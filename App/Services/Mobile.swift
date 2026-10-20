import CryptoKit
import Foundation
import MCP
import Network
import OSLog
import Security

/// Serves the Health and Alarms tools from iMCP on a paired iPhone or iPad.
///
/// HealthKit and AlarmKit data stays on the phone,
/// so the iOS app implements the tools from `MobileTools`.
/// When the phone is connected, calls go to it live;
/// otherwise read-only calls answer from `MobileCache`,
/// the copy of the data that the phone last sent,
/// and every answer says when that was.
actor MobileService: MobileBackend {
    static let shared = MobileService(isEnabled: { MobileService.isAnyServiceEnabled() })

    private let log = Logger.service("mobile")
    private var cache: MobileCache?
    private let pairings: any MobilePairingStore
    private let reconnectGrace: Duration
    private let advertise: Bool
    private let pollInterval: Duration
    private let codeLifetime: TimeInterval
    private let isEnabled: @Sendable () -> Bool
    private var listener: NWListener?
    private var listenerUpdate: Task<Void, Error>?
    private var port: NWEndpoint.Port = .any
    private var pendingPairing: (code: MobilePairingCode, expires: Date)?
    private var expiryTask: Task<Void, Never>?
    private var link: (any MobilePeerLink)?
    private var syncTask: Task<Void, Never>?
    private var draining = false
    private var lastPairingError: String?

    /// How long a pairing code works after iMCP shows it.
    static let pairingLifetime: TimeInterval = 600

    /// - Parameters:
    ///   - codeLifetime: How long a pairing code works.
    ///   - isEnabled: Whether a mobile service is on.
    ///     While none is, the Mac listens only for a pairing code.
    init(
        cache: MobileCache? = nil,
        pairings: any MobilePairingStore = MobileKeychainPairings(),
        reconnectGrace: Duration = .seconds(5),
        advertise: Bool = true,
        pollInterval: Duration = .seconds(15),
        codeLifetime: TimeInterval = MobileService.pairingLifetime,
        isEnabled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.cache = cache
        self.pairings = pairings
        self.reconnectGrace = reconnectGrace
        self.advertise = advertise
        self.pollInterval = pollInterval
        self.codeLifetime = codeLifetime
        self.isEnabled = isEnabled
    }

    /// Whether Health or Alarms is on in iMCP.
    nonisolated static func isAnyServiceEnabled() -> Bool {
        ["alarmsEnabled", "healthEnabled"].contains { UserDefaults.standard.bool(forKey: $0) }
    }

    /// Whether `service` is one of the services that this actor serves.
    nonisolated static func serves(_ service: any Service) -> Bool {
        service is HealthService || service is AlarmsService
    }

    /// Opens the cache and listens for paired devices, if there are any.
    func start() async throws {
        _ = try openCache()
        try await updateListener()
    }

    var isStarted: Bool { cache != nil }

    /// The port that the listener uses, or nil when iMCP isn't listening.
    var listeningPort: UInt16? { listener == nil ? nil : port.rawValue }

    /// Starts or stops listening after Health or Alarms is turned on or off.
    /// When both are off, also closes the connection to the phone.
    func servicesChanged() async {
        if !isEnabled() { await disconnect() }
        do {
            try await updateListener()
        } catch {
            log.error("\(error.localizedDescription, privacy: .public)")
        }
    }

    var isConnected: Bool { link != nil }

    var connectedDevice: MobileDevice? { link?.device }

    var devices: [MobileDevice] { pairings.devices() }

    var cacheID: String {
        get async {
            guard let cache = try? openCache() else { return "" }
            return (try? await cache.cacheID()) ?? ""
        }
    }

    private func openCache() throws -> MobileCache {
        if let cache { return cache }
        let cache = try MobileCache.standard()
        self.cache = cache
        return cache
    }

    func syncedAt(_ domain: MobileDomain) async -> Date? {
        guard let cache = try? openCache() else { return nil }
        return await cache.syncedAt(domain)
    }

    /// Deletes the Mac's copy of mobile data.
    /// The phone sends its data again the next time it connects.
    func deleteCache() async throws {
        try await openCache().deleteAll()
    }

    func stop() async {
        expiryTask?.cancel()
        expiryTask = nil
        _ = await listenerUpdate?.result
        await stopListener()
        syncTask?.cancel()
        syncTask = nil
        let current = link
        link = nil
        await current?.close()
    }

    // MARK: - Listener

    /// The Bonjour name that the iPhone or iPad looks for.
    nonisolated static var serviceName: String {
        let name = "iMCP on \(Host.current().localizedName ?? "Mac")"
        var bytes = 0
        return String(
            name.prefix { character in
                bytes += character.utf8.count
                return bytes <= 63
            }
        )
    }

    /// Listens while a device is paired and a mobile service is on,
    /// or while a pairing code is on screen,
    /// and stops listening otherwise.
    /// A running listener restarts so that it has the current keys.
    ///
    /// Updates run one at a time,
    /// so two callers can't start two listeners on the same port.
    private func updateListener() async throws {
        let previous = listenerUpdate
        let update = Task {
            _ = await previous?.result
            try await self.applyListenerKeys()
        }
        listenerUpdate = update
        try await update.value
    }

    private func applyListenerKeys() async throws {
        var keys: [(identity: Data, key: SymmetricKey)] = []
        if isEnabled() {
            keys = pairings.devices().compactMap { device in
                pairings.key(for: device.id).map { (MobileLink.deviceIdentity(device.id), $0) }
            }
        }
        if let pending = pendingPairing, pending.expires > Date() {
            keys.append(
                (
                    MobileLink.pairingIdentity(pending.code.pairingID),
                    MobileLink.pairingKey(secret: pending.code.secret)
                )
            )
        }
        await stopListener()
        if keys.isEmpty { return }
        try await startListening(keys: keys)
    }

    /// Starts the TLS listener with `keys`.
    private func startListening(keys: [(identity: Data, key: SymmetricKey)]) async throws {
        let parameters = MobileTLS.parameters(keys: keys)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        if advertise {
            listener.service = NWListener.Service(name: Self.serviceName, type: MobileLink.serviceType)
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        self.listener = listener
        let ready: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeOnce(continuation)
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    gate.resume(returning: listener?.port?.rawValue ?? 0)
                case .failed(let error):
                    gate.resume(
                        throwing: MobileError("iMCP can't listen for an iPhone or iPad: \(error.localizedDescription)")
                    )
                case .cancelled:
                    gate.resume(throwing: MobileError("The listener for iPhone and iPad connections stopped."))
                default: break
                }
            }
            listener.start(queue: .global())
        }
        // Keep the same port when the listener restarts after pairing changes.
        port = NWEndpoint.Port(rawValue: ready) ?? .any
    }

    /// Cancels the listener and waits until it releases its port.
    private func stopListener() async {
        guard let listener else { return }
        self.listener = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                if case .cancelled = state { gate.resume(returning: ()) }
            }
            listener.cancel()
            Task {
                try? await Task.sleep(for: .seconds(2))
                gate.resume(returning: ())
            }
        }
    }

    // MARK: - Pairing

    /// Creates a one-time pairing code for the QR code in Settings.
    func beginPairing() async throws -> MobilePairingCode {
        var secret = Data(count: 32)
        var id = Data(count: 9)
        guard
            secret.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) })
                == errSecSuccess,
            id.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 9, $0.baseAddress!) }) == errSecSuccess
        else { throw MobileError("iMCP couldn't create a pairing code.") }
        let code = MobilePairingCode(
            service: Self.serviceName,
            pairingID: id.base64URLEncodedString(),
            secret: secret
        )
        let expires = Date().addingTimeInterval(codeLifetime)
        pendingPairing = (code, expires)
        lastPairingError = nil
        _ = try openCache()
        scheduleExpiry(of: code, at: expires)
        try await updateListener()
        return code
    }

    func cancelPairing() async {
        guard pendingPairing != nil else { return }
        await endPairing()
    }

    /// Forgets the pairing code and stops listening if nothing else needs the listener.
    private func endPairing() async {
        pendingPairing = nil
        expiryTask?.cancel()
        expiryTask = nil
        try? await updateListener()
    }

    /// Removes the pairing code's key from the listener when the code expires.
    private func scheduleExpiry(of code: MobilePairingCode, at expires: Date) {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, expires.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await self?.expire(code)
        }
    }

    private func expire(_ code: MobilePairingCode) async {
        guard pendingPairing?.code == code else { return }
        log.notice("The pairing code expired")
        await endPairing()
    }

    var isPairing: Bool { pendingPairing.map { $0.expires > Date() } ?? false }

    /// The reason the last connection attempt was refused, for Settings.
    var pairingError: String? { lastPairingError }

    /// Forgets a paired device and closes its connection.
    /// When no paired device remains,
    /// also deletes the Mac's copy of mobile data.
    func unpair(_ device: String) async {
        pairings.remove(device)
        if let current = link, current.device.id == device {
            link = nil
            syncTask?.cancel()
            await current.close()
        }
        if pairings.devices().isEmpty {
            do {
                try await deleteCache()
            } catch {
                log.error("Couldn't delete the mobile cache: \(error.localizedDescription, privacy: .public)")
            }
        }
        try? await updateListener()
    }

    private struct Refusal: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Checks a hello against the pairing code or the device's key.
    /// Returns nil for a device that asked to be forgotten.
    private func authenticate(_ hello: MobileHello) async throws -> (MobileDevice?, MobileWelcome) {
        guard hello.version == MobileLink.protocolVersion else {
            throw Refusal(
                "iMCP on the Mac and on the iPhone or iPad use different versions. Update both, then try again."
            )
        }
        if let pairing = hello.pairing {
            guard let pending = pendingPairing, pending.code.pairingID == pairing, pending.expires > Date() else {
                throw Refusal("This pairing code expired or was already used. Show a new code in iMCP Settings.")
            }
            let key = MobileLink.pairingKey(secret: pending.code.secret)
            guard let phone = hello.exchange,
                MobileLink.verify(
                    hello.proof,
                    key: key,
                    device: hello.device,
                    purpose: "pair:\(pairing)",
                    context: phone
                )
            else {
                throw Refusal("The pairing code doesn't match. Scan the code in iMCP Settings again.")
            }
            // Derive the device key from a key exchange, so it never crosses the network.
            let exchange = Curve25519.KeyAgreement.PrivateKey()
            let mac = exchange.publicKey.rawRepresentation
            let deviceKey: SymmetricKey
            do {
                deviceKey = try MobileKeyExchange.deviceKey(
                    privateKey: exchange,
                    peer: phone,
                    pairingKey: key,
                    device: hello.device,
                    phone: phone,
                    mac: mac
                )
            } catch {
                throw Refusal("The device sent an invalid pairing key. Scan the code in iMCP Settings again.")
            }
            let device = MobileDevice(id: hello.device, name: hello.name, pairedAt: Date())
            try pairings.save(device, key: deviceKey)
            await endPairing()
            log.notice("Paired \(hello.name, privacy: .public)")
            return (
                device,
                MobileWelcome(
                    ok: true,
                    mac: Self.serviceName,
                    exchange: mac,
                    proof: MobileKeyExchange.welcomeProof(
                        pairingKey: key,
                        pairingID: pairing,
                        device: hello.device,
                        phone: phone,
                        mac: mac
                    )
                )
            )
        }
        let purpose = hello.revoke == true ? "revoke" : "connect"
        guard let key = pairings.key(for: hello.device),
            let device = pairings.devices().first(where: { $0.id == hello.device }),
            MobileLink.verify(hello.proof, key: key, device: hello.device, purpose: purpose)
        else {
            throw Refusal("This device isn't paired with this Mac. Pair it again from iMCP Settings.")
        }
        if hello.revoke == true {
            await unpair(hello.device)
            log.notice("\(hello.name, privacy: .public) removed its pairing")
            return (nil, MobileWelcome(ok: true, mac: Self.serviceName))
        }
        return (device, MobileWelcome(ok: true, mac: Self.serviceName))
    }

    private func accept(_ connection: NWConnection) async {
        let channel = MobileChannel(connection: connection)
        do {
            try await channel.open()
            let hello = try await channel.read(MobileHello.self)
            let (device, welcome) = try await authenticate(hello)
            try await channel.write(welcome)
            guard let device else {
                await channel.disconnect()
                return
            }
            let client = MCP.Client(name: "iMCP", version: Bundle.main.shortVersionString ?? "unknown")
            let result = try await client.connect(transport: channel)
            guard result.serverInfo.name == MobileLink.serverName else {
                throw MobileError("The connected app isn't iMCP for iOS.")
            }
            let link = MobileRemoteLink(device: device, client: client, channel: channel)
            await channel.setCloseHandler { [weak self] in
                await self?.detach(link)
                // Disconnecting the client fails its pending requests and stops its receive loop.
                await link.close()
            }
            attach(link)
            log.notice("\(device.name, privacy: .public) connected")
        } catch let refusal as Refusal {
            lastPairingError = refusal.message
            log.error("Refused a mobile connection: \(refusal.message, privacy: .public)")
            try? await channel.write(MobileWelcome(ok: false, error: refusal.message))
            await channel.disconnect()
        } catch {
            log.error("A mobile connection failed: \(error.localizedDescription, privacy: .public)")
            await channel.disconnect()
        }
    }

    // MARK: - Links

    /// Makes `link` the connection that calls go to, replacing any other.
    func attach(_ link: any MobilePeerLink) {
        let previous = self.link
        self.link = link
        if let previous, previous !== link { Task { await previous.close() } }
        syncTask?.cancel()
        syncTask = Task { [weak self] in await self?.syncLoop(link) }
    }

    func detach(_ link: any MobilePeerLink) {
        guard self.link === link else { return }
        self.link = nil
        syncTask?.cancel()
        syncTask = nil
        log.notice("The iPhone or iPad disconnected")
    }

    /// Closes the current connection. The phone reconnects when it can.
    func disconnect() async {
        guard let current = link else { return }
        detach(current)
        await current.close()
    }

    /// Waits for `device` to reconnect.
    /// A connection from another paired device doesn't count,
    /// so a retried call never reaches a device that the caller didn't choose.
    private func waitForLink(to device: MobileDevice) async -> (any MobilePeerLink)? {
        let deadline = ContinuousClock.now.advanced(by: reconnectGrace)
        while ContinuousClock.now < deadline {
            if let link, link.device.id == device.id { return link }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let link, link.device.id == device.id else { return nil }
        return link
    }

    // MARK: - Sync

    /// Asks the phone for its status and remembers it for answers from the cache.
    @discardableResult
    private func refreshPhoneStatus(_ link: any MobilePeerLink) async -> Value? {
        guard let text = try? await link.call(MobileTools.statusTool, [:]),
            let status = try? JSONDecoder().decode(Value.self, from: Data(text.utf8))
        else { return nil }
        try? await openCache().setPhoneStatus(status)
        return status
    }

    private func syncLoop(_ link: any MobilePeerLink) async {
        await refreshPhoneStatus(link)
        while !Task.isCancelled, self.link === link {
            await drain(link)
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Pulls queued batches from the phone, applies each to the cache,
    /// and acknowledges it so that the phone can drop it.
    private func drain(_ link: any MobilePeerLink) async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        do {
            let cache = try openCache()
            var cacheID = try await cache.cacheID()
            for _ in 0 ..< 1_000 {
                let text = try await link.call(MobileLink.pullTool, ["cache": .string(cacheID)])
                let batch = try MobileCoding.decoder.decode(MobileBatch.self, from: Data(text.utf8))
                guard batch.sequence > 0 else { break }
                // The cache can be deleted while the pull is in flight.
                // Don't apply or acknowledge a batch for the old copy;
                // pull again with the new ID so that the phone sends everything.
                guard try await cache.apply(batch, cacheID: cacheID) else {
                    cacheID = try await cache.cacheID()
                    continue
                }
                _ = try await link.call(MobileLink.ackTool, ["sequence": .int(Int(batch.sequence))])
                guard batch.hasMore else { break }
            }
        } catch is MobileLinkLost {
            detach(link)
        } catch {
            log.error("Mobile sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - MobileBackend

    func call(_ tool: String, _ input: [String: Value]) async throws -> Value {
        guard let definition = MobileTools.all(backend: self).first(where: { $0.name == tool }) else {
            throw MobileError("Unknown mobile tool: \(tool)")
        }
        try ToolInput.validate(input, schema: definition.inputSchema)
        if listener == nil, advertise { try? await start() }
        if tool == MobileTools.statusTool { return try await status() }
        guard let link else { return try await cached(tool, MobileArguments(input)) }
        return try await live(tool, input, readOnly: definition.annotations.readOnlyHint == true, link: link)
    }

    /// Sends a call to the phone.
    /// After a lost connection, a call is sent again only if repeating it is safe:
    /// reads, and alarm changes that carry an ID the phone deduplicates.
    /// A lost read that can't be retried answers from the cache.
    private func live(
        _ tool: String,
        _ input: [String: Value],
        readOnly: Bool,
        link: any MobilePeerLink
    ) async throws -> Value {
        var input = input
        if tool == "alarms_create" || tool == "timers_create", input["id"] == nil {
            input["id"] = .string(UUID().uuidString)
        }
        do {
            return try await send(tool, input, readOnly: readOnly, to: link)
        } catch is MobileLinkLost {
            detach(link)
        } catch let error as MobileError where readOnly && error.message.contains(MobileTools.lockedMessage) {
            return try await cached(
                tool,
                MobileArguments(input),
                note: "The iPhone or iPad is locked, so HealthKit can't be read live."
            )
        }
        if let next = await waitForLink(to: link.device) {
            do {
                return try await send(tool, input, readOnly: readOnly, to: next)
            } catch is MobileLinkLost {
                detach(next)
            }
        }
        if readOnly { return try await cached(tool, MobileArguments(input)) }
        let id = input["id"]?.stringValue ?? ""
        throw MobileError(
            tool == "alarms_cancel"
                ? "The connection to the iPhone or iPad was lost before it answered, so the alarm may already be cancelled. Retrying is safe."
                : "The connection to the iPhone or iPad was lost before it answered, so the alarm may exist. Check alarms_list after it reconnects. Retrying with id \(id) is safe: it won't create a second alarm."
        )
    }

    private func send(
        _ tool: String,
        _ input: [String: Value],
        readOnly: Bool,
        to link: any MobilePeerLink
    ) async throws -> Value {
        let text = try await link.call(tool, input)
        if !readOnly { Task { await self.drain(link) } }
        do {
            return try JSONDecoder().decode(Value.self, from: Data(text.utf8))
        } catch {
            throw MobileError("The iPhone or iPad returned invalid JSON: \(error.localizedDescription)")
        }
    }

    // MARK: - Cache

    private func cached(_ tool: String, _ args: MobileArguments, note extra: String? = nil) async throws -> Value {
        guard let domain = MobileTools.domain(of: tool) else {
            throw MobileError("Unknown mobile tool: \(tool)")
        }
        let cache = try openCache()
        let start = try args.date("start")
        let end = try args.date("end")
        let limit = args.limit()
        var note: String?
        let rows: [MobileCache.Row]
        switch tool {
        case "health_fetch":
            let type = MobileTools.healthTypeName(try args.required("type"))
            rows = try await cache.records(
                .healthSample,
                key: type,
                start: start,
                end: end,
                limit: limit,
                ascending: args.bool("ascending") ?? false
            )
            if rows.isEmpty {
                note =
                    "\(MobileEnvelope.emptyHealthNote) The Mac keeps category samples, such as sleep, but not raw quantity samples, such as heart rate; use health_statistics for daily values."
            }
        case "health_statistics":
            let type = MobileTools.healthTypeName(try args.required("type"))
            let interval = args.string("interval") ?? "day"
            guard interval == "day" else {
                throw MobileError(
                    "The Mac keeps daily statistics only. Use interval day, or open iMCP on the iPhone or iPad for \(interval) buckets."
                )
            }
            rows = try await cache.records(
                .healthStatistic,
                key: type,
                start: start ?? (end ?? Date()).addingTimeInterval(-MobileTools.defaultStatisticsWindow),
                end: end,
                limit: 1000,
                ascending: true
            )
            if rows.isEmpty { note = MobileEnvelope.emptyHealthNote }
        case "workouts_fetch":
            rows = try await cache.records(
                .workout,
                key: args.string("activity_type").map(MobileTools.healthTypeName),
                start: start,
                end: end,
                limit: limit
            )
            if rows.isEmpty { note = MobileEnvelope.emptyHealthNote }
        case "clinical_records_fetch":
            rows = try await cache.records(
                .clinicalRecord,
                key: args.string("type"),
                start: start,
                end: end,
                limit: limit
            )
            if rows.isEmpty { note = MobileEnvelope.emptyHealthNote }
        case "alarms_list":
            rows = try await cache.records(.alarm, ascending: true)
        default:
            throw MobileError(
                "\(tool) needs iMCP to be open on the iPhone or iPad and connected to this Mac."
            )
        }
        // The phone reports when a service can't run there, with a note that says why.
        let phone = await cache.phoneStatus()?.objectValue?["services"]?.objectValue?[domain.rawValue]?.objectValue
        let unavailable = phone?["available"] == .bool(false) ? phone?["note"]?.stringValue : nil
        return MobileEnvelope.make(
            domain: domain,
            source: .cache,
            syncedAt: await cache.syncedAt(domain),
            results: rows.map(\.payload),
            note: [unavailable, extra, note].compactMap { $0 }.joined(separator: " ").nilIfEmpty
        )
    }

    // MARK: - Status

    private func status() async throws -> Value {
        let cache = try openCache()
        var services: [String: Value] = [:]
        for domain in MobileDomain.allCases {
            let syncedAt = await cache.syncedAt(domain)
            var count = 0
            for kind in MobileKind.allCases where kind.domain == domain {
                count += await cache.count(kind)
            }
            services[domain.rawValue] = .object([
                "synced_at": syncedAt.map { .string(MobileArguments.format($0)) } ?? .null,
                "stale": .bool(MobileEnvelope.isStale(domain, syncedAt: syncedAt, now: Date())),
                "cached_records": .int(count),
            ])
        }
        var object: [String: Value] = [
            "paired_devices": .array(pairings.devices().map { .string($0.name) }),
            "connected": .bool(link != nil),
            "services": .object(services),
        ]
        if let link {
            object["device"] = .string(link.device.name)
            // The phone reports its permissions and queue; an older or busy phone may not answer.
            if let phone = await refreshPhoneStatus(link) {
                object["phone"] = phone
            }
        }
        return .object(object)
    }
}

// MARK: - Pairings

/// An iPhone or iPad that the user paired with this Mac.
struct MobileDevice: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var pairedAt: Date
}

/// Where the Mac keeps paired devices and their keys.
protocol MobilePairingStore: AnyObject, Sendable {
    func devices() -> [MobileDevice]
    func key(for device: String) -> SymmetricKey?
    func save(_ device: MobileDevice, key: SymmetricKey) throws
    func remove(_ device: String)
}

/// Keeps the device list in user defaults and each device key in the Keychain.
final class MobileKeychainPairings: MobilePairingStore, @unchecked Sendable {
    private let lock = NSLock()
    private let defaultsKey = "mobileDevices"

    func devices() -> [MobileDevice] {
        lock.withLock { load() }
    }

    func key(for device: String) -> SymmetricKey? {
        (try? MobileKeychain.read("device-\(device)")).flatMap { $0 }.map(SymmetricKey.init(data:))
    }

    func save(_ device: MobileDevice, key: SymmetricKey) throws {
        try MobileKeychain.write("device-\(device.id)", key.withUnsafeBytes { Data($0) })
        lock.withLock {
            var devices = load().filter { $0.id != device.id }
            devices.append(device)
            store(devices)
        }
    }

    func remove(_ device: String) {
        MobileKeychain.delete("device-\(device)")
        lock.withLock { store(load().filter { $0.id != device }) }
    }

    private func load() -> [MobileDevice] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([MobileDevice].self, from: data)) ?? []
    }

    private func store(_ devices: [MobileDevice]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(devices), forKey: defaultsKey)
    }
}

// MARK: - Links

/// A connection to iMCP on an iPhone or iPad that the Mac can call tools on.
protocol MobilePeerLink: AnyObject, Sendable {
    var device: MobileDevice { get }
    /// Calls a tool on the phone and returns its JSON text.
    /// Throws `MobileLinkLost` if the connection ends before the answer arrives.
    func call(_ tool: String, _ input: [String: Value]) async throws -> String
    func close() async
}

struct MobileLinkLost: Error, CustomStringConvertible {
    var description: String { "The connection to the iPhone or iPad was lost." }
}

/// The MCP client side of a connection that the phone opened.
final class MobileRemoteLink: MobilePeerLink, @unchecked Sendable {
    let device: MobileDevice
    private let client: MCP.Client
    private let channel: MobileChannel
    /// Live HealthKit queries can take a while on a large store.
    private static let timeout: Duration = .seconds(90)

    init(device: MobileDevice, client: MCP.Client, channel: MobileChannel) {
        self.device = device
        self.client = client
        self.channel = channel
    }

    func call(_ tool: String, _ input: [String: Value]) async throws -> String {
        if await channel.isClosed { throw MobileLinkLost() }
        let client = self.client
        let channel = self.channel
        let (content, isError) = try await withThrowingTaskGroup(of: ([MCP.Tool.Content], Bool?).self) { group in
            group.addTask {
                do {
                    let result = try await client.callTool(name: tool, arguments: input)
                    return (result.content, result.isError)
                } catch {
                    if await channel.isClosed { throw MobileLinkLost() }
                    throw MobileError("The iPhone or iPad didn't answer: \(error.localizedDescription)")
                }
            }
            // The client doesn't fail pending calls when the connection closes,
            // and the group waits for the call, so disconnect the client to end it.
            group.addTask {
                while await !channel.isClosed { try await Task.sleep(for: .milliseconds(250)) }
                await client.disconnect()
                throw MobileLinkLost()
            }
            group.addTask {
                try await Task.sleep(for: Self.timeout)
                await channel.disconnect()
                await client.disconnect()
                throw MobileLinkLost()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        let texts = content.compactMap { item -> String? in
            if case .text(let text, _, _) = item { return text }
            return nil
        }
        if isError == true {
            var message = texts.joined(separator: "\n")
            if message.hasPrefix("Error: ") { message.removeFirst("Error: ".count) }
            throw MobileError(message)
        }
        guard let text = texts.first else { throw MobileError("The iPhone or iPad returned no JSON text.") }
        return text
    }

    func close() async {
        await client.disconnect()
        await channel.disconnect()
    }
}

/// Resumes a continuation at most once, from any thread.
private final class ResumeOnce<T: Sendable, Failure: Error>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Failure>?

    init(_ continuation: CheckedContinuation<T, Failure>) { self.continuation = continuation }

    private func take() -> CheckedContinuation<T, Failure>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }

    func resume(returning value: T) { take()?.resume(returning: value) }

    func resume(throwing error: Failure) { take()?.resume(throwing: error) }
}

/// Health data from the paired iPhone or iPad's HealthKit store.
struct HealthService: Service {
    static let shared = HealthService()
    var tools: [Tool] { return MobileTools.tools(for: .health, backend: MobileService.shared) }
    var isActivated: Bool { get async { await MobileService.shared.isStarted } }
    func activate() async throws { try await MobileService.shared.start() }
}

/// Alarms and timers that iMCP schedules with AlarmKit on the paired iPhone or iPad.
struct AlarmsService: Service {
    static let shared = AlarmsService()
    var tools: [Tool] { return MobileTools.tools(for: .alarms, backend: MobileService.shared) }
    var isActivated: Bool { get async { await MobileService.shared.isStarted } }
    func activate() async throws { try await MobileService.shared.start() }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
