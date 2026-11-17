import CryptoKit
import Foundation
import Network
import OSLog
import Security
import UIKit

/// What the phone keeps after pairing: its device ID and key, and which Mac it paired with.
struct PhoneCredentials: Codable, Equatable, Sendable {
    var device: String
    var key: Data
    /// The Mac's Bonjour service name.
    var service: String
    var tailnetHost: String?
    var tailnetPort: UInt16?
    var funnelURL: String?
    var cloudflareURL: String?

    private static let account = "pairing"
    private static let keychainService = "co.dododo.iMCP.iOS"

    static func load() -> PhoneCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(PhoneCredentials.self, from: data)
    }

    func save() throws {
        Self.delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.account,
            // Background delivery can run while the phone is locked after its first unlock.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: try JSONEncoder().encode(self),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MobileError("The Keychain refused the pairing (\(status)).")
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    var macName: String {
        service.hasPrefix("iMCP on ") ? String(service.dropFirst("iMCP on ".count)) : service
    }

    var endpoint: NWEndpoint {
        .service(name: service, type: MobileLink.serviceType, domain: "local.", interface: nil)
    }

    func updating(from welcome: MobileWelcome) -> PhoneCredentials {
        var copy = self
        if let host = welcome.tailnetHost, !host.isEmpty {
            copy.tailnetHost = host
        }
        if let port = welcome.tailnetPort, port > 0 {
            copy.tailnetPort = port
        }
        if let funnel = MobileLink.normalizedWebSocketURL(welcome.funnelURL) {
            copy.funnelURL = funnel
        }
        if let cloudflare = MobileLink.normalizedWebSocketURL(welcome.cloudflareURL) {
            copy.cloudflareURL = cloudflare
        }
        return copy
    }
}

/// Keeps the device connected to the paired Mac and serves the mobile tools on that connection.
///
/// The phone dials the Mac, because iOS suspends apps and can't accept connections reliably.
/// While the app is open, it reconnects whenever the connection drops.
/// When iOS wakes the app in the background, it connects once,
/// waits until the Mac has pulled the queued changes, and disconnects.
@MainActor
final class PhoneConnection: ObservableObject {
    static let shared = PhoneConnection()

    enum Phase: Equatable {
        case unpaired
        case searching
        case connected
        case failed(String)
    }

    private static let transportModeDefaultsKey = "mobile.transportMode"

    @Published private(set) var phase: Phase = .unpaired
    @Published private(set) var credentials: PhoneCredentials? = PhoneCredentials.load()
    @Published private(set) var queuedBatches = 0
    @Published private(set) var activeTransport: MobileTransportMode?
    @Published private(set) var transportMode: MobileTransportMode

    private let log = Logger(subsystem: "co.dododo.iMCP.iOS", category: "connection")
    private var loop: Task<Void, Never>?
    private var channel: (any MobileTransportChannel)?

    private init() {
        let storedMode =
            MobileAppGroup.defaults.string(forKey: Self.transportModeDefaultsKey)
            .flatMap(MobileTransportMode.init(rawValue:)) ?? .automatic
        self.transportMode = storedMode
        phase = credentials == nil ? .unpaired : .searching
    }

    static var deviceName: String { UIDevice.current.name }

    private var version: String { Bundle.main.shortVersionString ?? "unknown" }

    // MARK: - Transport Configuration

    func setTransportMode(_ mode: MobileTransportMode) {
        guard mode != transportMode else { return }
        transportMode = mode
        MobileAppGroup.defaults.set(mode.rawValue, forKey: Self.transportModeDefaultsKey)
        restartIfNeeded()
    }

    func updateEndpoints(
        tailnetHost: String?,
        tailnetPort: UInt16?,
        funnelURL: String?,
        cloudflareURL: String?
    ) throws {
        guard var current = credentials else { return }
        let trimmedHost = tailnetHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        current.tailnetHost = (trimmedHost?.isEmpty == false) ? trimmedHost : nil
        current.tailnetPort = (tailnetPort ?? 0) > 0 ? tailnetPort : nil
        current.funnelURL = MobileLink.normalizedWebSocketURL(funnelURL)
        current.cloudflareURL = MobileLink.normalizedWebSocketURL(cloudflareURL)
        try current.save()
        credentials = current
        restartIfNeeded()
    }

    private func restartIfNeeded() {
        guard credentials != nil, loop != nil else { return }
        stop()
        start()
    }

    // MARK: - Foreground

    /// Connects and reconnects until `stop()`.
    func start() {
        guard loop == nil, credentials != nil else { return }
        loop = Task { [weak self] in
            var delay: Duration = .seconds(1)
            while !Task.isCancelled, let self, let credentials = self.credentials {
                do {
                    try await self.serve(credentials)
                    delay = .seconds(1)
                } catch {
                    if Task.isCancelled { break }
                    self.phase = .failed(error.localizedDescription)
                    self.log.error("Connection failed: \(error.localizedDescription, privacy: .public)")
                }
                await self.refreshQueue()
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(30))
                if self.credentials != nil { self.phase = .searching }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        activeTransport = nil
        let channel = self.channel
        self.channel = nil
        Task { await channel?.disconnect() }
    }

    private func serve(_ credentials: PhoneCredentials) async throws {
        phase = .searching
        let result = try await dial(
            transportMode.candidates(
                service: credentials.service,
                tailnetHost: credentials.tailnetHost,
                tailnetPort: credentials.tailnetPort,
                funnelURL: credentials.funnelURL,
                cloudflareURL: credentials.cloudflareURL
            ),
            mode: transportMode,
            device: credentials.device,
            key: SymmetricKey(data: credentials.key)
        )
        let updated = credentials.updating(from: result.welcome)
        if updated != credentials {
            try? updated.save()
            self.credentials = updated
        }
        self.channel = result.channel
        self.activeTransport = result.transport
        phase = .connected
        defer {
            self.channel = nil
            self.activeTransport = nil
        }
        try await MobilePeer.serve(result.channel, tools: PhoneBackend.shared.tools, version: version)
    }

    func refreshQueue() async {
        queuedBatches = await PhoneBackend.shared.pendingBatches
    }

    // MARK: - Background

    private var flushing: Task<Bool, Never>?

    /// Connects long enough for the Mac to pull queued changes.
    /// Returns whether the queue emptied before `timeout`.
    /// Calls that arrive during a flush share it rather than dialing again.
    @discardableResult
    func flush(timeout: Duration = .seconds(20)) async -> Bool {
        if let flushing { return await flushing.value }
        let task = Task { await performFlush(timeout: timeout) }
        flushing = task
        let flushed = await task.value
        flushing = nil
        return flushed
    }

    private func performFlush(timeout: Duration) async -> Bool {
        guard let credentials else { return false }
        if await PhoneBackend.shared.pendingBatches == 0 { return true }
        // A foreground connection already serves the Mac's pulls.
        if channel != nil { return await waitForEmptyQueue(timeout: timeout) }
        do {
            let result = try await dial(
                transportMode.candidates(
                    service: credentials.service,
                    tailnetHost: credentials.tailnetHost,
                    tailnetPort: credentials.tailnetPort,
                    funnelURL: credentials.funnelURL,
                    cloudflareURL: credentials.cloudflareURL
                ),
                mode: transportMode,
                device: credentials.device,
                key: SymmetricKey(data: credentials.key),
                timeout: .seconds(10)
            )
            let channel = result.channel
            let tools = PhoneBackend.shared.tools
            let version = self.version
            let server = Task { try await MobilePeer.serve(channel, tools: tools, version: version) }
            let emptied = await waitForEmptyQueue(timeout: timeout)
            await channel.disconnect()
            server.cancel()
            await refreshQueue()
            return emptied
        } catch {
            log.error("Background sync couldn't reach the Mac: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func waitForEmptyQueue(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if await PhoneBackend.shared.pendingBatches == 0 { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    // MARK: - Pairing

    /// Pairs with the Mac that shows `code`, then keeps serving on that connection.
    func pair(_ code: MobilePairingCode) async throws {
        stop()
        let device = credentials?.device ?? UUID().uuidString
        let candidates = transportMode.candidates(for: code)
        let result = try await dial(
            candidates,
            mode: transportMode,
            pairing: code,
            device: device,
            key: nil
        )
        let channel = result.channel
        guard let key = result.deviceKey else {
            await channel.disconnect()
            throw MobileError("Pairing didn't produce a device key. Show a new code and try again.")
        }
        let credentials = PhoneCredentials(
            device: device,
            key: key.withUnsafeBytes { Data($0) },
            service: code.service,
            tailnetHost: code.tailnetHost,
            tailnetPort: code.tailnetPort,
            funnelURL: code.funnelURL,
            cloudflareURL: code.cloudflareURL
        ).updating(from: result.welcome)
        try credentials.save()
        // A new Mac has a new cache, which resets the outbox on its first pull.
        self.credentials = credentials
        self.channel = channel
        self.activeTransport = result.transport
        phase = .connected
        let tools = PhoneBackend.shared.tools
        let version = self.version
        loop = Task { [weak self] in
            try? await MobilePeer.serve(channel, tools: tools, version: version)
            guard let self else { return }
            self.channel = nil
            self.activeTransport = nil
            self.loop = nil
            self.start()
        }
    }

    /// Forgets the Mac, asks it to forget this phone if it's reachable,
    /// and clears queued changes.
    func unpair() async {
        let credentials = self.credentials
        stop()
        if let credentials {
            let candidates = transportMode.candidates(
                service: credentials.service,
                tailnetHost: credentials.tailnetHost,
                tailnetPort: credentials.tailnetPort,
                funnelURL: credentials.funnelURL,
                cloudflareURL: credentials.cloudflareURL
            )
            // The Mac forgets the device when it can verify the request; if it's away,
            // the user can remove the phone in iMCP Settings.
            if let result = try? await dial(
                candidates,
                mode: transportMode,
                device: credentials.device,
                key: SymmetricKey(data: credentials.key),
                revoke: true,
                timeout: .seconds(5)
            ) {
                await result.channel.disconnect()
            }
        }
        PhoneCredentials.delete()
        try? await PhoneBackend.shared.openOutbox().deleteAll()
        PhoneActivityStore.shared.reset()
        self.credentials = nil
        self.activeTransport = nil
        phase = .unpaired
        await refreshQueue()
    }

    // MARK: - Multi-Transport Dialer

    private struct DialResult {
        var channel: any MobileTransportChannel
        var transport: MobileTransportMode
        var welcome: MobileWelcome
        var deviceKey: SymmetricKey?
    }

    private func dial(
        _ candidates: [MobileTransportCandidate],
        mode: MobileTransportMode,
        pairing: MobilePairingCode? = nil,
        device: String,
        key: SymmetricKey?,
        revoke: Bool = false,
        timeout: Duration = .seconds(15)
    ) async throws -> DialResult {
        guard !candidates.isEmpty else {
            throw MobileError(
                "No endpoint is configured for \(mode.shortLabel). Configure it in Connection Settings or pair again."
            )
        }
        var lastError: Error?
        for (index, candidate) in candidates.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let isLast = index == candidates.count - 1
            let candidateTimeout: Duration =
                (!isLast && candidate.mode == .localOnly) ? min(timeout, .seconds(5)) : timeout
            do {
                switch candidate {
                case .bonjour(let service):
                    let endpoint = NWEndpoint.service(
                        name: service,
                        type: MobileLink.serviceType,
                        domain: "local.",
                        interface: nil
                    )
                    let session = try await connectNW(
                        endpoint: endpoint,
                        pairing: pairing,
                        device: device,
                        key: key,
                        revoke: revoke,
                        timeout: candidateTimeout
                    )
                    return DialResult(
                        channel: session.channel,
                        transport: .localOnly,
                        welcome: session.welcome,
                        deviceKey: session.deviceKey
                    )

                case .tailscaleVPN(let host, let port):
                    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                        throw MobileError("Invalid Tailscale port \(port).")
                    }
                    let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
                    let session = try await connectNW(
                        endpoint: endpoint,
                        pairing: pairing,
                        device: device,
                        key: key,
                        revoke: revoke,
                        timeout: candidateTimeout
                    )
                    return DialResult(
                        channel: session.channel,
                        transport: .tailscaleVPN,
                        welcome: session.welcome,
                        deviceKey: session.deviceKey
                    )

                case .tailscaleFunnel(let url), .cloudflare(let url):
                    let creds: MobileDialer.Credentials
                    if let pairing {
                        creds = MobileWebSocketDialer.pairing(pairing, device: device, name: Self.deviceName)
                    } else if let key {
                        creds = MobileWebSocketDialer.paired(
                            device: device,
                            name: Self.deviceName,
                            key: key,
                            revoke: revoke
                        )
                    } else {
                        throw MobileError("Missing device credentials.")
                    }
                    let session = try await MobileWebSocketDialer.connect(
                        to: url,
                        with: creds,
                        timeout: candidateTimeout
                    )
                    return DialResult(
                        channel: session.channel,
                        transport: candidate.mode,
                        welcome: session.welcome,
                        deviceKey: session.deviceKey
                    )
                }
            } catch {
                lastError = error
            }
        }
        throw lastError ?? MobileError("Couldn't reach the Mac.")
    }

    private func connectNW(
        endpoint: NWEndpoint,
        pairing: MobilePairingCode?,
        device: String,
        key: SymmetricKey?,
        revoke: Bool,
        timeout: Duration
    ) async throws -> MobileDialer.Session {
        let creds: MobileDialer.Credentials
        if let pairing {
            creds = MobileDialer.pairing(pairing, device: device, name: Self.deviceName)
        } else if let key {
            creds = MobileDialer.paired(device: device, name: Self.deviceName, key: key, revoke: revoke)
        } else {
            throw MobileError("Missing device credentials.")
        }
        return try await MobileDialer.connect(to: endpoint, with: creds, timeout: timeout)
    }
}
