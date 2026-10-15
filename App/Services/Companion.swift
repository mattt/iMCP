import CryptoKit
import Foundation
import MCP
import Network
import OSLog
import Security

/// Serves the Health, Finance, and Alarms tools from iMCP Companion on the iPhone.
///
/// HealthKit, FinanceKit, and AlarmKit data stays on the phone,
/// so the companion app implements the tools from `CompanionTools`.
/// When the phone is connected, calls go to it live;
/// otherwise read-only calls answer from `CompanionCache`,
/// the copy of the data that the phone last sent,
/// and every answer says when that was.
actor CompanionService: CompanionBackend {
    static let shared = CompanionService()

    private let log = Logger.service("companion")
    private var cache: CompanionCache?
    private let pairings: any CompanionPairingStore
    private let reconnectGrace: Duration
    private let advertise: Bool
    private let pollInterval: Duration
    private var listener: NWListener?
    private var port: NWEndpoint.Port = .any
    private var pendingPairing: (code: CompanionPairingCode, expires: Date)?
    private var link: (any CompanionPeerLink)?
    private var syncTask: Task<Void, Never>?
    private var draining = false
    private var lastPairingError: String?

    /// How long a pairing code works after iMCP shows it.
    static let pairingLifetime: TimeInterval = 600

    init(
        cache: CompanionCache? = nil,
        pairings: any CompanionPairingStore = CompanionKeychainPairings(),
        reconnectGrace: Duration = .seconds(5),
        advertise: Bool = true,
        pollInterval: Duration = .seconds(15)
    ) {
        self.cache = cache
        self.pairings = pairings
        self.reconnectGrace = reconnectGrace
        self.advertise = advertise
        self.pollInterval = pollInterval
    }

    /// Opens the cache and starts listening for the paired iPhone.
    func start() async throws {
        _ = try openCache()
        if listener == nil { _ = try await startListening() }
    }

    var isStarted: Bool { cache != nil && listener != nil }

    var isConnected: Bool { link != nil }

    var connectedDevice: CompanionDevice? { link?.device }

    var devices: [CompanionDevice] { pairings.devices() }

    var cacheID: String {
        get async {
            guard let cache = try? openCache() else { return "" }
            return (try? await cache.cacheID()) ?? ""
        }
    }

    private func openCache() throws -> CompanionCache {
        if let cache { return cache }
        let cache = try CompanionCache.standard()
        self.cache = cache
        return cache
    }

    func syncedAt(_ domain: CompanionDomain) async -> Date? {
        guard let cache = try? openCache() else { return nil }
        return await cache.syncedAt(domain)
    }

    /// Deletes the Mac's copy of companion data.
    /// The phone sends its data again the next time it connects.
    func deleteCache() async throws {
        try await openCache().deleteAll()
    }

    func stop() async {
        await stopListener()
        syncTask?.cancel()
        syncTask = nil
        let current = link
        link = nil
        await current?.close()
    }

    // MARK: - Listener

    /// The Bonjour name that the iPhone looks for.
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

    /// Starts the TLS listener with the keys of every paired device
    /// and of the pairing code on screen, if any.
    /// Returns its port.
    @discardableResult
    func startListening() async throws -> UInt16 {
        await stopListener()
        var keys = pairings.devices().compactMap { device in
            pairings.key(for: device.id).map { (CompanionLink.deviceIdentity(device.id), $0) }
        }
        if let pending = pendingPairing, pending.expires > Date() {
            keys.append(
                (
                    CompanionLink.pairingIdentity(pending.code.pairingID),
                    CompanionLink.pairingKey(secret: pending.code.secret)
                )
            )
        }
        if keys.isEmpty {
            // TLS needs a key; this one belongs to no device.
            keys.append((CompanionLink.deviceIdentity("none"), SymmetricKey(size: .bits256)))
        }
        let parameters = CompanionTLS.parameters(keys: keys)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        if advertise {
            listener.service = NWListener.Service(name: Self.serviceName, type: CompanionLink.serviceType)
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
                        throwing: CompanionError("iMCP can't listen for iMCP Companion: \(error.localizedDescription)")
                    )
                case .cancelled:
                    gate.resume(throwing: CompanionError("The companion listener stopped."))
                default: break
                }
            }
            listener.start(queue: .global())
        }
        // Keep the same port when the listener restarts after pairing changes.
        port = NWEndpoint.Port(rawValue: ready) ?? .any
        return ready
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
    func beginPairing() async throws -> CompanionPairingCode {
        var secret = Data(count: 32)
        var id = Data(count: 9)
        guard
            secret.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) })
                == errSecSuccess,
            id.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 9, $0.baseAddress!) }) == errSecSuccess
        else { throw CompanionError("iMCP couldn't create a pairing code.") }
        let code = CompanionPairingCode(
            service: Self.serviceName,
            pairingID: id.base64URLEncodedString(),
            secret: secret
        )
        pendingPairing = (code, Date().addingTimeInterval(Self.pairingLifetime))
        lastPairingError = nil
        _ = try openCache()
        try await startListening()
        return code
    }

    func cancelPairing() async {
        guard pendingPairing != nil else { return }
        pendingPairing = nil
        _ = try? await startListening()
    }

    var isPairing: Bool { pendingPairing.map { $0.expires > Date() } ?? false }

    /// The reason the last connection attempt was refused, for Settings.
    var pairingError: String? { lastPairingError }

    /// Forgets a paired iPhone and closes its connection.
    func unpair(_ device: String) async {
        pairings.remove(device)
        if let current = link, current.device.id == device {
            link = nil
            syncTask?.cancel()
            await current.close()
        }
        if listener != nil { _ = try? await startListening() }
    }

    private struct Refusal: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Checks a hello against the pairing code or the device's key.
    /// Returns nil for a device that asked to be forgotten.
    private func authenticate(_ hello: CompanionHello) async throws -> (CompanionDevice?, CompanionWelcome) {
        guard hello.version == CompanionLink.protocolVersion else {
            throw Refusal("iMCP and iMCP Companion use different versions. Update both, then try again.")
        }
        if let pairing = hello.pairing {
            guard let pending = pendingPairing, pending.code.pairingID == pairing, pending.expires > Date() else {
                throw Refusal("This pairing code expired or was already used. Show a new code in iMCP Settings.")
            }
            let key = CompanionLink.pairingKey(secret: pending.code.secret)
            guard CompanionLink.verify(hello.proof, key: key, device: hello.device, purpose: "pair:\(pairing)") else {
                throw Refusal("The pairing code doesn't match. Scan the code in iMCP Settings again.")
            }
            let deviceKey = SymmetricKey(size: .bits256)
            let device = CompanionDevice(id: hello.device, name: hello.name, pairedAt: Date())
            try pairings.save(device, key: deviceKey)
            pendingPairing = nil
            _ = try? await startListening()
            log.notice("Paired iMCP Companion on \(hello.name, privacy: .public)")
            return (
                device,
                CompanionWelcome(ok: true, mac: Self.serviceName, deviceKey: deviceKey.withUnsafeBytes { Data($0) })
            )
        }
        let purpose = hello.revoke == true ? "revoke" : "connect"
        guard let key = pairings.key(for: hello.device),
            let device = pairings.devices().first(where: { $0.id == hello.device }),
            CompanionLink.verify(hello.proof, key: key, device: hello.device, purpose: purpose)
        else {
            throw Refusal("This iPhone isn't paired with this Mac. Pair it again from iMCP Settings.")
        }
        if hello.revoke == true {
            await unpair(hello.device)
            log.notice("iMCP Companion on \(hello.name, privacy: .public) removed its pairing")
            return (nil, CompanionWelcome(ok: true, mac: Self.serviceName))
        }
        return (device, CompanionWelcome(ok: true, mac: Self.serviceName))
    }

    private func accept(_ connection: NWConnection) async {
        let channel = CompanionChannel(connection: connection)
        do {
            try await channel.open()
            let hello = try await channel.read(CompanionHello.self)
            let (device, welcome) = try await authenticate(hello)
            try await channel.write(welcome)
            guard let device else {
                await channel.disconnect()
                return
            }
            let client = MCP.Client(name: "iMCP", version: Bundle.main.shortVersionString ?? "unknown")
            let result = try await client.connect(transport: channel)
            guard result.serverInfo.name == CompanionLink.serverName else {
                throw CompanionError("The connected app isn't iMCP Companion.")
            }
            let link = CompanionRemoteLink(device: device, client: client, channel: channel)
            await channel.setCloseHandler { [weak self] in
                await self?.detach(link)
                // Disconnecting the client fails its pending requests and stops its receive loop.
                await link.close()
            }
            attach(link)
            log.notice("iMCP Companion connected from \(device.name, privacy: .public)")
        } catch let refusal as Refusal {
            lastPairingError = refusal.message
            log.error("Refused an iMCP Companion connection: \(refusal.message, privacy: .public)")
            try? await channel.write(CompanionWelcome(ok: false, error: refusal.message))
            await channel.disconnect()
        } catch {
            log.error("An iMCP Companion connection failed: \(error.localizedDescription, privacy: .public)")
            await channel.disconnect()
        }
    }

    // MARK: - Links

    /// Makes `link` the connection that calls go to, replacing any other.
    func attach(_ link: any CompanionPeerLink) {
        let previous = self.link
        self.link = link
        if let previous, previous !== link { Task { await previous.close() } }
        syncTask?.cancel()
        syncTask = Task { [weak self] in await self?.syncLoop(link) }
    }

    func detach(_ link: any CompanionPeerLink) {
        guard self.link === link else { return }
        self.link = nil
        syncTask?.cancel()
        syncTask = nil
        log.notice("iMCP Companion disconnected")
    }

    /// Closes the current connection. The phone reconnects when it can.
    func disconnect() async {
        guard let current = link else { return }
        detach(current)
        await current.close()
    }

    private func waitForLink() async -> (any CompanionPeerLink)? {
        let deadline = ContinuousClock.now.advanced(by: reconnectGrace)
        while ContinuousClock.now < deadline {
            if let link { return link }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return link
    }

    // MARK: - Sync

    /// Asks the phone for its status and remembers it for answers from the cache.
    @discardableResult
    private func refreshPhoneStatus(_ link: any CompanionPeerLink) async -> Value? {
        guard let text = try? await link.call(CompanionTools.statusTool, [:]),
            let status = try? JSONDecoder().decode(Value.self, from: Data(text.utf8))
        else { return nil }
        try? await openCache().setPhoneStatus(status)
        return status
    }

    private func syncLoop(_ link: any CompanionPeerLink) async {
        await refreshPhoneStatus(link)
        while !Task.isCancelled, self.link === link {
            await drain(link)
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Pulls queued batches from the phone, applies each to the cache,
    /// and acknowledges it so that the phone can drop it.
    private func drain(_ link: any CompanionPeerLink) async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        do {
            let cache = try openCache()
            let cacheID = try await cache.cacheID()
            for _ in 0 ..< 1_000 {
                let text = try await link.call(CompanionLink.pullTool, ["cache": .string(cacheID)])
                let batch = try CompanionCoding.decoder.decode(CompanionBatch.self, from: Data(text.utf8))
                guard batch.sequence > 0 else { break }
                try await cache.apply(batch)
                _ = try await link.call(CompanionLink.ackTool, ["sequence": .int(Int(batch.sequence))])
                guard batch.hasMore else { break }
            }
        } catch is CompanionLinkLost {
            detach(link)
        } catch {
            log.error("Companion sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - CompanionBackend

    func call(_ tool: String, _ input: [String: Value]) async throws -> Value {
        guard let definition = CompanionTools.all(backend: self).first(where: { $0.name == tool }) else {
            throw CompanionError("Unknown companion tool: \(tool)")
        }
        try ToolInput.validate(input, schema: definition.inputSchema)
        if listener == nil, advertise { try? await start() }
        if tool == CompanionTools.statusTool { return try await status() }
        guard let link else { return try await cached(tool, CompanionArguments(input)) }
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
        link: any CompanionPeerLink
    ) async throws -> Value {
        var input = input
        if tool == "alarms_create" || tool == "timers_create", input["id"] == nil {
            input["id"] = .string(UUID().uuidString)
        }
        do {
            return try await send(tool, input, readOnly: readOnly, to: link)
        } catch is CompanionLinkLost {
            detach(link)
        } catch let error as CompanionError where readOnly && error.message.contains(CompanionTools.lockedMessage) {
            return try await cached(
                tool,
                CompanionArguments(input),
                note: "The iPhone is locked, so HealthKit can't be read live."
            )
        }
        if let next = await waitForLink() {
            do {
                return try await send(tool, input, readOnly: readOnly, to: next)
            } catch is CompanionLinkLost {
                detach(next)
            }
        }
        if readOnly { return try await cached(tool, CompanionArguments(input)) }
        let id = input["id"]?.stringValue ?? ""
        throw CompanionError(
            tool == "alarms_cancel"
                ? "The connection to iMCP Companion was lost before it answered, so the alarm may already be cancelled. Retrying is safe."
                : "The connection to iMCP Companion was lost before it answered, so the alarm may exist. Check alarms_list after the iPhone reconnects. Retrying with id \(id) is safe: it won't create a second alarm."
        )
    }

    private func send(
        _ tool: String,
        _ input: [String: Value],
        readOnly: Bool,
        to link: any CompanionPeerLink
    ) async throws -> Value {
        let text = try await link.call(tool, input)
        if !readOnly { Task { await self.drain(link) } }
        do {
            return try JSONDecoder().decode(Value.self, from: Data(text.utf8))
        } catch {
            throw CompanionError("iMCP Companion returned invalid JSON: \(error.localizedDescription)")
        }
    }

    // MARK: - Cache

    private func cached(_ tool: String, _ args: CompanionArguments, note extra: String? = nil) async throws -> Value {
        guard let domain = CompanionTools.domain(of: tool) else {
            throw CompanionError("Unknown companion tool: \(tool)")
        }
        let cache = try openCache()
        let start = try args.date("start")
        let end = try args.date("end")
        let limit = args.limit()
        var note: String?
        let rows: [CompanionCache.Row]
        switch tool {
        case "health_fetch":
            let type = CompanionTools.healthTypeName(try args.required("type"))
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
                    "\(CompanionEnvelope.emptyHealthNote) The Mac keeps category samples, such as sleep, but not raw quantity samples, such as heart rate; use health_statistics for daily values."
            }
        case "health_statistics":
            let type = CompanionTools.healthTypeName(try args.required("type"))
            let interval = args.string("interval") ?? "day"
            guard interval == "day" else {
                throw CompanionError(
                    "The Mac keeps daily statistics only. Use interval day, or open iMCP Companion on the iPhone for \(interval) buckets."
                )
            }
            rows = try await cache.records(
                .healthStatistic,
                key: type,
                start: start ?? (end ?? Date()).addingTimeInterval(-CompanionTools.defaultStatisticsWindow),
                end: end,
                limit: 1000,
                ascending: true
            )
            if rows.isEmpty { note = CompanionEnvelope.emptyHealthNote }
        case "workouts_fetch":
            rows = try await cache.records(
                .workout,
                key: args.string("activity_type").map(CompanionTools.healthTypeName),
                start: start,
                end: end,
                limit: limit
            )
            if rows.isEmpty { note = CompanionEnvelope.emptyHealthNote }
        case "clinical_records_fetch":
            rows = try await cache.records(
                .clinicalRecord,
                key: args.string("type"),
                start: start,
                end: end,
                limit: limit
            )
            if rows.isEmpty { note = CompanionEnvelope.emptyHealthNote }
        case "finance_accounts_list":
            rows = try await cache.records(.account, ascending: true)
        case "finance_balances_fetch":
            rows = try await cache.records(
                .balance,
                key: try args.uuid("account")?.uuidString,
                start: start,
                end: end,
                limit: limit
            )
        case "finance_transactions_fetch":
            let status = args.string("status")
            let query = args.string("query")?.lowercased()
            let candidates = try await cache.records(
                .transaction,
                key: try args.uuid("account")?.uuidString,
                start: start,
                end: end,
                limit: status == nil && query == nil ? limit : nil
            )
            rows = Array(
                candidates.filter { row in
                    let object = row.payload.objectValue ?? [:]
                    if let status, object["status"]?.stringValue != status { return false }
                    if let query {
                        let text = [object["merchant_name"], object["description"]]
                            .compactMap { $0?.stringValue?.lowercased() }
                        if !text.contains(where: { $0.contains(query) }) { return false }
                    }
                    return true
                }
                .prefix(limit)
            )
        case "alarms_list":
            rows = try await cache.records(.alarm, ascending: true)
        default:
            throw CompanionError(
                "\(tool) needs iMCP Companion to be open on the iPhone and connected to this Mac."
            )
        }
        // The phone reports when a service can't run there, such as Finance without its entitlement.
        let phone = await cache.phoneStatus()?.objectValue?["services"]?.objectValue?[domain.rawValue]?.objectValue
        let unavailable = phone?["available"] == .bool(false) ? phone?["note"]?.stringValue : nil
        return CompanionEnvelope.make(
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
        for domain in CompanionDomain.allCases {
            let syncedAt = await cache.syncedAt(domain)
            var count = 0
            for kind in CompanionKind.allCases where kind.domain == domain {
                count += await cache.count(kind)
            }
            services[domain.rawValue] = .object([
                "synced_at": syncedAt.map { .string(CompanionArguments.format($0)) } ?? .null,
                "stale": .bool(CompanionEnvelope.isStale(domain, syncedAt: syncedAt, now: Date())),
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

/// An iPhone that the user paired with this Mac.
struct CompanionDevice: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var pairedAt: Date
}

/// Where the Mac keeps paired devices and their keys.
protocol CompanionPairingStore: AnyObject, Sendable {
    func devices() -> [CompanionDevice]
    func key(for device: String) -> SymmetricKey?
    func save(_ device: CompanionDevice, key: SymmetricKey) throws
    func remove(_ device: String)
}

/// Keeps the device list in user defaults and each device key in the Keychain.
final class CompanionKeychainPairings: CompanionPairingStore, @unchecked Sendable {
    private let lock = NSLock()
    private let defaultsKey = "companionDevices"

    func devices() -> [CompanionDevice] {
        lock.withLock { load() }
    }

    func key(for device: String) -> SymmetricKey? {
        (try? CompanionKeychain.read("device-\(device)")).flatMap { $0 }.map(SymmetricKey.init(data:))
    }

    func save(_ device: CompanionDevice, key: SymmetricKey) throws {
        try CompanionKeychain.write("device-\(device.id)", key.withUnsafeBytes { Data($0) })
        lock.withLock {
            var devices = load().filter { $0.id != device.id }
            devices.append(device)
            store(devices)
        }
    }

    func remove(_ device: String) {
        CompanionKeychain.delete("device-\(device)")
        lock.withLock { store(load().filter { $0.id != device }) }
    }

    private func load() -> [CompanionDevice] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([CompanionDevice].self, from: data)) ?? []
    }

    private func store(_ devices: [CompanionDevice]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(devices), forKey: defaultsKey)
    }
}

// MARK: - Links

/// A connection to iMCP Companion that the Mac can call tools on.
protocol CompanionPeerLink: AnyObject, Sendable {
    var device: CompanionDevice { get }
    /// Calls a tool on the phone and returns its JSON text.
    /// Throws `CompanionLinkLost` if the connection ends before the answer arrives.
    func call(_ tool: String, _ input: [String: Value]) async throws -> String
    func close() async
}

struct CompanionLinkLost: Error, CustomStringConvertible {
    var description: String { "The connection to iMCP Companion was lost." }
}

/// The MCP client side of a connection that the phone opened.
final class CompanionRemoteLink: CompanionPeerLink, @unchecked Sendable {
    let device: CompanionDevice
    private let client: MCP.Client
    private let channel: CompanionChannel
    /// Live HealthKit and FinanceKit queries can take a while on a large store.
    private static let timeout: Duration = .seconds(90)

    init(device: CompanionDevice, client: MCP.Client, channel: CompanionChannel) {
        self.device = device
        self.client = client
        self.channel = channel
    }

    func call(_ tool: String, _ input: [String: Value]) async throws -> String {
        if await channel.isClosed { throw CompanionLinkLost() }
        let client = self.client
        let channel = self.channel
        let (content, isError) = try await withThrowingTaskGroup(of: ([MCP.Tool.Content], Bool?).self) { group in
            group.addTask {
                do {
                    let result = try await client.callTool(name: tool, arguments: input)
                    return (result.content, result.isError)
                } catch {
                    if await channel.isClosed { throw CompanionLinkLost() }
                    throw CompanionError("iMCP Companion didn't answer: \(error.localizedDescription)")
                }
            }
            // The client doesn't fail pending calls when the connection closes,
            // and the group waits for the call, so disconnect the client to end it.
            group.addTask {
                while await !channel.isClosed { try await Task.sleep(for: .milliseconds(250)) }
                await client.disconnect()
                throw CompanionLinkLost()
            }
            group.addTask {
                try await Task.sleep(for: Self.timeout)
                await channel.disconnect()
                await client.disconnect()
                throw CompanionLinkLost()
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
            throw CompanionError(message)
        }
        guard let text = texts.first else { throw CompanionError("iMCP Companion returned no JSON text.") }
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

/// Health data from the paired iPhone's HealthKit store.
struct HealthService: Service {
    static let shared = HealthService()
    var tools: [Tool] { return CompanionTools.tools(for: .health, backend: CompanionService.shared) }
    var isActivated: Bool { get async { await CompanionService.shared.isStarted } }
    func activate() async throws { try await CompanionService.shared.start() }
}

/// Apple Card, Apple Cash, and Apple Savings data from the paired iPhone's Wallet.
struct FinanceService: Service {
    static let shared = FinanceService()
    var tools: [Tool] { return CompanionTools.tools(for: .finance, backend: CompanionService.shared) }
    var isActivated: Bool { get async { await CompanionService.shared.isStarted } }
    func activate() async throws { try await CompanionService.shared.start() }
}

/// Alarms and timers that iMCP Companion schedules with AlarmKit on the paired iPhone.
struct AlarmsService: Service {
    static let shared = AlarmsService()
    var tools: [Tool] { return CompanionTools.tools(for: .alarms, backend: CompanionService.shared) }
    var isActivated: Bool { get async { await CompanionService.shared.isStarted } }
    func activate() async throws { try await CompanionService.shared.start() }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
