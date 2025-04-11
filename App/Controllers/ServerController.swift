import AppKit
import Logging
import MCP
import Network
import OSLog
import Ontology
import SwiftUI
import SystemPackage

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

private let serviceType = "_mcp._tcp"
private let serviceDomain = "local."

private let log = Logger.server

struct ServiceConfig: Identifiable {
    let id: String
    let name: String
    let iconName: String
    let color: Color
    let service: any Service
    let binding: Binding<Bool>

    var isActivated: Bool {
        get async {
            await service.isActivated
        }
    }

    init(
        name: String,
        iconName: String,
        color: Color,
        service: any Service,
        binding: Binding<Bool>
    ) {
        self.id = String(describing: type(of: service))
        self.name = name
        self.iconName = iconName
        self.color = color
        self.service = service
        self.binding = binding
    }
}

enum ServiceRegistry {
    static let services: [any Service] = [
        CalendarService.shared,
        ContactsService.shared,
        LocationService.shared,
        MapsService.shared,
        MessageService.shared,
        RemindersService.shared,
        UtilitiesService.shared,
        WeatherService.shared,
    ]

    static func configureServices(
        calendarEnabled: Binding<Bool>,
        contactsEnabled: Binding<Bool>,
        locationEnabled: Binding<Bool>,
        mapsEnabled: Binding<Bool>,
        messagesEnabled: Binding<Bool>,
        remindersEnabled: Binding<Bool>,
        utilitiesEnabled: Binding<Bool>,
        weatherEnabled: Binding<Bool>
    ) -> [ServiceConfig] {
        [
            ServiceConfig(
                name: "Calendar",
                iconName: "calendar",
                color: .red,
                service: CalendarService.shared,
                binding: calendarEnabled
            ),
            ServiceConfig(
                name: "Contacts",
                iconName: "person.crop.square.filled.and.at.rectangle.fill",
                color: .brown,
                service: ContactsService.shared,
                binding: contactsEnabled
            ),
            ServiceConfig(
                name: "Location",
                iconName: "location.fill",
                color: .blue,
                service: LocationService.shared,
                binding: locationEnabled
            ),
            ServiceConfig(
                name: "Maps",
                iconName: "mappin.and.ellipse",
                color: .purple,
                service: MapsService.shared,
                binding: mapsEnabled
            ),
            ServiceConfig(
                name: "Messages",
                iconName: "message.fill",
                color: .green,
                service: MessageService.shared,
                binding: messagesEnabled
            ),
            ServiceConfig(
                name: "Reminders",
                iconName: "list.bullet",
                color: .orange,
                service: RemindersService.shared,
                binding: remindersEnabled
            ),
            ServiceConfig(
                name: "Weather",
                iconName: "cloud.sun.fill",
                color: .cyan,
                service: WeatherService.shared,
                binding: weatherEnabled
            ),
        ]
    }
}

@MainActor
final class ServerController: ObservableObject {
    @Published var serverStatus: String = "Starting..."
    @Published var pendingConnectionID: String?

    private var activeApprovalDialogs: Set<String> = []
    private var pendingApprovals: [(String, () -> Void, () -> Void)] = []

    private let networkManager = ServerNetworkManager()

    init() {
        Task {
            await self.networkManager.start()
            self.updateServerStatus("Running")

            await networkManager.setConnectionApprovalHandler {
                [weak self] connectionID, clientInfo in
                guard let self = self else {
                    log.debug("Self is nil in approval handler, denying connection")
                    return false
                }

                log.debug("ServerManager: Approval handler called for client \(clientInfo.name)")

                // Create a continuation to wait for the user's response
                return await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        self.showConnectionApprovalAlert(
                            clientID: clientInfo.name,
                            approve: {
                                continuation.resume(returning: true)
                            },
                            deny: {
                                continuation.resume(returning: false)
                            }
                        )
                    }
                }
            }
        }
    }

    func updateServiceBindings(_ bindings: [String: Binding<Bool>]) async {
        await networkManager.updateServiceBindings(bindings)
    }

    func startServer() async {
        await networkManager.start()
        updateServerStatus("Running")
    }

    func stopServer() async {
        await networkManager.stop()
        updateServerStatus("Stopped")
    }

    func setEnabled(_ enabled: Bool) async {
        await networkManager.setEnabled(enabled)
        updateServerStatus(enabled ? "Running" : "Disabled")
    }

    private func updateServerStatus(_ status: String) {
        log.info("Server status updated: \(status)")
        self.serverStatus = status
    }

    private func showConnectionApprovalAlert(
        clientID: String, approve: @escaping () -> Void, deny: @escaping () -> Void
    ) {
        log.notice("Connection approval requested for client: \(clientID)")
        self.pendingConnectionID = clientID

        // Check if there's already an active dialog for this client
        guard !activeApprovalDialogs.contains(clientID) else {
            log.info("Adding to pending approvals for client: \(clientID)")
            pendingApprovals.append((clientID, approve, deny))
            return
        }

        activeApprovalDialogs.insert(clientID)

        let alert = NSAlert()
        alert.messageText = "Client Connection Request"
        alert.informativeText =
            #"Allow "\#(clientID)" to connect to the MCP server?"#
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")

        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        let approved = response == .alertFirstButtonReturn

        // Handle the current approval
        if approved {
            log.notice("Connection approved for client: \(clientID)")
            approve()
        } else {
            log.notice("Connection denied for client: \(clientID)")
            deny()
        }

        // Handle any pending approvals for the same client
        while let pendingIndex = pendingApprovals.firstIndex(where: { $0.0 == clientID }) {
            let (_, pendingApprove, pendingDeny) = pendingApprovals.remove(at: pendingIndex)
            if approved {
                log.notice("Approving pending connection for client: \(clientID)")
                pendingApprove()
            } else {
                log.notice("Denying pending connection for client: \(clientID)")
                pendingDeny()
            }
        }

        activeApprovalDialogs.remove(clientID)
        log.debug("Clearing pending connection")
        self.pendingConnectionID = nil
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

    typealias ConnectionApprovalHandler = @Sendable (UUID, MCP.Client.Info) async -> Bool
    private var connectionApprovalHandler: ConnectionApprovalHandler?

    // Replace individual services array with ServiceRegistry
    private let services = ServiceRegistry.services
    private var serviceBindings: [String: Binding<Bool>] = [:]

    init() {
        // Set up Bonjour service
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.includePeerToPeer = false

        if let tcpOptions = parameters.defaultProtocolStack.internetProtocol
            as? NWProtocolIP.Options
        {
            tcpOptions.version = .v4
        }

        // Create the listener with service discovery
        listener = try! NWListener(using: parameters)
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

        // Set up connection state handler
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                log.debug("Connection ready")
                Task {
                    if let self = self {
                        await self.setupConnection(
                            connectionID: connectionID,
                            connection: connection
                        )
                    }
                }
            case .failed(let error):
                log.error("Connection failed: \(error)")
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

    private func setupConnection(connectionID: UUID, connection: NWConnection) async {
        let logger = Logger(label: "com.loopwork.mcp-server.\(connectionID)")
        let transport = NetworkTransport(connection: connection, logger: logger)

        // Create the MCP server
        let server = MCP.Server(
            name: Bundle.main.name ?? "iMCP",
            version: Bundle.main.shortVersionString ?? "unknown",
            capabilities: MCP.Server.Capabilities(
                tools: .init(listChanged: true)
            )
        )

        // Store the server immediately
        self.mcpServers[connectionID] = server

        // Start the server
        Task {
            do {
                log.notice("Starting MCP server for connection: \(connectionID)")
                try await server.start(transport: transport) { clientInfo, capabilities in
                    log.info("Received initialize request from client: \(clientInfo.name)")

                    // Request user approval
                    var approved = false
                    if let approvalHandler = await self.connectionApprovalHandler {
                        approved = await approvalHandler(connectionID, clientInfo)
                        log.info(
                            "Approval result for connection \(connectionID): \(approved ? "Approved" : "Denied")"
                        )
                    }

                    if !approved {
                        await self._removeConnection(connectionID)
                        throw MCPError.connectionClosed
                    }
                }
                log.notice("MCP Server started successfully for connection: \(connectionID)")

                // Register handlers after successful approval
                await self.registerHandlers(for: server)
            } catch {
                log.error("Failed to start MCP server: \(error.localizedDescription)")
                _removeConnection(connectionID)
            }
        }
    }

    private func registerHandlers(for server: MCP.Server) async {
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

        // Update tools/list handler with proper actor isolation
        await server.withMethodHandler(ListTools.self) { [self] _ in
            log.debug("Handling ListTools request")

            var tools: [MCP.Tool] = []
            if await self.isEnabled {
                for service in self.services {
                    let serviceId = String(describing: type(of: service))

                    // Get the binding value in an actor-safe way
                    let isServiceEnabled = await serviceBindings[serviceId]?.wrappedValue ?? true
                    if isServiceEnabled {
                        for tool in service.tools {
                            log.debug("Adding tool: \(tool.name)")
                            tools.append(
                                .init(
                                    name: tool.name,
                                    description: tool.description,
                                    inputSchema: tool.inputSchema
                                )
                            )
                        }
                    }
                }
            }

            log.info("Returning \(tools.count) available tools")
            return ListTools.Result(tools: tools)
        }

        // Update tools/call handler with proper actor isolation
        await server.withMethodHandler(CallTool.self) { [self] params in
            log.notice("Tool call received: \(params.name)")

            guard await self.isEnabled else {
                log.notice("Tool call rejected: iMCP is disabled")
                return CallTool.Result(
                    content: [.text("iMCP is currently disabled. Please enable it to use tools.")],
                    isError: true
                )
            }

            for service in self.services {
                let serviceId = String(describing: type(of: service))

                // Get the binding value in an actor-safe way
                let isServiceEnabled = await serviceBindings[serviceId]?.wrappedValue ?? true
                guard isServiceEnabled else {
                    continue
                }

                do {
                    guard
                        let value = try await service.call(
                            tool: params.name,
                            with: params.arguments ?? [:]
                        )
                    else {
                        continue
                    }

                    log.notice("Tool \(params.name) executed successfully")
                    switch value {
                    case let .data(mimeType?, data) where mimeType.hasPrefix("image/"):
                        return CallTool.Result(
                            content: [
                                .image(
                                    data: data.base64EncodedString(),
                                    mimeType: mimeType,
                                    metadata: nil
                                )
                            ], isError: false)
                    default:
                        let encoder = JSONEncoder()
                        encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] = TimeZone.current
                        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                        let data = try encoder.encode(value)
                        let text = String(data: data, encoding: .utf8)!
                        return CallTool.Result(content: [.text(text)], isError: false)
                    }
                } catch {
                    log.error("Error executing tool \(params.name): \(error.localizedDescription)")
                    return CallTool.Result(content: [.text("Error: \(error)")], isError: true)
                }
            }

            log.error("Tool not found or service not enabled: \(params.name)")
            return CallTool.Result(
                content: [.text("Tool not found or service not enabled: \(params.name)")],
                isError: true
            )
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
        log.info("Updating service bindings")
        self.serviceBindings = newBindings

        // Notify clients that tool availability may have changed
        Task {
            for (_, server) in mcpServers {
                try? await server.notify(ToolListChangedNotification.message())
            }
        }
    }
}
