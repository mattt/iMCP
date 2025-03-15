import AppKit
import Logging
import MCP
import Network
import OSLog
import SwiftUI
import SystemPackage

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

private let serviceType = "_mcp._tcp"
private let serviceDomain = "local."

private let log = Logger.server

@MainActor
final class ServerUIHandler: ObservableObject {
    @Published var serverStatus: String = "Starting..."
    @Published var pendingConnectionID: String?

    // Network manager reference
    private var networkManager: ServerNetworkManager?

    func setNetworkManager(_ manager: ServerNetworkManager) {
        self.networkManager = manager
    }

    func updateServerStatus(_ status: String) {
        log.info("Server status updated: \(status)")
        self.serverStatus = status
    }

    func showConnectionApprovalAlert(
        clientID: String, approve: @escaping () -> Void, deny: @escaping () -> Void
    ) {
        log.notice("Connection approval requested for client: \(clientID)")
        self.pendingConnectionID = clientID

        let alert = NSAlert()
        alert.messageText = "Client Connection Request"
        alert.informativeText =
            "A client is requesting to connect to the MCP server. Do you want to allow this connection?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")

        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            log.notice("Connection approved for client: \(clientID)")
            approve()
        } else {
            log.notice("Connection denied for client: \(clientID)")
            deny()
        }
    }

    func clearPendingConnection() {
        log.debug("Clearing pending connection")
        self.pendingConnectionID = nil
    }

    func approveConnection(connectionID: UUID, clientID: String) {
        log.notice(
            "Approving connection for client: \(clientID), ID: \(connectionID)")
        Task {
            await networkManager?.approveConnection(connectionID: connectionID, clientID: clientID)
        }
    }

    func denyConnection(connectionID: UUID) {
        log.notice("Denying connection: \(connectionID)")
        Task {
            await networkManager?.denyConnection(connectionID: connectionID)
        }
    }
}

actor ServerNetworkManager {
    private var isRunning: Bool = false
    private var isEnabled: Bool = true
    private var listener: NWListener
    private var browser: NWBrowser
    private var connections: [UUID: NWConnection] = [:]
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingConnections: [UUID: String] = [:]
    private var mcpServers: [UUID: MCP.Server] = [:]

    // Connection approval handler
    typealias ConnectionApprovalHandler = @Sendable (UUID, String) async -> Bool
    private var connectionApprovalHandler: ConnectionApprovalHandler?

    private let services: [any Service] = [
        CalendarService.shared,
        ContactsService.shared,
        LocationService.shared,
        MessageService.shared,
        RemindersService.shared,
        UtilitiesService.shared,
        WeatherService.shared,
    ]

    // Service toggle bindings
    private var serviceBindings: [String: Binding<Bool>]

    init(serviceBindings: [String: Binding<Bool>]) throws {
        self.serviceBindings = serviceBindings
        // Set up Bonjour service
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.attribution = .user
        parameters.includePeerToPeer = true

        if let tcpOptions = parameters.defaultProtocolStack.internetProtocol
            as? NWProtocolIP.Options
        {
            tcpOptions.version = .v4
        }

        // Create the listener with service discovery
        listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(type: serviceType, domain: serviceDomain)

        // Set up browser for debugging/monitoring
        browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: serviceDomain),
            using: parameters
        )

        log.info(
            "Network manager initialized with Bonjour service type: \(serviceType)")
    }

    func setConnectionApprovalHandler(_ handler: @escaping ConnectionApprovalHandler) {
        log.debug("Setting connection approval handler")
        self.connectionApprovalHandler = handler
    }

    func approveConnection(connectionID: UUID, clientID: String) async {
        log.notice(
            "Processing approved connection for client: \(clientID), ID: \(connectionID)"
        )

        guard let connection = connections[connectionID] else {
            log.error("Connection not found for ID: \(connectionID)")
            return
        }

        // Create and configure MCP server for this connection
        let logger = Logger(label: "com.loopwork.mcp-server.\(connectionID)")
        let transport = NetworkTransport(connection: connection, logger: logger)

        // Create the MCP server with capabilities
        let server = MCP.Server(
            name: Bundle.main.name ?? "iMCP",
            version: Bundle.main.shortVersionString ?? "unknown",
            capabilities: MCP.Server.Capabilities(
                tools: .init(listChanged: true)
            )
        )

        // Register prompts/list handler
        await server.withMethodHandler(ListPrompts.self) { _ in
            log.debug("Handling ListPrompts request")

            return ListPrompts.Result(prompts: [])
        }

        // Register the resources/list handler
        await server.withMethodHandler(ListResources.self) { _ in
            log.debug("Handling ListResources request")

            return ListResources.Result(resources: [])
        }

        // Register tools/list handler
        await server.withMethodHandler(ListTools.self) { [self] _ in
            log.debug("Handling ListTools request")

            var tools: [MCP.Tool] = []
            if await self.isEnabled {
                for service in await self.services {
                    //                    let serviceKey = String(describing: type(of: service))
                    //                    if let binding = await self.serviceBindings[serviceKey],
                    //                        binding.wrappedValue,
                    //                        await service.isActivated
                    //                    {
                    for tool in service.tools {
                        tools.append(
                            .init(
                                name: tool.name,
                                description: tool.description,
                                inputSchema: tool.inputSchema
                            )
                        )
                    }
                    //                    }
                }
            }

            log.info("Returning \(tools.count) available tools")
            return ListTools.Result(tools: tools)
        }

        // Register tools/call handler
        await server.withMethodHandler(CallTool.self) { [self] params in
            log.notice("Tool call received: \(params.name)")

            guard await self.isEnabled else {
                log.notice("Tool call rejected: iMCP is disabled")
                return CallTool.Result(
                    content: [
                        .text("iMCP is currently disabled. Please enable it to use tools.")
                    ],
                    isError: true
                )
            }

            for service in await self.services {
//                let serviceKey = String(describing: type(of: service))
//                if let binding = await self.serviceBindings[serviceKey],
//                    binding.wrappedValue,
//                    await service.isActivated
//                {
                    do {
                        if let value = try await service.call(
                            tool: params.name,
                            with: params.arguments ?? [:]
                        ) {
                            log.notice("Tool \(params.name) executed successfully")
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                            
                            let data = try encoder.encode(value)
                            
                            
                            let text = String(data: data, encoding: .utf8)!
                            
                            return CallTool.Result(content: [.text(text)], isError: false)
                        }
                    } catch {
                        log.error(
                            "Error executing tool \(params.name): \(error.localizedDescription)"
                        )
                        return CallTool.Result(content: [.text("Error: \(error)")], isError: true)
                    }
//                }
            }

            log.error("Tool not found or service not enabled: \(params.name)")
            return CallTool.Result(
                content: [.text("Tool not found or service not enabled: \(params.name)")],
                isError: true
            )
        }

        // Store the server
        mcpServers[connectionID] = server

        // Start the server with the transport
        Task {
            do {
                log.notice("Starting MCP server for connection: \(connectionID)")
                try await server.start(transport: transport)
                log.notice(
                    "MCP Server started successfully for connection: \(connectionID)")

                if !self.isEnabled {
                    log.info("iMCP is disabled, notifying new client")
                    try await server.notify(ToolListChangedNotification.message())
                }
            } catch {
                log.error(
                    "Failed to start MCP server: \(error.localizedDescription)")
                _removeConnection(connectionID)
            }
        }
    }

    // Deny a pending connection
    func denyConnection(connectionID: UUID) async {
        print("NetworkManager: Denying connection: \(connectionID)")

        // Clean up the connection
        _removeConnection(connectionID)
    }

    // Debug method to test the connection approval flow
    func testConnectionApproval(clientID: String) async -> Bool {
        log.debug("Testing connection approval for client: \(clientID)")

        let connectionID = UUID()
        pendingConnections[connectionID] = clientID

        guard let handler = connectionApprovalHandler else {
            log.warning("No approval handler set, test failed")
            return false
        }

        log.debug("Calling approval handler")
        let result = await handler(connectionID, clientID)
        log.info("Approval test result: \(result ? "Approved" : "Denied")")
        return result
    }

    func start() async {
        log.info("Starting network manager")
        isRunning = true
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                log.info("Server ready and advertising via Bonjour")
            case .failed(let error):
                log.error("Server failed: \(error)")
            default:
                return
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.handleNewConnection(connection)
            }
        }

        listener.start(queue: .main)
        browser.start(queue: .main)
    }

    func stop() async {
        log.info("Stopping network manager")
        isRunning = false

        // Stop all MCP servers
        for (_, server) in mcpServers {
            Task {
                await server.stop()
            }
        }

        // Cancel all connections
        for (id, connection) in connections {
            log.debug("Cancelling connection: \(id)")
            connectionTasks[id]?.cancel()
            connection.cancel()
        }

        listener.cancel()
        browser.cancel()
    }

    nonisolated func removeConnection(_ id: UUID) {
        Task {
            await _removeConnection(id)
        }
    }

    private func _removeConnection(_ id: UUID) {
        log.debug("Removing connection: \(id)")
        // Stop the MCP server if it exists
        if let server = mcpServers[id] {
            Task {
                await server.stop()
            }
            mcpServers.removeValue(forKey: id)
        }

        if let task = connectionTasks[id] {
            task.cancel()
            connectionTasks.removeValue(forKey: id)
        }

        if let connection = connections[id] {
            connection.cancel()
            connections.removeValue(forKey: id)
        }

        pendingConnections.removeValue(forKey: id)
    }

    // Handle new incoming connections
    private func handleNewConnection(_ connection: NWConnection) async {
        let connectionID = UUID()
        log.info("Handling new connection: \(connectionID)")
        connections[connectionID] = connection

        let clientID = "client-\(connectionID.uuidString.prefix(8))"
        pendingConnections[connectionID] = clientID

        // Set up connection state handler
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                log.debug("Connection ready")
                Task {
                    if let self = self {
                        await self.processConnection(
                            connectionID: connectionID, clientID: clientID, connection: connection)
                    }
                }
            case .failed(let error):
                log.error("Connection failed: \(error)")
                // Use Task to handle actor-isolated property access
                Task {
                    await self?._removeConnection(connectionID)
                }
            case .cancelled:
                log.info("Connection cancelled")
                Task {
                    await self?._removeConnection(connectionID)
                }
            default:
                return
            }
        }

        connection.start(queue: .main)
    }

    // Process a new connection - identify client and request approval
    private func processConnection(connectionID: UUID, clientID: String, connection: NWConnection)
        async
    {
        log.info("Processing new connection: \(connectionID) for client: \(clientID)")

        var approved = false
        if let approvalHandler = connectionApprovalHandler {
            log.debug("Requesting approval for client: \(clientID)")
            approved = await approvalHandler(connectionID, clientID)
            log.info(
                "Approval result for client \(clientID): \(approved ? "Approved" : "Denied")")
        } else {
            log.warning("No approval handler set, defaulting to denied")
        }

        if !approved {
            connection.cancel()
            _removeConnection(connectionID)
        }
    }

    // Update the enabled state and notify clients
    func setEnabled(_ enabled: Bool) async {
        // Only do something if the state actually changes
        guard isEnabled != enabled else { return }

        isEnabled = enabled
        log.info("iMCP enabled state changed to: \(enabled)")

        // Notify all connected clients that the tool list has changed
        for (connectionID, server) in mcpServers {
            // Check if the connection is still active before sending notification
            if let connection = connections[connectionID], connection.state == .ready {
                Task {
                    do {
                        log.info(
                            "Notified client that tool list changed. Tools are now \(enabled ? "enabled" : "disabled")"
                        )
                        try await server.notify(ToolListChangedNotification.message())
                    } catch {
                        log.error("Failed to notify client of tool list change: \(error)")

                        // If the error is related to connection issues, clean up the connection
                        if let nwError = error as? NWError,
                            nwError.errorCode == 57  // Socket is not connected
                                || nwError.errorCode == 54
                        {  // Connection reset by peer
                            log.debug("Connection appears to be closed, removing it")
                            _removeConnection(connectionID)
                        }
                    }
                }
            } else {
                log.debug("Connection \(connectionID) is no longer active, removing it")
                _removeConnection(connectionID)
            }
        }
    }

    // Update service bindings
    func updateServiceBindings(_ newBindings: [String: Binding<Bool>]) {
        log.info("Notifying clients of tool list update")
        self.serviceBindings = newBindings
        // Notify clients that tool availability may have changed
        Task {
            for (_, server) in mcpServers {
                try? await server.notify(ToolListChangedNotification.message())
            }
        }
    }
}

// Main class that combines UI and network functionality for SwiftUI
@MainActor
final class ServerManager: ObservableObject {
    // The UI handler is the observable object that SwiftUI will use
    @Published var uiHandler: ServerUIHandler

    // The network manager handles all the network operations
    private let networkManager: ServerNetworkManager

    init() {
        print("Initializing ServerManager")

        // Create the UI handler first (on the main actor)
        self.uiHandler = ServerUIHandler()

        // Create the network manager with empty initial bindings
        self.networkManager = try! ServerNetworkManager(serviceBindings: [:])
        print("Network manager created")

        // Set the network manager in the UI handler
        self.uiHandler.setNetworkManager(self.networkManager)

        // Set up the connection approval handler
        Task {
            print("Setting up connection approval handler")
            await networkManager.setConnectionApprovalHandler {
                [weak self] connectionID, clientID in
                guard let self = self else {
                    print("Self is nil in approval handler, denying connection")
                    return false
                }

                print("ServerManager: Approval handler called for client \(clientID)")

                // Create a continuation to wait for the user's response
                return await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        self.uiHandler.showConnectionApprovalAlert(
                            clientID: clientID,
                            approve: {
                                Task { @MainActor in
                                    self.uiHandler.approveConnection(
                                        connectionID: connectionID, clientID: clientID)
                                    continuation.resume(returning: true)
                                }
                            },
                            deny: {
                                Task { @MainActor in
                                    self.uiHandler.denyConnection(connectionID: connectionID)
                                    continuation.resume(returning: false)
                                }
                            }
                        )
                    }
                }
            }
            print("Connection approval handler set")
        }

        // Start the server
        Task {
            await self.networkManager.start()
            self.uiHandler.updateServerStatus("Running")
        }
    }

    func updateServiceBindings(_ bindings: [String: Binding<Bool>]) async {
        await networkManager.updateServiceBindings(bindings)
    }

    // Expose the UI properties directly for convenience
    var serverStatus: String { uiHandler.serverStatus }
    var pendingConnectionID: String? { uiHandler.pendingConnectionID }

    // Start and stop the server
    func startServer() async {
        await networkManager.start()
        uiHandler.updateServerStatus("Running")
    }

    func stopServer() async {
        await networkManager.stop()
        uiHandler.updateServerStatus("Stopped")
    }

    // Test the connection approval flow
    func testConnectionApproval(clientID: String) async -> Bool {
        print("ServerManager: Testing connection approval for client: \(clientID)")
        return await networkManager.testConnectionApproval(clientID: clientID)
    }

    // Update the enabled state
    func setEnabled(_ enabled: Bool) async {
        await networkManager.setEnabled(enabled)
        uiHandler.updateServerStatus(enabled ? "Running" : "Disabled")
    }
}
