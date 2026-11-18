import AppKit
import Foundation
import MCP
import OSLog
import ServiceManagement

/// What iMCP needs from the launch agent that runs iMCP Helper.
/// `SMAppService` implements it; tests use a recording stand-in.
protocol HomeAgentControlling: Sendable {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
    func openLoginItemsSettings()
}

struct SMAppServiceAgent: HomeAgentControlling {
    let plistName: String

    private var service: SMAppService { SMAppService.agent(plistName: plistName) }
    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Serves the Home tools by calling the Catalyst helper that holds HomeKit access.
///
/// HomeKit is not available to native macOS apps,
/// so the helper runs as a separate Mac Catalyst app that iMCP embeds,
/// and implements the same tool definitions from `HomeTools`.
/// iMCP registers the helper as a per-user launch agent with `SMAppService`,
/// so launchd starts it in the user's login session, where it can show a window,
/// and connects to its Mach service with XPC.
/// Each side requires the other's code signature (same team, expected identifier),
/// so nothing has to be paired and no key is stored.
actor HomeService: Service, HomeBackend {
    static let shared = HomeService()

    /// Why Home can't be used yet, in words for Settings.
    enum SetupError: LocalizedError, Equatable {
        case notBundled
        case needsApproval
        case unsignedBuild
        case outdatedHelper
        case notReady(String)
        case registrationFailed(String)

        var errorDescription: String? {
            switch self {
            case .notBundled:
                "This build of iMCP doesn't include iMCP Helper. Use a build that embeds it, which needs a team with the HomeKit capability."
            case .needsApproval:
                "Allow iMCP in System Settings > General > Login Items & Extensions, then turn Home on again."
            case .unsignedBuild:
                "This build of iMCP isn't signed with a developer team, so it can't verify iMCP Helper. Sign it with your team, then turn Home on again."
            case .outdatedHelper:
                "iMCP Helper doesn't match this version of iMCP. Unregister it in Settings > Home, then register it again."
            case .notReady(let detail):
                "HomeKit isn't ready in iMCP Helper: \(detail) If macOS asks to allow Home access for iMCP Helper, allow it, then turn Home on again."
            case .registrationFailed(let message):
                "iMCP couldn't register iMCP Helper: \(message)"
            }
        }
    }

    /// A failure of the XPC connection, not of a tool.
    private struct ConnectionLost: Error {}

    private let log = Logger.service("home")
    private let bundleURL: URL
    private let appBundleIdentifier: String
    private let agent: any HomeAgentControlling
    private var connection: NSXPCConnection?
    private var connecting: Task<Void, Error>?
    /// The last reason that Home couldn't start, for Settings.
    private(set) var lastFailure: String?

    /// Creates a service for the iMCP at `bundleURL`.
    /// Tests pass their own bundle and agent.
    init(
        bundleURL: URL = Bundle.main.bundleURL,
        appBundleIdentifier: String = Bundle.main.bundleIdentifier ?? HomeHelperIdentity.defaultAppBundleIdentifier,
        agent: (any HomeAgentControlling)? = nil
    ) {
        self.bundleURL = bundleURL
        self.appBundleIdentifier = appBundleIdentifier
        self.agent =
            agent
            ?? SMAppServiceAgent(plistName: HomeHelperIdentity.agentPlistName(appBundleIdentifier: appBundleIdentifier))
    }

    // MARK: - Service

    nonisolated var tools: [Tool] { return HomeTools.tools(backend: self) }

    var isActivated: Bool { connection != nil }

    func activate() async throws {
        if isActivated { return }
        if let connecting { return try await connecting.value }
        let task = Task { try await self.connect() }
        connecting = task
        defer { connecting = nil }
        do {
            try await task.value
            lastFailure = nil
        } catch {
            lastFailure = error.localizedDescription
            throw error
        }
    }

    /// Turns Home on for the user. Returns false when macOS needs the user to allow the helper first,
    /// which `activate()` has already sent them to System Settings for.
    func activateAskingUser() async throws -> Bool {
        do {
            try await activate()
            return true
        } catch SetupError.needsApproval {
            return false
        }
    }

    // MARK: - Registration

    /// The agent's state, which Settings shows.
    nonisolated func state() -> HomeHelperLocator.State {
        HomeHelperLocator.state(
            isBundled: HomeHelperLocator.isBundled(in: bundleURL, appBundleIdentifier: appBundleIdentifier),
            status: agent.status
        )
    }

    /// Registers the launch agent if it isn't, and sends the user to Login Items if macOS wants approval.
    func register() throws {
        switch state() {
        case .notBundled: throw SetupError.notBundled
        case .registered: return
        case .needsApproval:
            agent.openLoginItemsSettings()
            throw SetupError.needsApproval
        case .notRegistered:
            do { try agent.register() } catch {
                // Registering can report requiresApproval as an error when the user hasn't allowed it yet.
                if agent.status == .requiresApproval {
                    agent.openLoginItemsSettings()
                    throw SetupError.needsApproval
                }
                throw SetupError.registrationFailed(error.localizedDescription)
            }
            if agent.status == .requiresApproval {
                agent.openLoginItemsSettings()
                throw SetupError.needsApproval
            }
        }
    }

    /// Ends the connection and unregisters the launch agent, which stops the helper.
    /// This replaces unpairing: there is no key to forget, so the clean slate is an unregistered agent.
    /// Register again (or turn Home on) to start over.
    func unregister() async throws {
        drop(connection)
        do { try await agent.unregister() } catch {
            // An agent that wasn't registered has nothing to remove.
            if agent.status != .notRegistered, agent.status != .notFound {
                throw SetupError.registrationFailed(error.localizedDescription)
            }
        }
    }

    // MARK: - HomeBackend

    func call(_ tool: String, _ input: [String: Value]) async throws -> Value {
        try await activate()
        guard let active = connection else { throw HomeError("iMCP Helper is not connected.") }
        do { return try await send(tool, input, over: active) } catch is ConnectionLost {
            drop(active)
            // A lost response does not prove that a write failed. Never duplicate a write.
            guard tools.first(where: { $0.name == tool })?.annotations.readOnlyHint == true else {
                throw HomeError(
                    "The iMCP Helper connection was lost. The write may have completed. Inspect the home before retrying."
                )
            }
            try await activate()
            guard let renewed = connection else { throw HomeError("iMCP Helper could not reconnect.") }
            do { return try await send(tool, input, over: renewed) } catch is ConnectionLost {
                drop(renewed)
                throw HomeError("iMCP Helper stopped answering. Turn Home off and on again.")
            }
        }
    }

    // MARK: - Connection

    private func send(_ tool: String, _ input: [String: Value], over connection: NSXPCConnection) async throws
        -> Value
    {
        let request = try JSONEncoder().encode(HomeXPCRequest(tool: tool, arguments: input))
        let reply = try await Self.ask(connection) { proxy, reply in proxy.callTool(request, reply: reply) }
        let response: HomeXPCResponse
        do { response = try JSONDecoder().decode(HomeXPCResponse.self, from: reply) } catch {
            throw HomeError("iMCP Helper returned an unreadable response.")
        }
        if let message = response.error { throw HomeError(message) }
        guard let text = response.result, let data = text.data(using: .utf8) else {
            throw HomeError("iMCP Helper returned no JSON text.")
        }
        do { return try JSONDecoder().decode(Value.self, from: data) } catch {
            throw HomeError("iMCP Helper returned invalid JSON: \(error.localizedDescription)")
        }
    }

    /// Calls the helper and returns its reply, or throws `ConnectionLost` if XPC fails first.
    private static func ask(
        _ connection: NSXPCConnection,
        _ call: (any HomeHelperXPC, @escaping @Sendable (Data) -> Void) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let lost: @Sendable (Error) -> Void = { _ in once.resume(throwing: ConnectionLost()) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler(lost) as? any HomeHelperXPC
            else {
                once.resume(throwing: ConnectionLost())
                return
            }
            call(proxy) { once.resume(returning: $0) }
        }
    }

    private func connect() async throws {
        drop(connection)
        try register()
        let helperURL = HomeHelperLocator.embeddedHelperURL(in: bundleURL)
        guard let helperIdentifier = HomeHelperLocator.helperBundleIdentifier(at: helperURL),
            let team = HomeHelperIdentity.ownTeamIdentifier(),
            let requirement = HomeHelperIdentity.helperRequirement(helperBundleIdentifier: helperIdentifier, team: team)
        else { throw SetupError.unsignedBuild }
        let newConnection = NSXPCConnection(
            machServiceName: HomeHelperIdentity.machServiceName(appBundleIdentifier: appBundleIdentifier),
            options: []
        )
        newConnection.remoteObjectInterface = NSXPCInterface(with: HomeHelperXPC.self)
        // The requirement checks the helper's signature before any message is accepted.
        newConnection.setCodeSigningRequirement(requirement)
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            Task { await self.connectionEnded(newConnection) }
        }
        newConnection.resume()
        do {
            try await waitUntilReady(over: newConnection)
        } catch {
            newConnection.invalidate()
            throw error
        }
        connection = newConnection
        log.info("Connected to iMCP Helper.")
    }

    /// Reads the helper's status until HomeKit is ready, for at most 30 seconds.
    /// launchd starts the helper on the first message, and HomeKit may need the user to allow access first.
    private func waitUntilReady(over connection: NSXPCConnection) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        var detail = "it didn't answer."
        while true {
            do {
                let reply = try await Self.ask(connection) { proxy, reply in proxy.status(reply: reply) }
                let status = try JSONDecoder().decode(HomeXPCStatus.self, from: reply)
                guard status.protocolVersion == HomeHelperIdentity.protocolVersion else {
                    throw SetupError.outdatedHelper
                }
                if status.homeKitReady { return }
                detail = status.detail ?? "it is still loading."
            } catch is ConnectionLost {
                // The helper may still be starting, or its signature failed the requirement.
                detail = "it didn't answer. Check that it is signed with the same team as iMCP."
            }
            guard clock.now < deadline else { throw SetupError.notReady(detail) }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func connectionEnded(_ ended: NSXPCConnection) {
        if connection === ended { connection = nil }
    }

    private func drop(_ dropped: NSXPCConnection?) {
        guard let dropped else { return }
        if connection === dropped { connection = nil }
        dropped.invalidate()
    }
}

/// Resumes a continuation once, whichever of an XPC reply and an XPC error comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }

    func resume(returning data: Data) { take()?.resume(returning: data) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        defer { continuation = nil }
        return continuation
    }
}
