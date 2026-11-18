import CryptoKit
import Foundation
import MCP
import Network
import OSLog
import Security

/// Transport endpoints that the Mac advertises to a paired iPhone or iPad.
struct MobileRemoteEndpoints: Equatable, Sendable {
    var tailnetHost: String?
    var tailnetPort: UInt16?
    var funnelURL: String?
    var cloudflareURL: String?
}

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

    static let transportModeKey = "mobileTransportMode"
    static let tailscaleVPNEnabledKey = "mobileTailscaleVPNEnabled"
    static let tailscaleHostOverrideKey = "mobileTailscaleHost"
    /// How long a phone has to send its hello on a WebSocket before the Mac closes it.
    static let helloTimeout: Duration = .seconds(15)
    static let cloudflareEnabledKey = "mobileCloudflareEnabled"
    static let cloudflareURLKey = "mobileCloudflareURL"
    static let cloudflareLocalPortKey = "mobileCloudflareLocalPort"
    /// The port that the TLS listener last bound, tried first on the next launch
    /// so that a paired phone's saved Tailscale address stays valid.
    static let listenerPortKey = "mobileListenerPort"
    /// The order the owner chose for the routes the Mac offers, as `MobileRouteKind` raw values.
    static let routeOrderKey = "mobileRouteOrder"
    /// Routes the owner turned off, as `MobileRouteKind` raw values.
    static let disabledRoutesKey = "mobileDisabledRoutes"
    /// Whether the Mac tells the phone to show activity history. On unless turned off.
    static let activityHistoryKey = "mobileActivityHistoryEnabled"

    private let log = Logger.service("mobile")
    private var cache: MobileCache?
    private var activityStore: MobileActivityStore?
    private let pairings: any MobilePairingStore
    private let defaults: UserDefaults
    private let ledger: MobileConfigurationLedger
    private let reconnectGrace: Duration
    private let livenessTimeout: Duration
    private let activityStoreOpener: @Sendable () throws -> MobileActivityStore
    private let advertise: Bool
    private let pollInterval: Duration
    private let codeLifetime: TimeInterval
    private let isEnabled: @Sendable () -> Bool
    private var listener: NWListener?
    private var webSocketListener: NWListener?
    private var webSocketListeningPort: UInt16?
    private var listenerUpdate: Task<Void, Error>?
    private var port: NWEndpoint.Port = .any
    private var pendingPairing: (code: MobilePairingCode, expires: Date)?
    private var expiryTask: Task<Void, Never>?
    private var link: (any MobilePeerLink)?
    private var syncTask: Task<Void, Never>?
    private var draining = false
    private var syncingActivity = false
    private var needsActivitySync = false
    private var lastPairingError: String?
    private var advertisedTailnetHost: String?
    private var advertisedFunnelURL: String?
    private var advertisedCloudflareURL: String?

    /// How long a pairing code works after iMCP shows it.
    static let pairingLifetime: TimeInterval = 600

    /// - Parameters:
    ///   - codeLifetime: How long a pairing code works.
    ///   - isEnabled: Whether a mobile service is on.
    ///     While none is, the Mac listens only for a pairing code.
    init(
        cache: MobileCache? = nil,
        activityStore: MobileActivityStore? = nil,
        pairings: any MobilePairingStore = MobileKeychainPairings(),
        defaults: UserDefaults = .standard,
        reconnectGrace: Duration = .seconds(5),
        livenessTimeout: Duration = .seconds(3),
        activityStoreOpener: @escaping @Sendable () throws -> MobileActivityStore = { try .standard() },
        advertise: Bool = true,
        pollInterval: Duration = .seconds(15),
        codeLifetime: TimeInterval = MobileService.pairingLifetime,
        isEnabled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.cache = cache
        self.activityStore = activityStore
        self.pairings = pairings
        self.defaults = defaults
        ledger = MobileConfigurationLedger(defaults: defaults)
        self.reconnectGrace = reconnectGrace
        self.livenessTimeout = livenessTimeout
        self.activityStoreOpener = activityStoreOpener
        self.advertise = advertise
        self.pollInterval = pollInterval
        self.codeLifetime = codeLifetime
        self.isEnabled = isEnabled
    }

    /// Whether Health or Alarms is on in iMCP.
    nonisolated static func isAnyServiceEnabled() -> Bool {
        ["alarmsEnabled", "healthEnabled"].contains { UserDefaults.standard.bool(forKey: $0) }
    }

    /// Saves the order of the routes that the Mac offers.
    nonisolated static func setRouteOrder(_ order: [MobileRouteKind], defaults: UserDefaults = .standard) {
        defaults.set(order.map(\.rawValue), forKey: routeOrderKey)
    }

    /// Turns a route on or off. Tailscale VPN and Cloudflare Tunnel use the settings that already switch them.
    nonisolated static func setRoute(_ kind: MobileRouteKind, enabled: Bool, defaults: UserDefaults = .standard) {
        switch kind {
        case .tailscaleVPN:
            defaults.set(enabled, forKey: tailscaleVPNEnabledKey)
        case .cloudflare:
            defaults.set(enabled, forKey: cloudflareEnabledKey)
        case .local, .tailscaleFunnel:
            var disabled = Set(defaults.stringArray(forKey: disabledRoutesKey) ?? [])
            if enabled { disabled.remove(kind.rawValue) } else { disabled.insert(kind.rawValue) }
            defaults.set(disabled.sorted(), forKey: disabledRoutesKey)
        }
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

    /// The port of the loopback WebSocket listener that a tunnel forwards to, or nil when it isn't running.
    var webSocketPort: UInt16? { webSocketListener == nil ? nil : webSocketListeningPort }

    /// Re-applies the transport settings after they change.
    func applyTransportSettings() async {
        do {
            try await updateListener()
        } catch {
            log.error("Couldn't update the transport listeners: \(error.localizedDescription, privacy: .public)")
        }
        await pushConfiguration()
    }

    /// Sets the Tailscale host, Funnel WebSocket URL and Cloudflare Tunnel WebSocket URL that remote access advertises.
    /// Without a caller, the Mac advertises the address of its own Tailscale interface and no Funnel URL.
    /// A Cloudflare address typed in Settings takes priority over `cloudflareURL`.
    func updateRemoteEndpoints(tailnetHost: String?, funnelURL: String?, cloudflareURL: String? = nil) {
        let trimmedHost = tailnetHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        advertisedTailnetHost = (trimmedHost?.isEmpty == false) ? trimmedHost : nil
        advertisedFunnelURL = MobileLink.normalizedWebSocketURL(funnelURL)
        advertisedCloudflareURL = MobileLink.normalizedWebSocketURL(cloudflareURL)
        Task { await pushConfiguration() }
    }

    /// The Mac's settings and live addresses, as the configuration is built from them.
    var currentState: MobileMacState {
        let mode =
            defaults.string(forKey: Self.transportModeKey).flatMap(MobileTransportMode.init(rawValue:)) ?? .automatic
        var disabled = Set(
            (defaults.stringArray(forKey: Self.disabledRoutesKey) ?? []).compactMap(MobileRouteKind.init(rawValue:))
        )
        var host: String?
        if defaults.object(forKey: Self.tailscaleVPNEnabledKey) as? Bool ?? true {
            let override = defaults.string(forKey: Self.tailscaleHostOverrideKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            host = (override?.isEmpty == false) ? override : (advertisedTailnetHost ?? MobileTailnet.localAddress())
        } else {
            disabled.insert(.tailscaleVPN)
        }
        // A Cloudflare address typed in Settings takes priority over the one remote access advertises.
        let cloudflareEnabled = defaults.bool(forKey: Self.cloudflareEnabledKey)
        let typedCloudflareURL =
            cloudflareEnabled ? MobileLink.normalizedWebSocketURL(defaults.string(forKey: Self.cloudflareURLKey)) : nil
        let cloudflareURL = typedCloudflareURL ?? advertisedCloudflareURL
        if !cloudflareEnabled && advertisedCloudflareURL == nil {
            disabled.insert(.cloudflare)
        }
        return MobileMacState(
            macName: Host.current().localizedName ?? "Mac",
            service: Self.serviceName,
            recommendedMode: mode,
            order: (defaults.stringArray(forKey: Self.routeOrderKey) ?? []).compactMap(MobileRouteKind.init(rawValue:)),
            disabled: disabled,
            tailnetHost: host,
            tailnetPort: host != nil ? listeningPort : nil,
            funnelURL: advertisedFunnelURL,
            cloudflareURL: cloudflareURL,
            features: MobileFeatures(
                activityHistory: defaults.object(forKey: Self.activityHistoryKey) as? Bool ?? true
            )
        )
    }

    /// What the Mac offers, with the revision that this offer has.
    /// The revision goes up when the offer changes and never otherwise.
    var currentConfiguration: MobileConfiguration {
        ledger.configuration(for: currentState)
    }

    /// The revision that `device` last said it applied, or nil if it hasn't said.
    func appliedConfigurationRevision(for device: String) -> Int? {
        ledger.appliedRevision(for: device)
    }

    /// What the Mac offers a phone from before configurations existed.
    /// A route that the owner turned off is left out.
    var currentEndpoints: MobileRemoteEndpoints {
        let offered = MobileConfigurationBuilder.build(currentState, revision: 0)
        guard currentState.recommendedMode != .localOnly else { return MobileRemoteEndpoints() }
        return MobileRemoteEndpoints(
            tailnetHost: offered.tailnetHost,
            tailnetPort: offered.tailnetPort,
            funnelURL: offered.funnelURL,
            cloudflareURL: offered.cloudflareURL
        )
    }

    var isConnected: Bool { link != nil }

    var connectedDevice: MobileDevice? { link?.device }

    var connectedTransport: MobileTransportMode? { link?.transportMode }

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
        await stopWebSocketListener()
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
        if keys.isEmpty {
            await stopWebSocketListener()
            return
        }
        try await startListening(keys: keys)
        if advertise {
            await stopWebSocketListener()
            if UserDefaults.standard.bool(forKey: Self.cloudflareEnabledKey) {
                let stored = UserDefaults.standard.integer(forKey: Self.cloudflareLocalPortKey)
                let webSocketPort =
                    (stored > 0 && stored <= Int(UInt16.max)) ? UInt16(stored) : MobileLink.defaultWebSocketPort
                do {
                    try await startWebSocketListener(port: webSocketPort)
                } catch {
                    log.error("\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Starts the TLS listener with `keys`.
    private func startListening(keys: [(identity: Data, key: SymmetricKey)]) async throws {
        let parameters = MobileTLS.parameters(keys: keys)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        if port == .any, advertise,
            let saved = UserDefaults.standard.object(forKey: Self.listenerPortKey) as? Int,
            let preferred = NWEndpoint.Port(rawValue: UInt16(clamping: saved)), saved > 0,
            let reused = try? NWListener(using: parameters, on: preferred)
        {
            listener = reused
        } else {
            listener = try NWListener(using: parameters, on: port)
        }
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
        if advertise, ready > 0 { UserDefaults.standard.set(Int(ready), forKey: Self.listenerPortKey) }
    }

    /// Starts the loopback WebSocket listener that a tunnel forwards to (`127.0.0.1:<port>`).
    /// Phones reach it over `wss://` through the tunnel, with the same pairing and encryption as any other route.
    func startWebSocketListener(port wsPort: UInt16 = 0) async throws {
        await stopWebSocketListener()
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        let endpointPort: NWEndpoint.Port = wsPort == 0 ? .any : (NWEndpoint.Port(rawValue: wsPort) ?? .any)
        let listener = try NWListener(using: parameters, on: endpointPort)
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.acceptLoopbackWebSocket(connection) }
        }
        webSocketListener = listener
        let ready: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeOnce(continuation)
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    gate.resume(returning: listener?.port?.rawValue ?? 0)
                case .failed(let error):
                    gate.resume(
                        throwing: MobileError("iMCP can't listen for tunnel connections: \(error.localizedDescription)")
                    )
                case .cancelled:
                    gate.resume(throwing: MobileError("The tunnel listener stopped."))
                default: break
                }
            }
            listener.start(queue: .global())
        }
        webSocketListeningPort = ready
    }

    private func stopWebSocketListener() async {
        guard let listener = webSocketListener else { return }
        webSocketListener = nil
        webSocketListeningPort = nil
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
        var code = MobilePairingCode(
            service: Self.serviceName,
            pairingID: id.base64URLEncodedString(),
            secret: secret
        )
        let expires = Date().addingTimeInterval(codeLifetime)
        pendingPairing = (code, expires)
        lastPairingError = nil
        _ = try openCache()
        // The listener has to be up to know its port, so the code carries the right Tailscale address.
        try await updateListener()
        let endpoints = currentEndpoints
        code.tailnetHost = endpoints.tailnetHost
        code.tailnetPort = endpoints.tailnetPort
        code.funnelURL = endpoints.funnelURL
        code.cloudflareURL = endpoints.cloudflareURL
        pendingPairing = (code, expires)
        scheduleExpiry(of: code, at: expires)
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
        ledger.forget(device)
        await activityStore?.resetAcknowledgement(for: device)
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

    private func makeWelcome(
        ok: Bool,
        error: String? = nil,
        exchange: Data? = nil,
        proof: String? = nil
    ) -> MobileWelcome {
        let endpoints = ok ? currentEndpoints : MobileRemoteEndpoints()
        return MobileWelcome(
            ok: ok,
            error: error,
            mac: ok ? Self.serviceName : nil,
            exchange: exchange,
            proof: proof,
            tailnetHost: endpoints.tailnetHost,
            tailnetPort: endpoints.tailnetPort,
            funnelURL: endpoints.funnelURL,
            cloudflareURL: endpoints.cloudflareURL,
            configuration: ok ? currentConfiguration : nil
        )
    }

    /// Checks a hello against the pairing code or the device's key.
    /// Returns nil for a device that asked to be forgotten.
    private func authenticate(
        _ hello: MobileHello,
        requiresExchange: Bool = false
    ) async throws -> (
        device: MobileDevice?,
        welcome: MobileWelcome,
        sessionKeys: (send: SymmetricKey, receive: SymmetricKey)?
    ) {
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
            let sessionKeys: (send: SymmetricKey, receive: SymmetricKey)?
            do {
                deviceKey = try MobileKeyExchange.deviceKey(
                    privateKey: exchange,
                    peer: phone,
                    pairingKey: key,
                    device: hello.device,
                    phone: phone,
                    mac: mac
                )
                sessionKeys =
                    requiresExchange
                    ? try MobileKeyExchange.sessionKeys(
                        privateKey: exchange,
                        peer: phone,
                        psk: key,
                        device: hello.device,
                        phone: phone,
                        mac: mac,
                        role: .mac
                    )
                    : nil
            } catch {
                throw Refusal("The device sent an invalid pairing key. Scan the code in iMCP Settings again.")
            }
            let device = MobileDevice(id: hello.device, name: hello.name, pairedAt: Date())
            try pairings.save(device, key: deviceKey)
            await endPairing()
            log.notice("Paired \(hello.name, privacy: .public)")
            let welcome = makeWelcome(
                ok: true,
                exchange: mac,
                proof: MobileKeyExchange.welcomeProof(
                    pairingKey: key,
                    pairingID: pairing,
                    device: hello.device,
                    phone: phone,
                    mac: mac
                )
            )
            return (device, welcome, sessionKeys)
        }

        let purpose = hello.revoke == true ? "revoke" : "connect"
        let context: Data
        if requiresExchange {
            guard let phone = hello.exchange else {
                throw Refusal("The device didn't send an encryption key for this connection.")
            }
            context = phone
        } else {
            context = Data()
        }
        guard let key = pairings.key(for: hello.device),
            let device = pairings.devices().first(where: { $0.id == hello.device }),
            MobileLink.verify(hello.proof, key: key, device: hello.device, purpose: purpose, context: context)
        else {
            throw Refusal("This device isn't paired with this Mac. Pair it again from iMCP Settings.")
        }

        var macExchange: Data?
        var welcomeProof: String?
        var sessionKeys: (send: SymmetricKey, receive: SymmetricKey)?
        if requiresExchange, let phone = hello.exchange {
            let exchange = Curve25519.KeyAgreement.PrivateKey()
            let mac = exchange.publicKey.rawRepresentation
            do {
                sessionKeys = try MobileKeyExchange.sessionKeys(
                    privateKey: exchange,
                    peer: phone,
                    psk: key,
                    device: hello.device,
                    phone: phone,
                    mac: mac,
                    role: .mac
                )
            } catch {
                throw Refusal("The device sent an invalid connection key.")
            }
            macExchange = mac
            welcomeProof = MobileLink.proof(
                key: key,
                device: hello.device,
                purpose: "welcome:\(purpose)",
                context: phone + mac
            )
        }

        if hello.revoke == true {
            await unpair(hello.device)
            log.notice("\(hello.name, privacy: .public) removed its pairing")
            return (nil, makeWelcome(ok: true, exchange: macExchange, proof: welcomeProof), sessionKeys)
        }
        return (device, makeWelcome(ok: true, exchange: macExchange, proof: welcomeProof), sessionKeys)
    }

    private func accept(_ connection: NWConnection) async {
        let channel = MobileChannel(connection: connection)
        do {
            try await channel.open()
            // A phone on the tailnet reaches this listener through the Tailscale interface.
            let transportMode: MobileTransportMode =
                MobileTailnet.contains(connection.currentPath?.localEndpoint) ? .tailscaleVPN : .localOnly
            let hello = try await channel.read(MobileHello.self)
            let (device, welcome, _) = try await authenticate(hello)
            try await channel.write(welcome)
            guard let device else {
                await channel.disconnect()
                return
            }
            try await connectPeer(device: device, channel: channel, transportMode: transportMode)
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

    private func acceptLoopbackWebSocket(_ connection: NWConnection) async {
        let stream = MobileNWByteStream(connection: connection)
        do {
            try await stream.open(timeout: .seconds(15))
            let leftover = try await MobileWebSocketHandshake.accept(from: stream)
            let wire = MobileServerWebSocketWire(stream: stream, initialBuffer: leftover)
            await acceptWebSocket(wire, transportMode: .cloudflare)
        } catch {
            log.error("A tunnel WebSocket upgrade failed: \(error.localizedDescription, privacy: .public)")
            await stream.close()
        }
    }

    /// Accepts an upgraded WebSocket wire (from Tailscale Funnel or Cloudflare Tunnel).
    /// The phone has `helloTimeout` to send its hello and the Mac closes the connection if it doesn't.
    func acceptWebSocket(
        _ wire: any MobileFrameWire,
        transportMode: MobileTransportMode,
        helloTimeout: Duration = MobileService.helloTimeout
    ) async {
        do {
            let helloFrame = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    guard let frame = try await wire.receiveFrame() else {
                        throw MobileError("The WebSocket closed before sending hello.")
                    }
                    return frame
                }
                group.addTask {
                    try await Task.sleep(for: helloTimeout)
                    await wire.close()
                    throw MobileError("The phone didn't send its hello in time.")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            let hello = try MobileCoding.decoder.decode(MobileHello.self, from: helloFrame)
            let (device, welcome, keys) = try await authenticate(hello, requiresExchange: true)
            try await wire.sendFrame(try MobileCoding.encoder.encode(welcome))
            guard let device, let keys else {
                await wire.close()
                return
            }
            let channel = MobileEncryptedChannel(
                wire: wire,
                sendKey: keys.send,
                receiveKey: keys.receive,
                role: .mac
            )
            try await connectPeer(device: device, channel: channel, transportMode: transportMode)
        } catch let refusal as Refusal {
            lastPairingError = refusal.message
            log.error("Refused a WebSocket mobile connection: \(refusal.message, privacy: .public)")
            if let data = try? MobileCoding.encoder.encode(MobileWelcome(ok: false, error: refusal.message)) {
                try? await wire.sendFrame(data)
            }
            await wire.close()
        } catch {
            log.error("A WebSocket mobile connection failed: \(error.localizedDescription, privacy: .public)")
            await wire.close()
        }
    }

    private func connectPeer(
        device: MobileDevice,
        channel: any MobileTransportChannel,
        transportMode: MobileTransportMode
    ) async throws {
        do {
            let client = MCP.Client(name: "iMCP", version: Bundle.main.shortVersionString ?? "unknown")
            let result = try await client.connect(transport: channel)
            guard result.serverInfo.name == MobileLink.serverName else {
                throw MobileError("The connected app isn't iMCP for iOS.")
            }
            let link = MobileRemoteLink(
                device: device,
                client: client,
                channel: channel,
                transportMode: transportMode
            )
            await channel.setCloseHandler { [weak self] in
                await self?.detach(link)
                // Disconnecting the client fails its pending requests and stops its receive loop.
                await link.close()
            }
            if await attach(link) {
                log.notice(
                    "\(device.name, privacy: .public) connected via \(transportMode.shortLabel, privacy: .public)"
                )
            } else {
                log.notice("\(device.name, privacy: .public) opened a second connection; kept the live one")
            }
        } catch {
            await channel.disconnect()
            throw error
        }
    }

    // MARK: - Links

    /// Makes `link` the connection that calls go to, replacing any other.
    ///
    /// A second connection from the device that already has a live one
    /// (the app dials from two places at once) doesn't replace it
    /// while it still answers a quick status call,
    /// because replacing it would cancel the sync in progress and start the same fight again.
    /// A link that doesn't answer is stale, so the new one replaces it.
    /// Returns whether `link` is now the connection; if not, it has been closed.
    @discardableResult
    func attach(_ link: any MobilePeerLink) async -> Bool {
        if let current = self.link, current !== link, current.device.id == link.device.id,
            await current.answers(within: livenessTimeout), self.link === current
        {
            await link.close()
            return false
        }
        let previous = self.link
        self.link = link
        if let previous, previous !== link { Task { await previous.close() } }
        syncTask?.cancel()
        syncTask = Task { [weak self] in await self?.syncLoop(link) }
        return true
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
        await pushConfiguration(to: link)
        while !Task.isCancelled, self.link === link {
            // Activity first: it is small, and a long drain of queued batches
            // must not keep the phone's history empty if the connection is short.
            await syncActivity(link)
            await drain(link)
            try? await Task.sleep(for: pollInterval)
        }
    }

    // MARK: - Configuration

    /// Sends the current configuration to the connected phone, if there is one.
    func pushConfiguration() async {
        guard let link else { return }
        await pushConfiguration(to: link)
    }

    /// Calls `config_apply` on `link` and records the revision the phone says it holds.
    /// A phone from before configurations existed doesn't know the tool; that is not an error,
    /// because it still got the individual endpoints in its welcome.
    func pushConfiguration(to link: any MobilePeerLink) async {
        let configuration = currentConfiguration
        do {
            let request = MobileConfigApplyRequest(configuration: configuration)
            let arguments = try JSONDecoder().decode(
                [String: Value].self,
                from: MobileCoding.encoder.encode(request)
            )
            let text = try await link.call(MobileConfigLink.applyTool, arguments)
            let response = try MobileCoding.decoder.decode(MobileConfigApplyResponse.self, from: Data(text.utf8))
            ledger.recordApplied(response.revision, for: link.device.id)
        } catch is MobileLinkLost {
            detach(link)
        } catch {
            log.debug("Configuration push skipped or failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Activity History

    private func openActivityStore() throws -> MobileActivityStore {
        if let activityStore { return activityStore }
        let store = try activityStoreOpener()
        self.activityStore = store
        return store
    }

    /// Records a tool call in the Mac's activity history and pushes it to the connected phone.
    func recordActivity(_ event: MobileActivityEvent) async {
        guard let store = try? openActivityStore() else { return }
        _ = await store.record(event)
        if let link {
            await syncActivity(link)
        }
    }

    func activityEvents() async -> [MobileActivityEvent] {
        guard let store = try? openActivityStore() else { return [] }
        return await store.allEvents()
    }

    /// Pushes unsent activity events to `link` and records the phone's acknowledgement.
    func syncActivity(_ link: any MobilePeerLink) async {
        guard currentState.features.activityHistory else { return }
        // Open the store from disk: after a relaunch it holds events that no phone has received yet.
        guard let store = try? openActivityStore() else { return }
        if syncingActivity {
            needsActivitySync = true
            return
        }
        syncingActivity = true
        defer { syncingActivity = false }

        repeat {
            needsActivitySync = false
            while self.link === link {
                let pending = await store.pendingEvents(for: link.device.id)
                guard !pending.isEmpty else { break }
                do {
                    let request = MobileActivitySyncRequest(events: pending)
                    let arguments = try JSONDecoder().decode(
                        [String: Value].self,
                        from: MobileCoding.encoder.encode(request)
                    )
                    let text = try await link.call(MobileActivityLink.syncTool, arguments)
                    let response = try MobileCoding.decoder.decode(
                        MobileActivitySyncResponse.self,
                        from: Data(text.utf8)
                    )
                    let acked = response.ackedSequence > 0 ? response.ackedSequence : (pending.last?.sequence ?? 0)
                    await store.acknowledge(acked, for: link.device.id)
                } catch is MobileLinkLost {
                    detach(link)
                    return
                } catch {
                    log.debug("Activity sync skipped or failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
            }
        } while needsActivitySync && self.link === link
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
            // A newer connection or a disconnect cancels the sync; that isn't a failure.
            if error is CancellationError || Task.isCancelled {
                log.debug("Mobile sync cancelled")
            } else {
                log.error("Mobile sync failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Approvals

    /// Whether `device` is paired with this Mac.
    nonisolated func isPaired(_ device: String) -> Bool {
        pairings.devices().contains { $0.id == device }
    }

    /// Whether any iPhone or iPad is paired with this Mac.
    nonisolated var hasPairedDevice: Bool { !pairings.devices().isEmpty }

    /// Sends the Mac's open approvals to the connected phone and returns the answers it holds.
    /// The device ID comes from the phone's authenticated connection.
    /// Returns nil when no phone is connected or it doesn't answer.
    func syncApprovals(
        pending: [RemoteApprovalRequest],
        ack: [String]
    ) async -> (device: String, answers: [RemoteApprovalAnswer])? {
        guard let link else { return nil }
        do {
            let request = RemoteApprovalSyncRequest(pending: pending, ack: ack)
            let arguments = try JSONDecoder().decode(
                [String: Value].self,
                from: MobileCoding.encoder.encode(request)
            )
            let text = try await link.call(RemoteApprovalLink.syncTool, arguments)
            let response = try MobileCoding.decoder.decode(RemoteApprovalSyncResponse.self, from: Data(text.utf8))
            return (link.device.id, response.answers)
        } catch is MobileLinkLost {
            detach(link)
            return nil
        } catch {
            log.error("Approval sync failed: \(error.localizedDescription, privacy: .public)")
            return nil
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

/// Numbers the configuration that the Mac offers and remembers what each phone applied.
///
/// The revision goes up by one whenever the offer's content changes,
/// and the last content is kept so a relaunch with the same settings keeps the same revision.
struct MobileConfigurationLedger: @unchecked Sendable {
    let defaults: UserDefaults
    static let revisionKey = "mobileConfigRevision"
    static let contentKey = "mobileConfigContent"
    static let appliedKey = "mobileConfigApplied"

    var revision: Int { defaults.integer(forKey: Self.revisionKey) }

    func configuration(for state: MobileMacState) -> MobileConfiguration {
        let content = (try? MobileCoding.encoder.encode(MobileConfigurationBuilder.build(state, revision: 0))) ?? Data()
        var revision = self.revision
        if revision < 1 || defaults.data(forKey: Self.contentKey) != content {
            revision += 1
            defaults.set(revision, forKey: Self.revisionKey)
            defaults.set(content, forKey: Self.contentKey)
        }
        return MobileConfigurationBuilder.build(state, revision: revision)
    }

    func appliedRevision(for device: String) -> Int? {
        (defaults.dictionary(forKey: Self.appliedKey) as? [String: Int])?[device]
    }

    func recordApplied(_ revision: Int, for device: String) {
        var applied = (defaults.dictionary(forKey: Self.appliedKey) as? [String: Int]) ?? [:]
        applied[device] = revision
        defaults.set(applied, forKey: Self.appliedKey)
    }

    func forget(_ device: String) {
        var applied = (defaults.dictionary(forKey: Self.appliedKey) as? [String: Int]) ?? [:]
        applied[device] = nil
        defaults.set(applied, forKey: Self.appliedKey)
    }
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
    var transportMode: MobileTransportMode { get }
    /// Calls a tool on the phone and returns its JSON text.
    /// Throws `MobileLinkLost` if the connection ends before the answer arrives.
    func call(_ tool: String, _ input: [String: Value]) async throws -> String
    func close() async
}

extension MobilePeerLink {
    var transportMode: MobileTransportMode { .localOnly }

    /// Whether the phone answers a status call within `timeout`.
    /// Any reply, even an error from the phone, means the connection is alive.
    func answers(within timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    _ = try await self.call(MobileTools.statusTool, [:])
                    return true
                } catch is MobileLinkLost {
                    return false
                } catch is CancellationError {
                    return false
                } catch {
                    return true
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }
}

struct MobileLinkLost: Error, CustomStringConvertible {
    var description: String { "The connection to the iPhone or iPad was lost." }
}

/// The MCP client side of a connection that the phone opened.
final class MobileRemoteLink: MobilePeerLink, @unchecked Sendable {
    let device: MobileDevice
    let transportMode: MobileTransportMode
    private let client: MCP.Client
    private let channel: any MobileTransportChannel
    /// Live HealthKit queries can take a while on a large store.
    private static let timeout: Duration = .seconds(90)

    init(
        device: MobileDevice,
        client: MCP.Client,
        channel: any MobileTransportChannel,
        transportMode: MobileTransportMode = .localOnly
    ) {
        self.device = device
        self.client = client
        self.channel = channel
        self.transportMode = transportMode
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
                    if error is CancellationError { throw error }
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

/// The Mac's own Tailscale address, which a phone on the same tailnet can dial.
enum MobileTailnet {
    /// Whether an IPv4 address is in Tailscale's 100.64.0.0/10 range.
    static func isTailnetAddress(_ address: [UInt8]) -> Bool {
        address.count == 4 && address[0] == 100 && (address[1] & 0xC0) == 64
    }

    static func contains(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _) = endpoint, case .ipv4(let address) = host else { return false }
        return isTailnetAddress(Array(address.rawValue))
    }

    /// The first Tailscale IPv4 address on this Mac, or nil when Tailscale isn't connected.
    static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let socket = entry.ifa_addr, socket.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let bytes = socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
            }
            if isTailnetAddress(bytes) { return bytes.map(String.init).joined(separator: ".") }
        }
        return nil
    }
}
