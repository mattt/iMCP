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

    @Published private(set) var phase: Phase = .unpaired
    @Published private(set) var credentials: PhoneCredentials? = PhoneCredentials.load()
    @Published private(set) var queuedBatches = 0

    private let log = Logger(subsystem: "co.dododo.iMCP.iOS", category: "connection")
    private var loop: Task<Void, Never>?
    private var channel: MobileChannel?

    private init() {
        phase = credentials == nil ? .unpaired : .searching
    }

    static var deviceName: String { UIDevice.current.name }

    private var version: String { Bundle.main.shortVersionString ?? "unknown" }

    // MARK: - Foreground

    /// The one dial in flight. The foreground loop, a background flush, and a refresh
    /// all join it instead of dialing their own, because the Mac treats two connections
    /// from one device as a conflict and the extra dial only delays the first.
    private var dialTask: Task<Void, Error>?
    /// Serves the Mac's calls on the current channel, until the channel closes.
    private var serveTask: Task<Void, Error>?
    private var connectionID = UUID()
    @Published private(set) var lastConnected: Date?
    @Published private(set) var isRefreshing = false

    /// Connects and reconnects until `stop()`.
    /// When the loop is already running but waiting out a backoff, it retries now.
    func start() {
        guard credentials != nil else { return }
        if loop != nil {
            reconnectNow()
            return
        }
        loop = Task { [weak self] in
            var delay: Duration = .seconds(1)
            while !Task.isCancelled, let self, self.credentials != nil {
                do {
                    try await self.ensureConnected(timeout: .seconds(15))
                    delay = .seconds(1)
                    try await self.serveTask?.value
                } catch {
                    if Task.isCancelled { break }
                    self.phase = .failed(error.localizedDescription)
                    self.log.error("Connection failed: \(error.localizedDescription, privacy: .public)")
                }
                await self.refreshQueue()
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(10))
                if self.credentials != nil, self.channel == nil { self.phase = .searching }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        dialTask?.cancel()
        dialTask = nil
        serveTask?.cancel()
        serveTask = nil
        let channel = self.channel
        self.channel = nil
        connectionID = UUID()
        Task { await channel?.disconnect() }
    }

    /// Returns once a channel is open, joining a dial that is already running.
    private func ensureConnected(timeout: Duration) async throws {
        if channel != nil { return }
        if let dialTask { return try await dialTask.value }
        guard let credentials else { throw MobileError("This device isn't paired with a Mac.") }
        phase = .searching
        let task = Task { try await self.establish(credentials, timeout: timeout) }
        dialTask = task
        defer { if dialTask == task { dialTask = nil } }
        try await task.value
    }

    private func establish(_ credentials: PhoneCredentials, timeout: Duration) async throws {
        let channel = try await MobileDialer.connect(
            to: credentials.endpoint,
            with: MobileDialer.paired(
                device: credentials.device,
                name: Self.deviceName,
                key: SymmetricKey(data: credentials.key)
            ),
            timeout: timeout
        ).channel
        try Task.checkCancellation()
        adopt(channel)
    }

    /// Makes `channel` the connection and serves the Mac's calls on it until it closes.
    private func adopt(_ channel: MobileChannel) {
        let id = UUID()
        connectionID = id
        self.channel = channel
        lastConnected = Date()
        phase = .connected
        let tools = PhoneBackend.shared.tools
        let version = self.version
        serveTask = Task { [weak self] in
            do {
                try await MobilePeer.serve(channel, tools: tools, version: version)
                self?.connectionEnded(id)
            } catch {
                self?.connectionEnded(id)
                throw error
            }
        }
    }

    private func connectionEnded(_ id: UUID) {
        guard connectionID == id else { return }
        channel = nil
        if credentials != nil, phase == .connected { phase = .searching }
    }

    /// Retries now instead of waiting out the backoff.
    private func reconnectNow() {
        guard credentials != nil, channel == nil, dialTask == nil else { return }
        loop?.cancel()
        loop = nil
        start()
    }

    func refreshQueue() async {
        queuedBatches = await PhoneBackend.shared.pendingBatches
    }

    /// Pull to refresh: collects changes, reuses the open connection (or retries the
    /// dial now), and returns within `limit` whatever the Mac or HealthKit is doing,
    /// leaving the status on screen to say what happened.
    func refresh(limit: Duration = .seconds(8)) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        reconnectNow()
        var collected = false
        Task { @MainActor in
            await PhoneBackend.shared.syncAll()
            collected = true
        }
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            let queued = await PhoneBackend.shared.pendingBatches
            queuedBatches = queued
            if collected, channel != nil, queued == 0 { break }
            if collected, channel == nil, case .failed = phase { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await refreshQueue()
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
        guard credentials != nil else { return false }
        if await PhoneBackend.shared.pendingBatches == 0 { return true }
        // Whoever holds the connection (the foreground loop, or this flush) serves the Mac's pulls.
        let owned = channel == nil && loop == nil
        do {
            try await ensureConnected(timeout: .seconds(10))
        } catch {
            log.error("Background sync couldn't reach the Mac: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let emptied = await waitForEmptyQueue(timeout: timeout)
        if owned, loop == nil {
            // A flush that opened the connection closes it; a foreground loop keeps its own.
            stop()
        }
        await refreshQueue()
        return emptied
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
        let session = try await MobileDialer.connect(
            to: NWEndpoint.service(
                name: code.service,
                type: MobileLink.serviceType,
                domain: "local.",
                interface: nil
            ),
            with: MobileDialer.pairing(code, device: device, name: Self.deviceName)
        )
        let channel = session.channel
        guard let key = session.deviceKey else {
            await channel.disconnect()
            throw MobileError("Pairing didn't produce a device key. Show a new code and try again.")
        }
        let credentials = PhoneCredentials(device: device, key: key.withUnsafeBytes { Data($0) }, service: code.service)
        try credentials.save()
        // A new Mac has a new cache, which resets the outbox on its first pull.
        self.credentials = credentials
        adopt(channel)
        loop = Task { [weak self] in
            try? await self?.serveTask?.value
            guard let self else { return }
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
            if let channel = try? await MobileDialer.connect(
                to: credentials.endpoint,
                with: MobileDialer.paired(
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
        PhoneActivityStore.shared.reset()
        phase = .unpaired
        await refreshQueue()
    }
}
