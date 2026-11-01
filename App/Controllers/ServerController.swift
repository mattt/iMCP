import AppKit
import MCP
import OSLog
import Ontology
import SwiftUI
import SystemPackage
import UserNotifications

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

private let log = Logger.server

struct ServiceConfig: Identifiable {
    let id: String
    let name: String
    /// What clients can do with the service, as Settings describes it.
    let summary: String
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
        summary: String,
        iconName: String,
        color: Color,
        service: any Service,
        binding: Binding<Bool>
    ) {
        self.id = String(describing: type(of: service))
        self.name = name
        self.summary = summary
        self.iconName = iconName
        self.color = color
        self.service = service
        self.binding = binding
    }
}

enum ServiceRegistry {
    static let services: [any Service] = {
        var services: [any Service] = [
            CalendarService.shared,
            CaptureService.shared,
            ContactsService.shared,
            HomeService.shared,
            LocationService.shared,
            MapsService.shared,
            MailService.shared,
            MessageService.shared,
            MusicService.shared,
            NotesService.shared,
            PhoneService.shared,
            RemindersService.shared,
            ShortcutsService.shared,
            UtilitiesService.shared,
            VoiceMemosService.shared,
        ]
        if VoicemailService.isSupported {
            services.append(VoicemailService.shared)
        }
        #if WEATHERKIT_AVAILABLE
            services.append(WeatherService.shared)
        #endif
        return services
    }()

    static func configureServices(
        calendarEnabled: Binding<Bool>,
        captureEnabled: Binding<Bool>,
        contactsEnabled: Binding<Bool>,
        homeEnabled: Binding<Bool>,
        locationEnabled: Binding<Bool>,
        mapsEnabled: Binding<Bool>,
        mailEnabled: Binding<Bool>,
        messagesEnabled: Binding<Bool>,
        musicEnabled: Binding<Bool>,
        notesEnabled: Binding<Bool>,
        phoneEnabled: Binding<Bool>,
        remindersEnabled: Binding<Bool>,
        shortcutsEnabled: Binding<Bool>,
        utilitiesEnabled: Binding<Bool>,
        voiceMemosEnabled: Binding<Bool>,
        voicemailEnabled: Binding<Bool>,
        weatherEnabled: Binding<Bool>
    ) -> [ServiceConfig] {
        var configs: [ServiceConfig] = [
            ServiceConfig(
                name: "Calendar",
                summary: "View, create, update, and delete calendar events.",
                iconName: "calendar",
                color: .red,
                service: CalendarService.shared,
                binding: calendarEnabled
            ),
            ServiceConfig(
                name: "Capture",
                summary: "Take pictures with the camera, record audio, and take screenshots.",
                iconName: "camera.on.rectangle.fill",
                color: .gray.mix(with: .black, by: 0.7),
                service: CaptureService.shared,
                binding: captureEnabled
            ),
            ServiceConfig(
                name: "Contacts",
                summary: "Look up your own contact card, and search, create, and update contacts.",
                iconName: "person.crop.square.filled.and.at.rectangle.fill",
                color: .brown,
                service: ContactsService.shared,
                binding: contactsEnabled
            ),
            ServiceConfig(
                name: "Home",
                summary: "Control HomeKit accessories, scenes, and automations, and organize rooms and zones.",
                iconName: "house.fill",
                color: .orange,
                service: HomeService.shared,
                binding: homeEnabled
            ),
            ServiceConfig(
                name: "Location",
                summary: "Get your current location, and convert between addresses and coordinates.",
                iconName: "location.fill",
                color: .blue,
                service: LocationService.shared,
                binding: locationEnabled
            ),
            ServiceConfig(
                name: "Maps",
                summary: "Search for places, get directions and travel times, and generate map images.",
                iconName: "mappin.and.ellipse",
                color: .purple,
                service: MapsService.shared,
                binding: mapsEnabled
            ),
            ServiceConfig(
                name: "Mail",
                summary: "Search and read the mail stored on your Mac, and open new drafts in your email app.",
                iconName: "envelope.fill",
                color: .blue,
                service: MailService.shared,
                binding: mailEnabled
            ),
            ServiceConfig(
                name: "Messages",
                summary: "Read your message history with specific people, including attachments.",
                iconName: "message.fill",
                color: .green,
                service: MessageService.shared,
                binding: messagesEnabled
            ),
            ServiceConfig(
                name: "Music",
                summary: "See what's playing in Music, control playback, and search the Apple Music catalog.",
                iconName: "music.note",
                color: .black,
                service: MusicService.shared,
                binding: musicEnabled
            ),
            ServiceConfig(
                name: "Notes",
                summary: "Search notes by text, folder, or date, and read them as Markdown.",
                iconName: "note.text",
                color: .yellow,
                service: NotesService.shared,
                binding: notesEnabled
            ),
            ServiceConfig(
                name: "Phone",
                summary: "View the call history synced from your iPhone, and start calls with confirmation.",
                iconName: "phone.fill",
                color: .green,
                service: PhoneService.shared,
                binding: phoneEnabled
            ),
            ServiceConfig(
                name: "Reminders",
                summary: "View, create, update, and delete reminders and reminder lists.",
                iconName: "list.bullet",
                color: .orange,
                service: RemindersService.shared,
                binding: remindersEnabled
            ),
            ServiceConfig(
                name: "Shortcuts",
                summary: "List and run the shortcuts on your Mac, with optional text input.",
                iconName: "square.2.layers.3d",
                color: .indigo,
                service: ShortcutsService.shared,
                binding: shortcutsEnabled
            ),
            ServiceConfig(
                name: "Voice Memos",
                summary: "Fetch recordings from Voice Memos, with their transcripts and audio.",
                iconName: "waveform",
                color: .red,
                service: VoiceMemosService.shared,
                binding: voiceMemosEnabled
            ),
        ]
        if VoicemailService.isSupported {
            configs.append(
                ServiceConfig(
                    name: "Voicemail",
                    summary: "Fetch the voicemails synced from your iPhone, with their transcripts and audio.",
                    iconName: "recordingtape",
                    color: .green,
                    service: VoicemailService.shared,
                    binding: voicemailEnabled
                )
            )
        }
        #if WEATHERKIT_AVAILABLE
            configs.append(
                ServiceConfig(
                    name: "Weather",
                    summary: "Get current weather and daily, hourly, and minute-by-minute forecasts.",
                    iconName: "cloud.sun.fill",
                    color: .cyan,
                    service: WeatherService.shared,
                    binding: weatherEnabled
                )
            )
        #endif
        return configs
    }
}

@MainActor
final class ServerController: ObservableObject {
    @Published var serverStatus: String = "Starting..."

    /// Clients with an approval window on screen.
    /// Keyed by client name so that concurrent requests
    /// from different clients each keep their own state.
    private var activeApprovalDialogs: Set<String> = []
    private var pendingApprovals: [(String, () -> Void, () -> Void)] = []
    private let approvalWindowController = ConnectionApprovalWindowController()

    private let networkManager = ServerNetworkManager()

    // MARK: - AppStorage for Service Enablement States
    @AppStorage("calendarEnabled") private var calendarEnabled = false
    @AppStorage("captureEnabled") private var captureEnabled = false
    @AppStorage("contactsEnabled") private var contactsEnabled = false
    @AppStorage("homeEnabled") private var homeEnabled = false
    @AppStorage("locationEnabled") private var locationEnabled = false
    @AppStorage("mapsEnabled") private var mapsEnabled = true  // Default enabled
    @AppStorage("mailEnabled") private var mailEnabled = false
    @AppStorage("messagesEnabled") private var messagesEnabled = false
    @AppStorage("musicEnabled") private var musicEnabled = false
    @AppStorage("notesEnabled") private var notesEnabled = false
    @AppStorage("phoneEnabled") private var phoneEnabled = false
    @AppStorage("remindersEnabled") private var remindersEnabled = false
    @AppStorage("shortcutsEnabled") private var shortcutsEnabled = false
    @AppStorage("utilitiesEnabled") private var utilitiesEnabled = true  // Default enabled
    @AppStorage("voiceMemosEnabled") private var voiceMemosEnabled = false
    @AppStorage("voicemailEnabled") private var voicemailEnabled = false
    @AppStorage("weatherEnabled") private var weatherEnabled = false

    // MARK: - AppStorage for Trusted Clients
    @AppStorage("trustedClients") private var trustedClientsData = Data()

    // MARK: - AppStorage for Disabled Tools
    @AppStorage("disabledTools") private var disabledToolsData = Data()
    private var disabledToolsGeneration = 0

    // MARK: - Computed Properties for Service Configurations and Bindings
    var computedServiceConfigs: [ServiceConfig] {
        ServiceRegistry.configureServices(
            calendarEnabled: $calendarEnabled,
            captureEnabled: $captureEnabled,
            contactsEnabled: $contactsEnabled,
            homeEnabled: $homeEnabled,
            locationEnabled: $locationEnabled,
            mapsEnabled: $mapsEnabled,
            mailEnabled: $mailEnabled,
            messagesEnabled: $messagesEnabled,
            musicEnabled: $musicEnabled,
            notesEnabled: $notesEnabled,
            phoneEnabled: $phoneEnabled,
            remindersEnabled: $remindersEnabled,
            shortcutsEnabled: $shortcutsEnabled,
            utilitiesEnabled: $utilitiesEnabled,
            voiceMemosEnabled: $voiceMemosEnabled,
            voicemailEnabled: $voicemailEnabled,
            weatherEnabled: $weatherEnabled
        )
    }

    private var currentServiceBindings: [String: Binding<Bool>] {
        var bindings = Dictionary(
            uniqueKeysWithValues: computedServiceConfigs.map {
                ($0.id, $0.binding)
            }
        )
        // Utilities has no toggle in the menu, so it has no config,
        // but its tools still need a binding to be listed and called.
        bindings[String(describing: UtilitiesService.self)] = $utilitiesEnabled
        return bindings
    }

    // MARK: - Trusted Clients Management
    private var trustedClients: Set<String> {
        get {
            (try? JSONDecoder().decode(Set<String>.self, from: trustedClientsData)) ?? []
        }
        set {
            objectWillChange.send()
            trustedClientsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    private func isClientTrusted(_ clientName: String) -> Bool {
        trustedClients.contains(clientName)
    }

    private func addTrustedClient(_ clientName: String) {
        var clients = trustedClients
        clients.insert(clientName)
        trustedClients = clients
    }

    func removeTrustedClient(_ clientName: String) {
        var clients = trustedClients
        clients.remove(clientName)
        trustedClients = clients
    }

    func getTrustedClients() -> [String] {
        trustedClients.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func resetTrustedClients() {
        trustedClients = Set<String>()
    }

    // MARK: - Disabled Tools Management
    var disabledTools: Set<String> {
        get {
            (try? JSONDecoder().decode(Set<String>.self, from: disabledToolsData)) ?? []
        }
        set {
            objectWillChange.send()
            disabledToolsData = (try? JSONEncoder().encode(newValue)) ?? Data()
            disabledToolsGeneration += 1
            let generation = disabledToolsGeneration
            Task { await networkManager.updateDisabledTools(newValue, generation: generation) }
        }
    }

    func isToolEnabled(_ name: String) -> Bool {
        !disabledTools.contains(name)
    }

    func setTool(_ name: String, enabled: Bool) {
        var tools = disabledTools
        if enabled {
            tools.remove(name)
        } else {
            tools.insert(name)
        }
        disabledTools = tools
    }

    func setService(_ config: ServiceConfig, enabled: Bool) {
        objectWillChange.send()
        config.binding.wrappedValue = enabled

        Task {
            if enabled, await !config.isActivated {
                do {
                    if config.service is HomeService {
                        if try await !HomeService.shared.activateAskingUser() {
                            self.objectWillChange.send()
                            config.binding.wrappedValue = false
                        }
                    } else {
                        try await config.service.activate()
                    }
                } catch {
                    self.objectWillChange.send()
                    config.binding.wrappedValue = false
                }
                // Settings stays behind other windows after a permission prompt closes,
                // so bring iMCP back to the front.
                NSApp.activate(ignoringOtherApps: true)
            }
            await networkManager.updateServiceBindings(self.currentServiceBindings)
        }
    }

    // MARK: - Connection Approval Methods
    private func cleanupApprovalState(for clientID: String) {
        activeApprovalDialogs.remove(clientID)
    }

    private func handlePendingApprovals(for clientID: String, approved: Bool) {
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
    }

    init() {
        Task { [self] in
            // Initialize bindings from AppStorage before the server starts.
            await networkManager.updateServiceBindings(self.currentServiceBindings)
            await networkManager.updateDisabledTools(self.disabledTools, generation: 0)

            // Register the approval handler before listening on the socket.
            // Otherwise the first connection after launch is rejected
            // immediately because the handler is still nil.
            await networkManager.setConnectionApprovalHandler {
                [weak self] connectionID, clientInfo in
                guard let self = self else {
                    return false
                }

                log.debug("ServerManager: Approval handler called for client \(clientInfo.name)")

                // Bridge approval UI actions back into the async handler.
                return await withCheckedContinuation { continuation in
                    let resumeGate = ResumeGate()
                    let resumeOnce: (Bool) async -> Void = { value in
                        guard await resumeGate.shouldResume() else { return }
                        continuation.resume(returning: value)
                    }

                    Task { @MainActor in
                        self.showConnectionApprovalAlert(
                            clientID: clientInfo.name,
                            approve: {
                                Task { await resumeOnce(true) }
                            },
                            deny: {
                                Task { await resumeOnce(false) }
                            }
                        )
                    }
                }
            }

            await self.networkManager.start()
            self.updateServerStatus("Running")
        }
    }

    /// Sends every service's binding to the server, including Utilities, which has no toggle.
    /// Called by the UI when service toggles change.
    func updateServiceBindings() async {
        await networkManager.updateServiceBindings(currentServiceBindings)
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

    private func sendClientConnectionNotification(clientName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Client Connected"
        content.body = "Client '\(clientName)' has connected to iMCP"
        content.threadIdentifier = "client-connection-\(clientName)"

        let request = UNNotificationRequest(
            identifier: "client-connection-\(clientName)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                log.error("Failed to send notification: \(error.localizedDescription)")
            } else {
                log.info("Sent notification for client connection: \(clientName)")
            }
        }
    }

    private func showConnectionApprovalAlert(
        clientID: String,
        approve: @escaping () -> Void,
        deny: @escaping () -> Void
    ) {
        log.notice("Connection approval requested for client: \(clientID)")

        // Trusted clients auto-approve without showing the dialog.
        if isClientTrusted(clientID) {
            log.notice("Client \(clientID) is already trusted, auto-approving")
            approve()

            // Notify the user on auto-approved connections.
            sendClientConnectionNotification(clientName: clientID)

            return
        }

        // Coalesce concurrent approvals for the same client.
        guard !activeApprovalDialogs.contains(clientID) else {
            log.info("Adding to pending approvals for client: \(clientID)")
            pendingApprovals.append((clientID, approve, deny))
            return
        }

        activeApprovalDialogs.insert(clientID)

        // Present the approval window and wire callbacks.
        approvalWindowController.showApprovalWindow(
            clientName: clientID,
            enabledServiceNames:
                computedServiceConfigs
                .filter { $0.binding.wrappedValue }
                .map { $0.name },
            onApprove: { alwaysTrust in
                if alwaysTrust {
                    self.addTrustedClient(clientID)

                    // Ask for notification permission to alert on future trusted connections.
                    UNUserNotificationCenter.current().requestAuthorization(options: [
                        .alert, .sound, .badge,
                    ]) { granted, error in
                        if let error = error {
                            log.error(
                                "Failed to request notification permissions: \(error.localizedDescription)"
                            )
                        } else {
                            log.info("Notification permissions granted: \(granted)")
                        }
                    }
                }

                approve()
                self.cleanupApprovalState(for: clientID)
                self.handlePendingApprovals(for: clientID, approved: true)
            },
            onDeny: {
                deny()
                self.cleanupApprovalState(for: clientID)
                self.handlePendingApprovals(for: clientID, approved: false)
            }
        )

        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Connection Management Components

// Manages a single MCP connection.
actor MCPConnectionManager {
    private let connectionID: UUID
    private let server: MCP.Server
    private let transport: SocketTransport
    private let parentManager: ServerNetworkManager
    private let approvalGate = ConnectionApprovalGate()
    private var isStopping = false

    /// Creates a manager for a socket whose client passed the code-signing check.
    /// The manager owns `descriptor` and closes it when it stops.
    init(connectionID: UUID, descriptor: Int32, parentManager: ServerNetworkManager) {
        self.connectionID = connectionID
        self.parentManager = parentManager
        self.transport = SocketTransport(descriptor: descriptor)

        // MCP server instance for this connection.
        // Some clients, such as ChatGPT,
        // describe the server to the model with only the first line of the instructions,
        // so keep them on one line.
        self.server = MCP.Server(
            name: Bundle.main.name ?? "iMCP",
            version: Bundle.main.shortVersionString ?? "unknown",
            instructions: """
                Use iMCP for apps and data on the user's Mac: \
                Calendar, Contacts, Location, Mail, Maps, Messages, Music, Notes, Phone, Reminders, Shortcuts, Voice Memos, Voicemail, Weather, \
                and the camera, microphone, and screen. \
                Only the services that the user turns on in iMCP have tools.
                """,
            capabilities: MCP.Server.Capabilities(
                tools: .init(listChanged: true)
            )
        )
    }

    func start(approvalHandler: @escaping (MCP.Client.Info) async -> Bool) async throws {
        do {
            log.notice("Starting MCP server for connection: \(self.connectionID)")
            // Register handlers only after the user approves the connection.
            try await server.start(
                transport: transport,
                gate: approvalGate,
                approve: { [weak self] clientInfo in
                    guard let self = self else { return false }

                    log.info("Received initialize request from client: \(clientInfo.name)")

                    // Request user approval for the connection.
                    let approved = await approvalHandler(clientInfo)
                    log.info(
                        "Approval result for connection \(self.connectionID): \(approved ? "Approved" : "Denied")"
                    )

                    if !approved {
                        await self.parentManager.removeConnection(self.connectionID)
                    }
                    return approved
                },
                registerHandlers: { [weak self] in
                    await self?.registerHandlers()
                }
            )

            log.notice("MCP Server started successfully for connection: \(self.connectionID)")

            // The SDK ends the message loop when the client disconnects,
            // but leaves the socket open. Close it.
            Task { [weak self] in
                guard let self else { return }
                await self.server.waitUntilCompleted()
                await self.parentManager.removeConnection(self.connectionID)
            }
        } catch {
            log.error("Failed to start MCP server: \(error.localizedDescription)")
            throw error
        }
    }

    private func registerHandlers() async {
        await parentManager.registerHandlers(
            for: server,
            connectionID: connectionID,
            gate: approvalGate
        )
    }

    func notifyToolListChanged() async {
        do {
            log.info("Notifying client that tool list changed")
            try await server.notify(ToolListChangedNotification.message())
        } catch {
            log.error("Failed to notify client of tool list change: \(error)")

            // Clean up if the socket is closed.
            if let mcpError = error as? MCPError, case .transportError = mcpError {
                log.debug("Connection appears to be closed")
                await parentManager.removeConnection(connectionID)
            }
        }
    }

    func stop() async {
        // App shutdown and message-loop completion can both stop this connection.
        guard !isStopping else { return }
        isStopping = true
        await server.stop()
        // The server disconnects only a transport that it started.
        await transport.disconnect()
    }
}

/// Listens for `imcp-server` connections on the app's Unix domain socket.
final class LocalSocketListener: @unchecked Sendable {
    let path: String
    private let source: DispatchSourceRead
    private let inode: ino_t

    /// Binds the socket at `path` and calls `onConnection` with each accepted descriptor.
    ///
    /// - Throws: ``LocalSocket/Error/addressInUse(_:)`` if another copy of iMCP listens at `path`.
    init(path: String, onConnection: @escaping @Sendable (Int32) -> Void) throws {
        let descriptor = try LocalSocket.listen(at: path) { occupant in
            LocalSocket.peerSatisfies(CodeRequirement.server, descriptor: occupant, usesDynamicCode: true)
        }
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        var status = stat()
        _ = lstat(path, &status)
        self.path = path
        self.inode = status.st_ino

        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: "me.mattt.iMCP.socket-listener")
        )
        source.setEventHandler {
            while true {
                do {
                    onConnection(try LocalSocket.accept(descriptor))
                } catch {
                    if (error as? LocalSocket.Error)?.code != EAGAIN {
                        log.error("Failed to accept a connection: \(String(describing: error), privacy: .public)")
                    }
                    break
                }
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()

        log.info("Listening at \(path, privacy: .public)")
    }

    /// Stops listening and removes the socket file if no other listener replaced it.
    func cancel() {
        source.cancel()
        var status = stat()
        if lstat(path, &status) == 0, status.st_ino == inode {
            unlink(path)
        }
        log.info("Stopped listening at \(self.path, privacy: .public)")
    }

    deinit {
        if !source.isCancelled {
            cancel()
        }
    }
}

actor ServerNetworkManager {
    private var isRunningState: Bool = false
    private var isEnabledState: Bool = true
    private var listener: LocalSocketListener?
    private var listenerRetryTask: Task<Void, Never>?
    private var connections: [UUID: MCPConnectionManager] = [:]
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    /// Setup timers, keyed by connection.
    /// A timer is cancelled while the user is deciding on the approval dialog
    /// and started again with a fresh budget once they have,
    /// so human deliberation never counts as a stalled handshake (#193).
    private var setupTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingConnections: [UUID: String] = [:]
    private var removedConnections: Set<UUID> = []

    typealias ConnectionApprovalHandler = @Sendable (UUID, MCP.Client.Info) async -> Bool
    private var connectionApprovalHandler: ConnectionApprovalHandler?

    private let services = ServiceRegistry.services
    private var serviceBindings: [String: Binding<Bool>] = [:]
    private var disabledTools: Set<String> = []
    private var disabledToolsLastGeneration = -1

    func isRunning() -> Bool {
        isRunningState
    }

    func setConnectionApprovalHandler(_ handler: @escaping ConnectionApprovalHandler) {
        log.debug("Setting connection approval handler")
        self.connectionApprovalHandler = handler
    }

    func start() async {
        log.info("Starting network manager")
        isRunningState = true

        // Keep trying while another copy of iMCP holds the socket.
        listenerRetryTask?.cancel()
        listenerRetryTask = Task {
            while !Task.isCancelled, self.isRunningState {
                if self.listener == nil {
                    self.startListening()
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func startListening() {
        let path = LocalSocket.serverPath(isSandboxed: LocalSocket.isSandboxed)
        do {
            listener = try LocalSocketListener(path: path) { [weak self] descriptor in
                guard let self else {
                    close(descriptor)
                    return
                }
                Task {
                    await self.handleNewConnection(descriptor)
                }
            }
        } catch {
            log.error("Failed to listen at \(path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func stop() async {
        log.info("Stopping network manager")
        isRunningState = false

        for (id, connectionManager) in connections {
            log.debug("Stopping connection: \(id)")
            await connectionManager.stop()
            connectionTasks[id]?.cancel()
        }

        connections.removeAll()
        connectionTasks.removeAll()
        pendingConnections.removeAll()
        removedConnections.removeAll()

        listenerRetryTask?.cancel()
        listenerRetryTask = nil
        listener?.cancel()
        listener = nil
    }

    func removeConnection(_ id: UUID) async {
        // Guard against redundant removal — calling stop() on an already-stopped
        // connection can trigger a double-resume in the SDK's transport continuation.
        guard !removedConnections.contains(id) else {
            log.debug("Connection \(id) already removed, skipping")
            return
        }
        removedConnections.insert(id)

        log.debug("Removing connection: \(id)")

        if let connectionManager = connections[id] {
            await connectionManager.stop()
        }

        if let task = connectionTasks[id] {
            task.cancel()
        }

        connections.removeValue(forKey: id)
        connectionTasks.removeValue(forKey: id)
        pendingConnections.removeValue(forKey: id)
    }

    // Handle new incoming connections.
    private func handleNewConnection(_ descriptor: Int32) async {
        let connectionID = UUID()
        log.info("Handling new connection: \(connectionID)")

        // Check the client's code signature before reading anything from it.
        let hello: LocalSocketHello
        do {
            hello = try await Self.admit(descriptor)
        } catch {
            log.error(
                "Rejected connection \(connectionID): \(String(describing: error), privacy: .public)"
            )
            close(descriptor)
            return
        }
        log.debug("Connection \(connectionID) sent hello version \(hello.version)")

        let connectionManager = MCPConnectionManager(
            connectionID: connectionID,
            descriptor: descriptor,
            parentManager: self
        )

        connections[connectionID] = connectionManager

        // Drive the MCP handshake and approval flow.
        let task = Task {
            // Ensure this task is removed so the timeout logic doesn't fire afterward.
            defer {
                self.connectionTasks.removeValue(forKey: connectionID)
                self.cancelSetupTimeout(for: connectionID)
            }

            do {
                guard let approvalHandler = self.connectionApprovalHandler else {
                    log.error("No connection approval handler set, rejecting connection")
                    await removeConnection(connectionID)
                    return
                }

                try await connectionManager.start { clientInfo in
                    // From here the wait is on a person, not the client:
                    // stop the setup timer for the dialog
                    // and restart it for the rest of the handshake afterwards.
                    self.cancelSetupTimeout(for: connectionID)
                    let approved = await approvalHandler(connectionID, clientInfo)
                    if approved {
                        self.scheduleSetupTimeout(for: connectionID)
                    }
                    return approved
                }

                log.notice("Connection \(connectionID) successfully established")
            } catch {
                log.error("Failed to establish connection \(connectionID): \(error)")
                await removeConnection(connectionID)
            }
        }

        connectionTasks[connectionID] = task

        // Time out stalled setups to avoid orphaned connections.
        scheduleSetupTimeout(for: connectionID)
    }

    /// Checks that `imcp-server` is on the other end of `descriptor`, then reads its hello.
    ///
    /// Both steps block, so they run off the actor.
    private nonisolated static func admit(_ descriptor: Int32) async throws -> LocalSocketHello {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        let token = try LocalSocket.peerAuditToken(of: descriptor)
                        try CodeRequirement.check(
                            auditToken: token,
                            against: CodeRequirement.client,
                            usesDynamicCode: true
                        )
                        let line = try LocalSocket.readLine(
                            from: descriptor,
                            maximumLength: LocalSocketHello.maximumLength,
                            timeout: .seconds(5)
                        )
                        return try LocalSocketHello.decode(line)
                    }
                )
            }
        }
    }

    /// Gives the connection a fresh setup budget.
    /// Any previous timer for it is replaced.
    private func scheduleSetupTimeout(for connectionID: UUID) {
        setupTimeoutTasks[connectionID]?.cancel()
        setupTimeoutTasks[connectionID] = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
            guard !Task.isCancelled else { return }
            self.setupTimeoutTasks.removeValue(forKey: connectionID)

            // If the setup task is still registered, treat it as timed out.
            if self.connectionTasks[connectionID] != nil,
                self.connections[connectionID] != nil
            {
                log.warning(
                    "Connection \(connectionID) setup timed out (task still in registry), closing it"
                )
                await removeConnection(connectionID)
            }
        }
    }

    private func cancelSetupTimeout(for connectionID: UUID) {
        setupTimeoutTasks.removeValue(forKey: connectionID)?.cancel()
    }

    /// Registers the handlers for an approved connection.
    /// Each handler checks `gate` again,
    /// so that no request reaches a tool before approval.
    func registerHandlers(
        for server: MCP.Server,
        connectionID: UUID,
        gate: ConnectionApprovalGate
    ) async {
        await server.withApprovedMethodHandler(ListPrompts.self, gate: gate) { _ in
            log.debug("Handling ListPrompts request for \(connectionID)")
            return ListPrompts.Result(prompts: [])
        }

        await server.withApprovedMethodHandler(ListResources.self, gate: gate) { _ in
            log.debug("Handling ListResources request for \(connectionID)")
            return ListResources.Result(resources: [])
        }

        await server.withApprovedMethodHandler(ListTools.self, gate: gate) { [weak self] _ in
            guard let self = self else {
                return ListTools.Result(tools: [])
            }

            log.debug("Handling ListTools request for \(connectionID)")

            var tools: [MCP.Tool] = []
            if await self.isEnabledState {
                for service in await self.services {
                    let serviceId = String(describing: type(of: service))

                    // Read binding on the actor for consistency.
                    if let isServiceEnabled = await self.serviceBindings[serviceId]?.wrappedValue,
                        isServiceEnabled
                    {
                        for tool in service.tools {
                            if await self.disabledTools.contains(tool.name) {
                                log.debug("Skipping disabled tool: \(tool.name)")
                                continue
                            }
                            log.debug("Adding tool: \(tool.name)")
                            tools.append(
                                .init(
                                    name: tool.name,
                                    description: tool.description,
                                    inputSchema: try Value(tool.inputSchema),
                                    annotations: tool.annotations
                                )
                            )
                        }
                    }
                }
            }

            log.info("Returning \(tools.count) available tools for \(connectionID)")
            return ListTools.Result(tools: tools)
        }

        await server.withApprovedMethodHandler(CallTool.self, gate: gate) { [weak self] params in
            guard let self = self else {
                return CallTool.Result(
                    content: [.text(text: "Server unavailable", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            log.notice("Tool call received from \(connectionID): \(params.name)")

            guard await self.isEnabledState else {
                log.notice("Tool call rejected: iMCP is disabled")
                return CallTool.Result(
                    content: [
                        .text(
                            text: "iMCP is currently disabled. Please enable it to use tools.",
                            annotations: nil,
                            _meta: nil
                        )
                    ],
                    isError: true
                )
            }

            if await self.disabledTools.contains(params.name) {
                log.notice("Tool call rejected: \(params.name) is disabled")
                return CallTool.Result(
                    content: [
                        .text(
                            text: "Tool \(params.name) is currently disabled in iMCP settings.",
                            annotations: nil,
                            _meta: nil
                        )
                    ],
                    isError: true
                )
            }

            for service in await self.services {
                let serviceId = String(describing: type(of: service))

                // Read binding on the actor for consistency.
                if let isServiceEnabled = await self.serviceBindings[serviceId]?.wrappedValue,
                    isServiceEnabled
                {
                    do {
                        guard
                            let value = try await service.call(
                                tool: params.name,
                                with: params.arguments ?? [:]
                            )
                        else {
                            continue
                        }

                        log.notice("Tool \(params.name) executed successfully for \(connectionID)")
                        switch value {
                        case .data(let mimeType?, let data) where mimeType.hasPrefix("audio/"):
                            return CallTool.Result(
                                content: [
                                    .audio(
                                        data: data.base64EncodedString(),
                                        mimeType: mimeType,
                                        annotations: nil,
                                        _meta: nil
                                    )
                                ],
                                isError: false
                            )
                        case .data(let mimeType?, let data) where mimeType.hasPrefix("image/"):
                            return CallTool.Result(
                                content: [
                                    .image(
                                        data: data.base64EncodedString(),
                                        mimeType: mimeType,
                                        annotations: nil,
                                        _meta: nil
                                    )
                                ],
                                isError: false
                            )
                        default:
                            let encoder = JSONEncoder()
                            encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] =
                                TimeZone.current
                            encoder.userInfo[JSONLD.omitsNestedTypesKey] = true
                            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

                            let data = try encoder.encode(value)
                            let text = String(data: data, encoding: .utf8)!

                            return CallTool.Result(
                                content: [.text(text: text, annotations: nil, _meta: nil)],
                                isError: false
                            )
                        }
                    } catch {
                        log.error(
                            "Error executing tool \(params.name): \(error.localizedDescription)"
                        )
                        return CallTool.Result(
                            content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                            isError: true
                        )
                    }
                }
            }

            // Say why no service answered, so that an intermittent failure can be traced.
            if let owner = await self.services.first(where: { $0.tools.contains { $0.name == params.name } }) {
                let serviceId = String(describing: type(of: owner))
                let binding = await self.serviceBindings[serviceId]
                let state = binding.map { $0.wrappedValue ? "on" : "off" } ?? "missing"
                log.error(
                    "Tool \(params.name, privacy: .public) belongs to \(serviceId, privacy: .public), whose binding is \(state, privacy: .public)"
                )
            }
            log.error("Tool not found or service not enabled: \(params.name)")
            return CallTool.Result(
                content: [
                    .text(text: "Tool not found or service not enabled: \(params.name)", annotations: nil, _meta: nil)
                ],
                isError: true
            )
        }
    }

    // Update the enabled state and notify clients.
    func setEnabled(_ enabled: Bool) async {
        // Only act on changes.
        guard isEnabledState != enabled else { return }

        isEnabledState = enabled
        log.info("iMCP enabled state changed to: \(enabled)")

        // Notify all connected clients that the tool list has changed.
        for (_, connectionManager) in connections {
            Task {
                await connectionManager.notifyToolListChanged()
            }
        }
    }

    // Update service bindings.
    func updateServiceBindings(_ newBindings: [String: Binding<Bool>]) async {
        self.serviceBindings = newBindings
        let enabled = newBindings.filter { $0.value.wrappedValue }.keys.sorted()
        log.notice(
            "Updated service bindings: \(newBindings.count) services, on: \(enabled.joined(separator: ", "), privacy: .public)"
        )

        // Notify clients that tool availability may have changed.
        Task {
            for (_, connectionManager) in connections {
                await connectionManager.notifyToolListChanged()
            }
        }
    }

    // Update the disabled tool set, discarding out-of-order deliveries.
    func updateDisabledTools(_ newDisabledTools: Set<String>, generation: Int) async {
        guard generation > disabledToolsLastGeneration else { return }
        disabledToolsLastGeneration = generation

        guard disabledTools != newDisabledTools else { return }
        self.disabledTools = newDisabledTools

        // Notify clients that tool availability may have changed.
        Task {
            for (_, connectionManager) in connections {
                await connectionManager.notifyToolListChanged()
            }
        }
    }
}
