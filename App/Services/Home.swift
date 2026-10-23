import AppKit
import CryptoKit
import MCP
import Network
import OSLog
import UniformTypeIdentifiers
import dnssd

/// Serves the Home tools by proxying to the Catalyst helper that holds HomeKit access.
///
/// HomeKit is not available to native macOS apps,
/// so the helper runs as a separate Catalyst app,
/// which developers build and sign with `Scripts/install-helper.sh`,
/// and implements the same tool definitions from `HomeTools`.
/// This service launches the helper if it isn't running, finds it with Bonjour,
/// connects to it over the loopback interface with TLS
/// that uses the key that iMCP sent when it paired with the helper,
/// and forwards each call as an MCP `tools/call` request.
/// See `HomeHelperPairing` for how iMCP pairs with the helper.
actor HomeService: Service, HomeBackend {
    static let shared = HomeService()

    /// Thrown when iMCP isn't paired with the helper, or the helper rejects iMCP's key or code.
    enum PairingError: LocalizedError {
        /// iMCP has no key.
        case missing
        /// The helper rejected iMCP's key, or it shows a code because it isn't paired.
        case rejected
        /// The helper rejected the pairing code.
        case codeRejected

        var errorDescription: String? {
            switch self {
            case .missing:
                "iMCP isn't paired with iMCP Helper. Choose Pair… in Settings > Services > Home, then enter the code from the helper's window."
            case .rejected:
                "iMCP Helper doesn't accept iMCP's pairing key. Choose Pair… in Settings > Services > Home, then enter the code from the helper's window."
            case .codeRejected:
                "iMCP Helper didn't accept the code. Check the code in its window, then try again."
            }
        }
    }

    /// What a connection to the helper is for.
    enum ConnectionPurpose: Sendable {
        /// Serve tool calls, with the key from pairing.
        case serve
        /// Send a new key over a pairing connection, with the key derived from the code.
        case pair(SymmetricKey)

        var isPairing: Bool {
            if case .pair = self { return true }
            return false
        }
    }

    private static let outdatedHelperMessage =
        "iMCP Helper doesn't match this version of iMCP. Quit iMCP Helper, then rebuild it with Scripts/install-helper.sh."

    private let log = Logger.service("home")
    private let helperURL: URL?
    private let keyStore: any HomeHelperKeyStore
    private var client: MCP.Client?
    private var connection: NWConnection?
    private var connecting: Task<Void, Error>?
    private var authorized = false
    private var helperPID: pid_t?

    /// Creates a service that uses `helperURL` instead of the helper that the user chose,
    /// and keeps its pairing key in `keyStore`.
    init(helperURL: URL? = nil, keyStore: any HomeHelperKeyStore = HomeHelperPairing.Keychain.app) {
        self.helperURL = helperURL
        self.keyStore = keyStore
    }

    // MARK: - Service

    nonisolated var tools: [Tool] { return HomeTools.tools(backend: self) }

    var isActivated: Bool { authorized && connection?.state == .ready }

    func activate() async throws {
        if isActivated { return }
        if let connecting { return try await connecting.value }
        let task = Task { try await self.connect() }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    /// Switches an active Home service to a newly chosen helper.
    /// Quits the running helper, then reconnects,
    /// which launches the chosen one.
    func useChosenHelper() async throws {
        guard isActivated else { return }
        if let helperPID { try await quitHelper(pid: helperPID) }
        helperPID = nil
        try await connect()
    }

    /// Reconnects with the pairing key in the keychain.
    func reconnect() async throws {
        try await connect()
    }

    /// Pairs with the helper that shows `code`:
    /// sends a new key over a pairing connection and saves the key.
    /// Call `activate()` or `reconnect()` afterward to connect with the key.
    func pair(code: String) async throws {
        let pid = try await launchHelper(overrideURL: helperURL, activates: true)
        helperPID = pid
        let parameters = try HomeHelperPairing.pairingParameters(code: code)
        let paired: HelperCandidate
        do {
            paired = try await connectToHelper(
                pid: pid,
                parameters: parameters,
                purpose: .pair(HomeHelperPairing.generateKey())
            )
        } catch PairingError.rejected {
            throw PairingError.codeRejected
        }
        // The helper listens with the key once the pairing connection ends.
        // Until it advertises that, a connection would count as a rejected key.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while clock.now < deadline {
            let candidates = await HelperResolution.discover(until: min(clock.now + .seconds(1), deadline))
            if candidates.contains(where: { $0.processID == paired.processID && !$0.isPairing }) { return }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Quits a helper and waits until it has exited,
    /// so a reconnect doesn't find it instead of the chosen one.
    @MainActor
    private func quitHelper(pid: pid_t) async throws {
        guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else {
            return
        }
        application.terminate()
        for _ in 0 ..< 50 {
            if application.isTerminated { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        application.forceTerminate()
        for _ in 0 ..< 20 {
            if application.isTerminated { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HomeError("The previous iMCP Helper didn't quit. Quit it, then turn Home off and on again.")
    }

    // MARK: - HomeBackend

    func call(_ tool: String, _ input: [String: Value]) async throws -> Value {
        try await activate()
        guard let active = client else { throw HomeError("iMCP Helper is not connected.") }
        do { return try await forward(active, tool, input) } catch let error as HomeError { throw error } catch {
            if client === active {
                authorized = false
                client = nil
                connection?.cancel()
                connection = nil
                await active.disconnect()
            }
            try await activate()
            // A lost response does not prove that a write failed. Never duplicate a write.
            guard tools.first(where: { $0.name == tool })?.annotations.readOnlyHint == true
            else {
                throw HomeError(
                    "The iMCP Helper connection was lost. The write may have completed. Inspect the home before retrying."
                )
            }
            guard let client else { throw HomeError("iMCP Helper could not reconnect.") }
            return try await forward(client, tool, input)
        }
    }

    // MARK: - Connection

    private func forward(_ client: MCP.Client, _ tool: String, _ input: [String: Value]) async throws -> Value {
        let connection = self.connection
        let monitor = Task {
            guard let connection else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                switch connection.state {
                case .failed, .cancelled, .waiting:
                    await client.disconnect()
                    return
                default: break
                }
            }
        }
        defer { monitor.cancel() }
        let result = try await client.callTool(name: tool, arguments: input)
        let texts = result.content.compactMap { item -> String? in
            if case .text(let text, _, _) = item { return text }
            return nil
        }
        if result.isError == true { throw HomeError(texts.joined(separator: "\n")) }
        guard let text = texts.first, let data = text.data(using: .utf8) else {
            throw HomeError("iMCP Helper returned no JSON text.")
        }
        do { return try JSONDecoder().decode(Value.self, from: data) } catch {
            throw HomeError("iMCP Helper returned invalid JSON: \(error.localizedDescription)")
        }
    }

    private func connect() async throws {
        authorized = false
        let old = client
        client = nil
        connection?.cancel()
        connection = nil
        await old?.disconnect()
        let key = try keyStore.read()
        // Launch the helper even without a key, and bring it forward, so its window shows the code.
        let pid = try await launchHelper(overrideURL: helperURL, activates: key == nil)
        helperPID = pid
        guard let key else { throw PairingError.missing }
        try await connectToHelper(pid: pid, parameters: HomeHelperPairing.parameters(key: key), purpose: .serve)
    }

    /// Connects to the helper with `pid` or, failing that, to another helper on this Mac,
    /// and returns the advertisement that it connected to.
    @discardableResult
    private func connectToHelper(
        pid: pid_t,
        parameters: NWParameters,
        purpose: ConnectionPurpose
    ) async throws -> HelperCandidate {
        // One deadline bounds discovery, resolution, and every connection attempt.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(15)
        var log = HelperAttemptLog()
        repeat {
            try await checkHelperIsRunning(pid)
            // Discover each time, because a new pairing code moves the helper to a new port.
            let candidates = await HelperResolution.discover(until: deadline)
            // Try the helper that iMCP launched or found running first, then any other.
            // Only the TLS handshake decides whether a helper can be trusted.
            let ordered = candidates.filter { $0.processID == pid } + candidates.filter { $0.processID != pid }
            var chosenAttempts: [HelperAttempt] = []
            var otherAttempts: [String: HelperAttempt] = [:]
            for candidate in ordered where clock.now < deadline {
                // Don't try a code again with a helper that rejected it, so it doesn't count as another failure.
                if candidate.processID != pid, log.others[candidate.name] == .rejected { continue }
                let attempt: HelperAttempt
                if candidate.protocolVersion != HomeHelperPairing.protocolVersion {
                    attempt = .outdated
                } else if candidate.isPairing != purpose.isPairing {
                    // A helper that shows a code accepts only pairing, and a paired helper only its key.
                    attempt = .rejected
                } else {
                    do {
                        try await connect(
                            to: .hostPort(host: .ipv4(.loopback), port: candidate.port),
                            parameters: parameters,
                            deadline: deadline,
                            purpose: purpose
                        )
                        return candidate
                    } catch let error as HomeError {
                        // The handshake succeeded, so this is a paired helper, and its error stands.
                        throw error
                    } catch PairingError.rejected {
                        attempt = .rejected
                    } catch {
                        attempt = .unavailable
                    }
                }
                if candidate.processID == pid {
                    chosenAttempts.append(attempt)
                } else {
                    otherAttempts[candidate.name] = attempt
                }
            }
            log.record(chosen: chosenAttempts, others: otherAttempts)
            try await checkHelperIsRunning(pid)
            if let failure = log.failure(deadlinePassed: false) { throw failure }
            try await Task.sleep(until: min(clock.now + .milliseconds(250), deadline), clock: clock)
        } while clock.now < deadline
        // Decide from the stored results instead of starting a pass after the deadline.
        throw log.failure(deadlinePassed: true) ?? HomeError("iMCP Helper didn't accept a connection.")
    }

    /// The latest results from each helper during one connection operation.
    struct HelperAttemptLog {
        /// The chosen helper's latest results, kept while it briefly stops advertising,
        /// as it does when the user makes a new code.
        private(set) var chosen: [HelperAttempt] = []
        /// Other helpers' latest results by Bonjour service name.
        private(set) var others: [String: HelperAttempt] = [:]

        /// Records one discovery pass.
        /// Results replace older ones from the same helper, and helpers that didn't appear keep theirs.
        mutating func record(chosen roundChosen: [HelperAttempt], others roundOthers: [String: HelperAttempt]) {
            if !roundChosen.isEmpty { chosen = roundChosen }
            others.merge(roundOthers) { _, new in new }
        }

        func failure(deadlinePassed: Bool) -> Error? {
            HomeService.connectionFailure(
                chosen.map { (chosen: true, attempt: $0) } + others.values.map { (chosen: false, attempt: $0) },
                deadlinePassed: deadlinePassed
            )
        }
    }

    /// What happened when iMCP tried one helper advertisement.
    enum HelperAttempt: Equatable {
        /// The helper doesn't declare the current protocol version.
        case outdated
        /// The helper failed the TLS handshake, so its pairing code differs.
        case rejected
        /// The helper refused the connection or didn't answer.
        case unavailable
    }

    /// Chooses the error to report after no helper accepted a connection,
    /// or returns nil to keep looking.
    /// The results from the chosen helper decide as soon as all of them are final,
    /// and at the deadline if it advertised at all;
    /// other helpers' results decide only at the deadline, and only if it didn't.
    /// Then an outdated helper comes first, because a helper from before pairing
    /// doesn't advertise its process ID, so it may be the chosen one.
    nonisolated static func connectionFailure(
        _ attempts: [(chosen: Bool, attempt: HelperAttempt)],
        deadlinePassed: Bool
    ) -> Error? {
        let chosen = attempts.filter(\.chosen).map(\.attempt)
        if !chosen.isEmpty, !chosen.contains(.unavailable) {
            return chosen.contains(.rejected) ? PairingError.rejected : HomeError(outdatedHelperMessage)
        }
        guard deadlinePassed else { return nil }
        if chosen.isEmpty {
            let others = attempts.map(\.attempt)
            if others.contains(.outdated) { return HomeError(outdatedHelperMessage) }
            if others.contains(.rejected) { return PairingError.rejected }
        } else if chosen.contains(.rejected) {
            return PairingError.rejected
        } else if chosen.contains(.outdated) {
            return HomeError(outdatedHelperMessage)
        }
        if attempts.isEmpty {
            return HomeError(
                "iMCP Helper didn't appear on this Mac. Check its window, and allow it in System Settings > Privacy & Security > Local Network."
            )
        }
        return HomeError(
            "iMCP Helper did not accept a local connection within 15 seconds. Check its status window, then retry."
        )
    }

    /// Whether a connection failed its TLS handshake, which means the pairing codes differ.
    private nonisolated static func failedHandshake(_ state: NWConnection.State) -> Bool {
        switch state {
        case .waiting(.tls), .failed(.tls): true
        default: false
        }
    }

    /// Connects to one helper.
    /// The TLS handshake and `initialize` must finish by `deadline`;
    /// the first HomeKit read, or the pairing request, then has its own limit.
    func connect(
        to endpoint: NWEndpoint,
        parameters: NWParameters,
        deadline: ContinuousClock.Instant,
        purpose: ConnectionPurpose = .serve
    ) async throws {
        let connection = NWConnection(to: endpoint, using: parameters)
        let transport = NetworkTransport(
            connection: connection,
            heartbeatConfig: .init(enabled: false),
            reconnectionConfig: .disabled,
            bufferConfig: .unlimited
        )
        let client = MCP.Client(name: "iMCP", version: Bundle.main.shortVersionString ?? "unknown")
        let timeout = Task { () -> Bool in
            // NetworkTransport waits indefinitely in NWConnection.waiting.
            // Retry refused connections while the helper starts.
            let clock = ContinuousClock()
            // A peer that doesn't finish the TLS handshake in five seconds isn't a working helper.
            let handshakeDeadline = min(clock.now + .seconds(5), deadline)
            while clock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
                if case .waiting = connection.state { break }
                if clock.now >= handshakeDeadline, connection.state != .ready { break }
            }
            let failedHandshake = Self.failedHandshake(connection.state)
            connection.cancel()
            await client.disconnect()
            return failedHandshake
        }
        defer { timeout.cancel() }
        var probe: Task<Bool, Never>?
        defer { probe?.cancel() }
        do {
            let result = try await client.connect(transport: transport)
            guard result.serverInfo.name == "iMCP Helper" else {
                throw HomeError("The selected endpoint is not iMCP Helper.")
            }
            // Network.framework also accepts its default PSK suites, which lack forward secrecy.
            guard HomeHelperPairing.usesCipherSuite(connection) else {
                throw HomeError(
                    "iMCP Helper didn't use an ECDHE-PSK cipher suite. Rebuild it with Scripts/install-helper.sh."
                )
            }
            // Only a helper with the key or code gets past the handshake and initialize.
            // Its first HomeKit read can wait for a person to answer the HomeKit prompt,
            // which the helper ends after 10 seconds, so it has its own limit, not the shared deadline.
            timeout.cancel()
            _ = await timeout.value
            let limit = purpose.isPairing ? Self.pairingLimit : Self.firstReadLimit
            probe = Task {
                do { try await Task.sleep(for: limit) } catch { return false }
                connection.cancel()
                await client.disconnect()
                return true
            }
            switch purpose {
            case .serve:
                _ = try await forward(client, "homes_list", [:])
                self.client = client
                self.connection = connection
                authorized = true
                log.info("Connected to iMCP Helper")
            case .pair(let key):
                // Save the key first: if the response is lost but the helper saved the key,
                // iMCP still has it; if the helper didn't, the next connection asks for a new code.
                try keyStore.save(key)
                do {
                    let data = key.withUnsafeBytes { Data($0) }
                    _ = try await client.send(HomeHelperPairing.Pair.request(.init(key: data))).value
                } catch {
                    throw HomeError("iMCP Helper didn't accept the pairing: \(error.localizedDescription)")
                }
                connection.cancel()
                await client.disconnect()
                log.info("Paired with iMCP Helper")
            }
        } catch {
            let failedHandshake = Self.failedHandshake(connection.state)
            timeout.cancel()
            let timedOutInHandshake = await timeout.value
            probe?.cancel()
            let timedOutInFirstRead = await probe?.value ?? false
            connection.cancel()
            await client.disconnect()
            if failedHandshake || timedOutInHandshake { throw PairingError.rejected }
            if timedOutInFirstRead {
                throw HomeError(
                    purpose.isPairing
                        ? "iMCP Helper didn't answer the pairing request. Check its window, then try again."
                        : "iMCP Helper didn't answer within 20 seconds. Check its window for HomeKit access, then retry."
                )
            }
            throw error
        }
    }

    /// How long the pairing request can take after the handshake.
    private static let pairingLimit = Duration.seconds(5)

    /// How long the first HomeKit read through a paired helper can take.
    private static let firstReadLimit = Duration.seconds(20)

    // MARK: - Helper Launch

    @MainActor
    private func checkHelperIsRunning(_ pid: pid_t) throws {
        guard pid > 0,
            let application = NSRunningApplication(processIdentifier: pid),
            !application.isTerminated
        else {
            throw HomeError(
                "iMCP Helper exited before the connection was ready. Check its crash report in Console, then retry."
            )
        }
    }

    private static let bookmarkKey = "homeHelperBookmark"

    /// The helper chosen in the open panel, if its bookmark still resolves.
    @MainActor
    private func chosenHelperURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    /// The helper that iMCP would launch now, or nil if none is installed.
    @MainActor
    func helperLocation() -> URL? {
        let chosen = chosenHelperURL()
        let accessing = chosen?.startAccessingSecurityScopedResource() ?? false
        defer { if accessing { chosen?.stopAccessingSecurityScopedResource() } }
        return HomeHelperLocator.resolve(
            chosen: chosen,
            installed: HomeHelperLocator.installLocations,
            registered: NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: HomeHelperLocator.defaultBundleIdentifier
            ),
            embedded: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/iMCP Helper.app"),
            isHelper: HomeHelperLocator.isHelper(at:)
        )
    }

    /// Asks the user to choose iMCP Helper.app and remembers the choice.
    /// Returns nil when the user cancels.
    @MainActor
    func chooseHelper() throws -> URL? {
        let panel = NSOpenPanel()
        panel.message =
            "Choose iMCP Helper.app. To build it, run Scripts/install-helper.sh from the iMCP repository."
        panel.prompt = "Use Helper"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard HomeHelperLocator.isHelper(at: url) else {
            throw HomeError(
                "\(url.lastPathComponent) isn't iMCP Helper. Build the helper with Scripts/install-helper.sh, then choose it."
            )
        }
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        return url
    }

    /// Asks for the helper when the user turns Home on and none is installed.
    /// Tool calls and reconnects never show the panel.
    /// Returns false when the user cancels.
    @MainActor
    func promptForHelperIfMissing() throws -> Bool {
        if helperLocation() != nil { return true }
        return try chooseHelper() != nil
    }

    // MARK: - Pairing

    /// Whether iMCP has a pairing key for the helper.
    nonisolated func hasPairingKey() -> Bool {
        (try? keyStore.read()) != nil
    }

    /// Asks for the code from the helper's window.
    /// Returns nil when the user cancels.
    @MainActor
    func askForPairingCode(message: String) async -> String? {
        let alert = NSAlert()
        alert.messageText = "Pair with iMCP Helper"
        alert.informativeText = message
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Show iMCP Helper")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "XXXX-XXXX"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        while true {
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if let code = HomeHelperPairing.normalize(field.stringValue) { return code }
                alert.informativeText =
                    "That isn't a pairing code. A code has eight letters and digits, such as 7KQ2-M9XD."
            case .alertThirdButtonReturn:
                await showHelper()
            default:
                return nil
            }
        }
    }

    /// Turns Home on for the user:
    /// asks for the helper if none is installed,
    /// then asks for a code and pairs until the helper accepts iMCP's key.
    /// Tool calls and reconnects never ask.
    /// Returns false when the user cancels.
    @MainActor
    func activateAskingUser() async throws -> Bool {
        guard try promptForHelperIfMissing() else { return false }
        var message = "Enter the code shown in iMCP Helper's window."
        while true {
            do {
                try await activate()
                return true
            } catch PairingError.missing {
            } catch PairingError.rejected {
                message =
                    "iMCP Helper doesn't accept iMCP's pairing key. Enter the code shown in its window to pair again."
            }
            while true {
                guard let code = await askForPairingCode(message: message) else { return false }
                do {
                    try await pair(code: code)
                    break
                } catch PairingError.codeRejected {
                    message =
                        "That code didn't work. Enter the code shown in iMCP Helper's window. After \(HomeHelperPairing.failedPairingLimit) wrong codes, it shows a new one."
                }
            }
        }
    }

    /// Brings the helper's window to the front, launching the helper if needed.
    @MainActor
    func showHelper() async {
        _ = try? await launchHelper(overrideURL: helperURL, activates: true)
    }

    // MARK: - Helper Launch

    /// Returns the process ID of the running helper, after launching it if needed.
    /// With `activates`, also brings the helper to the front.
    @MainActor
    private func launchHelper(overrideURL: URL?, activates: Bool) async throws -> pid_t {
        let url = overrideURL ?? helperLocation()
        let accessing = url?.startAccessingSecurityScopedResource() ?? false
        defer { if accessing { url?.stopAccessingSecurityScopedResource() } }
        if let running = NSWorkspace.shared.runningApplications.first(where: { application in
            !application.isTerminated
                && HomeHelperLocator.isRunningHelper(
                    bundleURL: application.bundleURL,
                    localizedName: application.localizedName,
                    helper: url,
                    isHelper: HomeHelperLocator.isHelper(at:)
                )
        }) {
            // A helper from before pairing doesn't advertise its process ID,
            // so check its Info.plist instead of waiting for its advertisement.
            guard let bundleURL = running.bundleURL else {
                throw HomeError("iMCP can't find the running iMCP Helper's app bundle. Quit iMCP Helper, then retry.")
            }
            guard try HomeHelperLocator.protocolVersion(at: bundleURL) == HomeHelperPairing.protocolVersion else {
                throw HomeError(Self.outdatedHelperMessage)
            }
            if activates { _ = running.activate(from: .current) }
            return running.processIdentifier
        }
        guard let url else {
            throw HomeError(
                "iMCP Helper isn't installed. Build it with Scripts/install-helper.sh, then turn Home on again."
            )
        }
        guard try HomeHelperLocator.protocolVersion(at: url) == HomeHelperPairing.protocolVersion else {
            throw HomeError(Self.outdatedHelperMessage)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        // Xcode's native macOS debugger libraries cannot load in a Catalyst app.
        // Empty values override the launch environment; omitting the keys does not.
        // A sandboxed iMCP can't set the environment, but unsigned Debug builds aren't sandboxed.
        configuration.environment = [
            "DYLD_INSERT_LIBRARIES": "",
            "DYLD_LIBRARY_PATH": "",
            "DYLD_FRAMEWORK_PATH": "",
        ]
        return try await NSWorkspace.shared.openApplication(at: url, configuration: configuration).processIdentifier
    }
}

/// A helper's local-only Bonjour advertisement, resolved to its port and TXT record.
struct HelperCandidate: Equatable, Sendable {
    /// The Bonjour service name, which identifies the helper between discovery passes.
    let name: String
    let port: NWEndpoint.Port
    let protocolVersion: Int?
    let processID: pid_t?
    /// Whether the helper shows a pairing code.
    var isPairing = false
}

/// Where iMCP keeps its pairing key.
protocol HomeHelperKeyStore: Sendable {
    func read() throws -> SymmetricKey?
    func save(_ key: SymmetricKey) throws
}

extension HomeHelperPairing.Keychain: HomeHelperKeyStore {}

/// Finds and resolves the helpers' local-only Bonjour advertisements.
///
/// `NWBrowser` doesn't report local-only services when it asks for TXT records,
/// so this browses without them and resolves each service with DNS-SD.
@MainActor
final class HelperResolution {
    private let name: String
    private var continuation: CheckedContinuation<HelperCandidate, Error>?

    private init(name: String) { self.name = name }

    /// Browses for helpers on this Mac and resolves each one at the same time.
    /// Waits up to three seconds for the first advertisement, then briefly for others,
    /// and stops at `deadline`.
    static func discover(until deadline: ContinuousClock.Instant) async -> [HelperCandidate] {
        let browser = NWBrowser(for: .bonjour(type: HomeHelperPairing.serviceType, domain: "local."), using: .tcp)
        defer { browser.cancel() }
        browser.start(queue: .main)
        let clock = ContinuousClock()
        let browseDeadline = min(clock.now + .seconds(3), deadline)
        var firstSeen: ContinuousClock.Instant?
        while clock.now < browseDeadline {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            guard browser.browseResults.contains(where: BonjourDiscovery.isLocal) else { continue }
            if let firstSeen, clock.now - firstSeen >= .milliseconds(300) { break }
            firstSeen = firstSeen ?? clock.now
        }
        let services = browser.browseResults.filter(BonjourDiscovery.isLocal).compactMap {
            result -> (name: String, type: String, domain: String)? in
            guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
            return (name, type, domain)
        }
        return await withTaskGroup(of: HelperCandidate?.self) { group in
            for service in services {
                group.addTask {
                    try? await resolve(name: service.name, type: service.type, domain: service.domain, until: deadline)
                }
            }
            var candidates: [HelperCandidate] = []
            for await candidate in group {
                if let candidate { candidates.append(candidate) }
            }
            return candidates
        }
    }

    /// Resolves one service, giving up after five seconds or at `deadline`.
    static func resolve(
        name: String,
        type: String,
        domain: String,
        until deadline: ContinuousClock.Instant = .now + .seconds(5)
    ) async throws -> HelperCandidate {
        let resolution = HelperResolution(name: name)
        var reference: DNSServiceRef?
        defer { if let reference { DNSServiceRefDeallocate(reference) } }
        let timeout = Task {
            try await Task.sleep(until: min(.now + .seconds(5), deadline), clock: .continuous)
            resolution.finish(.failure(HomeError("iMCP Helper's Bonjour service didn't resolve in time.")))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            resolution.continuation = continuation
            let status = DNSServiceResolve(
                &reference,
                0,
                kDNSServiceInterfaceIndexLocalOnly,
                name,
                type,
                domain,
                { _, _, _, error, _, _, port, length, record, context in
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        let resolution = Unmanaged<HelperResolution>.fromOpaque(context).takeUnretainedValue()
                        guard error == kDNSServiceErr_NoError,
                            let port = NWEndpoint.Port(rawValue: UInt16(bigEndian: port))
                        else {
                            resolution.finish(
                                .failure(HomeError("iMCP Helper's Bonjour service didn't resolve (\(error))."))
                            )
                            return
                        }
                        func value(_ key: String) -> String? {
                            var valueLength: UInt8 = 0
                            guard let value = TXTRecordGetValuePtr(length, record, key, &valueLength) else {
                                return nil
                            }
                            let bytes = UnsafeRawBufferPointer(start: value, count: Int(valueLength))
                            return String(decoding: bytes, as: UTF8.self)
                        }
                        resolution.finish(
                            .success(
                                HelperCandidate(
                                    name: resolution.name,
                                    port: port,
                                    protocolVersion: value(HomeHelperPairing.protocolVersionTXTKey).flatMap { Int($0) },
                                    processID: value(HomeHelperPairing.processIDTXTKey).flatMap { pid_t($0) },
                                    isPairing: value(HomeHelperPairing.pairingTXTKey) == "1"
                                )
                            )
                        )
                    }
                },
                Unmanaged.passUnretained(resolution).toOpaque()
            )
            guard status == kDNSServiceErr_NoError, let reference else {
                resolution.finish(.failure(HomeError("iMCP Helper's Bonjour service didn't resolve (\(status)).")))
                return
            }
            let queueStatus = DNSServiceSetDispatchQueue(reference, .main)
            if queueStatus != kDNSServiceErr_NoError {
                resolution.finish(.failure(HomeError("iMCP Helper's Bonjour service didn't resolve (\(queueStatus)).")))
            }
        }
    }

    private func finish(_ result: Result<HelperCandidate, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
