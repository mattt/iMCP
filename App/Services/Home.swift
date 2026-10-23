import AppKit
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
/// that uses a key derived from the helper's pairing code,
/// and forwards each call as an MCP `tools/call` request.
actor HomeService: Service, HomeBackend {
    static let shared = HomeService()

    /// Thrown when iMCP has no pairing code for the helper, or the helper rejects it.
    enum PairingError: LocalizedError {
        case missing
        case rejected

        var errorDescription: String? {
            switch self {
            case .missing:
                "iMCP needs the pairing code from iMCP Helper's window. Enter it in Settings > Services > Home."
            case .rejected:
                "iMCP Helper rejected the pairing code. Enter the code from its window in Settings > Services > Home."
            }
        }
    }

    private static let outdatedHelperMessage =
        "iMCP Helper doesn't match this version of iMCP. Quit iMCP Helper, then rebuild it with Scripts/install-helper.sh."

    private let log = Logger.service("home")
    private let helperURL: URL?
    private let pairingCode: String?
    private let keychain = HomeHelperPairing.Keychain(service: "iMCP Helper pairing code")
    private var client: MCP.Client?
    private var connection: NWConnection?
    private var connecting: Task<Void, Error>?
    private var authorized = false
    private var helperPID: pid_t?

    /// Creates a service that uses `helperURL` instead of the helper that the user chose,
    /// and `pairingCode` instead of the code in the keychain.
    init(helperURL: URL? = nil, pairingCode: String? = nil) {
        self.helperURL = helperURL
        self.pairingCode = pairingCode
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

    /// Reconnects with the pairing code in the keychain.
    func usePairingCode() async throws {
        try await connect()
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
        // Launch the helper even without a code, so its window shows the code.
        let pid = try await launchHelper(overrideURL: helperURL)
        helperPID = pid
        guard let code = try pairingCode ?? keychain.read() else { throw PairingError.missing }
        let parameters = try HomeHelperPairing.parameters(code: code)
        let deadline = Date().addingTimeInterval(15)
        repeat {
            try await checkHelperIsRunning(pid)
            do {
                // Discover each time, because a new pairing code moves the helper to a new port.
                try await connect(to: discoverHelper(), parameters: parameters)
                return
            } catch let error as HomeError { throw error } catch let error as PairingError { throw error } catch {
                try await checkHelperIsRunning(pid)
                guard Date() < deadline else {
                    throw HomeError(
                        "iMCP Helper did not accept a local connection within 15 seconds. Check its status window, then retry."
                    )
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        } while true
    }

    /// Finds the helper's loopback endpoint in its local-only Bonjour advertisement,
    /// and checks the protocol version in its TXT record.
    private func discoverHelper() async throws -> NWEndpoint {
        let browser = NWBrowser(for: .bonjour(type: HomeHelperPairing.serviceType, domain: "local."), using: .tcp)
        let endpoint: NWEndpoint
        do {
            endpoint = try await BonjourDiscovery.discoverEndpoint(
                using: browser,
                timeout: .seconds(15),
                preferring: { String(describing: $0.endpoint).contains("iMCP Helper") }
            )
        } catch {
            throw HomeError(
                "iMCP Helper didn't appear on this Mac. Check its window, and allow it in System Settings > Privacy & Security > Local Network. \(error.localizedDescription)"
            )
        }
        guard case .service(let name, let type, let domain, _) = endpoint else {
            throw HomeError("iMCP Helper's Bonjour service has no name.")
        }
        let service = try await HelperResolution.resolve(name: name, type: type, domain: domain)
        guard service.protocolVersion == HomeHelperPairing.protocolVersion else {
            throw HomeError(Self.outdatedHelperMessage)
        }
        return .hostPort(host: .ipv4(.loopback), port: service.port)
    }

    /// Whether a connection failed its TLS handshake, which means the pairing codes differ.
    private nonisolated static func failedHandshake(_ state: NWConnection.State) -> Bool {
        switch state {
        case .waiting(.tls), .failed(.tls): true
        default: false
        }
    }

    private func connect(to endpoint: NWEndpoint, parameters: NWParameters) async throws {
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
            for _ in 0 ..< 80 {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return false }
                if case .waiting = connection.state { break }
            }
            let failedHandshake = Self.failedHandshake(connection.state)
            connection.cancel()
            await client.disconnect()
            return failedHandshake
        }
        defer { timeout.cancel() }
        do {
            let result = try await client.connect(transport: transport)
            guard result.serverInfo.name == "iMCP Helper" else {
                throw HomeError("The selected endpoint is not iMCP Helper.")
            }
            _ = try await forward(client, "homes_list", [:])
            self.client = client
            self.connection = connection
            authorized = true
            log.info("Connected to iMCP Helper")
        } catch {
            let failedHandshake = Self.failedHandshake(connection.state)
            timeout.cancel()
            let timedOutInHandshake = await timeout.value
            connection.cancel()
            await client.disconnect()
            if failedHandshake || timedOutInHandshake { throw PairingError.rejected }
            throw error
        }
    }

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

    /// Whether iMCP has a pairing code for the helper.
    nonisolated func hasPairingCode() -> Bool {
        pairingCode != nil || (try? keychain.read()) != nil
    }

    /// Asks for the pairing code from the helper's window and saves it in the keychain.
    /// Returns false when the user cancels.
    @MainActor
    func askForPairingCode(message: String) throws -> Bool {
        let alert = NSAlert()
        alert.messageText = "Pair with iMCP Helper"
        alert.informativeText = message
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "XXXXX-XXXXX-XXXXX-XXXXX"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            if let code = HomeHelperPairing.normalize(field.stringValue) {
                try keychain.save(code)
                return true
            }
            alert.informativeText =
                "That isn't a pairing code. Copy the code from iMCP Helper's window, then paste it here."
        }
        return false
    }

    /// Turns Home on for the user:
    /// asks for the helper if none is installed,
    /// then asks for the pairing code until the helper accepts one.
    /// Tool calls and reconnects never ask.
    /// Returns false when the user cancels.
    @MainActor
    func activateAskingUser() async throws -> Bool {
        guard try promptForHelperIfMissing() else { return false }
        var message = "Enter the pairing code shown in iMCP Helper's window."
        while true {
            do {
                try await activate()
                return true
            } catch PairingError.missing {
            } catch PairingError.rejected {
                message = "iMCP Helper rejected the pairing code. Enter the code shown in its window."
            }
            guard try askForPairingCode(message: message) else { return false }
        }
    }

    // MARK: - Helper Launch

    /// Returns the process ID of the running helper, after launching it if needed.
    @MainActor
    private func launchHelper(overrideURL: URL?) async throws -> pid_t {
        let url = overrideURL ?? helperLocation()
        if let running = NSWorkspace.shared.runningApplications.first(where: { application in
            !application.isTerminated
                && HomeHelperLocator.isRunningHelper(
                    bundleURL: application.bundleURL,
                    localizedName: application.localizedName,
                    helper: url,
                    isHelper: HomeHelperLocator.isHelper(at:)
                )
        }) {
            // Discovery checks the running helper's protocol version in its TXT record.
            return running.processIdentifier
        }
        guard let url else {
            throw HomeError(
                "iMCP Helper isn't installed. Build it with Scripts/install-helper.sh, then turn Home on again."
            )
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard HomeHelperLocator.protocolVersion(at: url) == HomeHelperPairing.protocolVersion else {
            throw HomeError(Self.outdatedHelperMessage)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
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

/// Resolves the helper's local-only Bonjour service to its port and protocol version.
///
/// `NWBrowser` doesn't report local-only services when it asks for TXT records,
/// so this resolves the service with DNS-SD.
@MainActor
final class HelperResolution {
    private var continuation: CheckedContinuation<(port: NWEndpoint.Port, protocolVersion: Int?), Error>?

    static func resolve(
        name: String,
        type: String,
        domain: String
    ) async throws -> (port: NWEndpoint.Port, protocolVersion: Int?) {
        let resolution = HelperResolution()
        var reference: DNSServiceRef?
        defer { if let reference { DNSServiceRefDeallocate(reference) } }
        let timeout = Task {
            try await Task.sleep(for: .seconds(5))
            resolution.finish(.failure(HomeError("iMCP Helper's Bonjour service didn't resolve within 5 seconds.")))
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
                        var valueLength: UInt8 = 0
                        let value = TXTRecordGetValuePtr(
                            length,
                            record,
                            HomeHelperPairing.protocolVersionTXTKey,
                            &valueLength
                        )
                        let version = value.flatMap {
                            Int(
                                String(
                                    decoding: UnsafeRawBufferPointer(start: $0, count: Int(valueLength)),
                                    as: UTF8.self
                                )
                            )
                        }
                        resolution.finish(.success((port, version)))
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

    private func finish(_ result: Result<(port: NWEndpoint.Port, protocolVersion: Int?), Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
