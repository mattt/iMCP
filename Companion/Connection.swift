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

    private static let account = "pairing"
    private static let keychainService = "co.dododo.iMCP.Companion"

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
            throw CompanionError("The Keychain refused the pairing (\(status)).")
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
        .service(name: service, type: CompanionLink.serviceType, domain: "local.", interface: nil)
    }
}

/// Keeps the phone connected to the paired Mac and serves the companion tools on that connection.
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

    @Published private(set) var phase: Phase = .unpaired
    @Published private(set) var credentials: PhoneCredentials? = PhoneCredentials.load()
    @Published private(set) var queuedBatches = 0

    private let log = Logger(subsystem: "co.dododo.iMCP.Companion", category: "connection")
    private var loop: Task<Void, Never>?
    private var channel: CompanionChannel?

    private init() {
        phase = credentials == nil ? .unpaired : .searching
    }

    static var deviceName: String { UIDevice.current.name }

    private var version: String { Bundle.main.shortVersionString ?? "unknown" }

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
        let channel = self.channel
        self.channel = nil
        Task { await channel?.disconnect() }
    }

    private func serve(_ credentials: PhoneCredentials) async throws {
        phase = .searching
        let channel = try await CompanionDialer.connect(
            to: credentials.endpoint,
            with: CompanionDialer.paired(
                device: credentials.device,
                name: Self.deviceName,
                key: SymmetricKey(data: credentials.key)
            )
        ).channel
        self.channel = channel
        phase = .connected
        defer { self.channel = nil }
        try await CompanionPeer.serve(channel, tools: PhoneBackend.shared.tools, version: version)
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

    /// Flushes while iOS lets the app finish the work after a background wake.
    func flushInBackground() async {
        let application = UIApplication.shared
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = application.beginBackgroundTask(withName: "Send changes to the Mac") {
            application.endBackgroundTask(identifier)
            identifier = .invalid
        }
        await flush()
        if identifier != .invalid { application.endBackgroundTask(identifier) }
    }

    private func performFlush(timeout: Duration) async -> Bool {
        guard let credentials else { return false }
        if await PhoneBackend.shared.pendingBatches == 0 { return true }
        // A foreground connection already serves the Mac's pulls.
        if channel != nil { return await waitForEmptyQueue(timeout: timeout) }
        do {
            let channel = try await CompanionDialer.connect(
                to: credentials.endpoint,
                with: CompanionDialer.paired(
                    device: credentials.device,
                    name: Self.deviceName,
                    key: SymmetricKey(data: credentials.key)
                ),
                timeout: .seconds(10)
            ).channel
            let tools = PhoneBackend.shared.tools
            let version = self.version
            let server = Task { try await CompanionPeer.serve(channel, tools: tools, version: version) }
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
    func pair(_ code: CompanionPairingCode) async throws {
        stop()
        let device = credentials?.device ?? UUID().uuidString
        let session = try await CompanionDialer.connect(
            to: NWEndpoint.service(
                name: code.service,
                type: CompanionLink.serviceType,
                domain: "local.",
                interface: nil
            ),
            with: CompanionDialer.pairing(code, device: device, name: Self.deviceName)
        )
        let channel = session.channel
        guard let key = session.deviceKey else {
            await channel.disconnect()
            throw CompanionError("Pairing didn't produce a device key. Show a new code and try again.")
        }
        let credentials = PhoneCredentials(device: device, key: key.withUnsafeBytes { Data($0) }, service: code.service)
        try credentials.save()
        // A new Mac has a new cache, which resets the outbox on its first pull.
        self.credentials = credentials
        self.channel = channel
        phase = .connected
        let tools = PhoneBackend.shared.tools
        let version = self.version
        loop = Task { [weak self] in
            try? await CompanionPeer.serve(channel, tools: tools, version: version)
            guard let self else { return }
            self.channel = nil
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
            // The Mac forgets the device when it can verify the request; if it's away,
            // the user can remove the phone in iMCP Settings.
            if let channel = try? await CompanionDialer.connect(
                to: credentials.endpoint,
                with: CompanionDialer.paired(
                    device: credentials.device,
                    name: Self.deviceName,
                    key: SymmetricKey(data: credentials.key),
                    revoke: true
                ),
                timeout: .seconds(5)
            ).channel {
                await channel.disconnect()
            }
        }
        PhoneCredentials.delete()
        try? await PhoneBackend.shared.openOutbox().deleteAll()
        self.credentials = nil
        phase = .unpaired
        await refreshQueue()
    }
}
