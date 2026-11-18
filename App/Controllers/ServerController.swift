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

/// A service's name and tools, for lists of tools in Settings.
struct ToolGroup {
    let name: String
    let tools: [Tool]
}

enum ServiceRegistry {
    static let services: [any Service] = {
        var services: [any Service] = [
            AlarmsService.shared,
            CalendarService.shared,
            CaptureService.shared,
            ContactsService.shared,
            FilesService.shared,
            HealthService.shared,
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
        alarmsEnabled: Binding<Bool>,
        calendarEnabled: Binding<Bool>,
        captureEnabled: Binding<Bool>,
        contactsEnabled: Binding<Bool>,
        filesEnabled: Binding<Bool>,
        healthEnabled: Binding<Bool>,
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
                name: "Alarms",
                summary: "List and cancel alarms, and schedule alarms and timers on your iPhone or iPad.",
                iconName: "alarm.fill",
                color: .orange,
                service: AlarmsService.shared,
                binding: alarmsEnabled
            ),
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
                name: "Files",
                summary: "Read and search the folders that you share, and, if you allow it, change files in them.",
                iconName: "folder.fill",
                color: .teal,
                service: FilesService.shared,
                binding: filesEnabled
            ),
            ServiceConfig(
                name: "Health",
                summary: "Read health samples, statistics, workouts, and clinical records from your iPhone or iPad.",
                iconName: "heart.fill",
                color: .pink,
                service: HealthService.shared,
                binding: healthEnabled
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

    /// Connections waiting for a person's decision, keyed by
    /// ``ClientCredentialStore/Request/approvalKey(connectionID:)``:
    /// connections with the same credential share a window,
    /// and each connection without one gets its own.
    private var approvals = ApprovalQueue<ClientCredentialStore.Request, ApprovalWaiter>()
    private let approvalWindowController = ConnectionApprovalWindowController()
    /// Apps that wait for the owner to approve public access through OAuth, keyed by request ID.
    private var oauthApprovals = ApprovalQueue<OAuthApprovalRequest, OAuthApprovalWaiter>()

    private let networkManager = ServerNetworkManager()

    // MARK: - AppStorage for Service Enablement States
    @AppStorage("alarmsEnabled") private var alarmsEnabled = false
    @AppStorage("calendarEnabled") private var calendarEnabled = false
    @AppStorage("captureEnabled") private var captureEnabled = false
    @AppStorage("contactsEnabled") private var contactsEnabled = false
    @AppStorage("filesEnabled") private var filesEnabled = false
    @AppStorage("healthEnabled") private var healthEnabled = false
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

    // MARK: - Client Credentials
    private let credentials = ClientCredentialStore(storage: KeychainClientRecordStorage())
    /// The open connections that each credential let in or was issued to,
    /// so that revoking a credential closes them.
    private var credentialSessions = CredentialSessions()

    // MARK: - AppStorage for Disabled Tools
    @AppStorage("disabledTools") private var disabledToolsData = Data()
    private var disabledToolsGeneration = 0

    // MARK: - Remote Access
    @AppStorage("remoteAccessEnabled") private var remoteAccessEnabled = false
    @AppStorage("remoteAccessPort") private var remoteAccessPortValue = Int(RemoteAccessServer.defaultPort)
    /// The host name for iMCP's node, or empty for one made from the Mac's name.
    @AppStorage("remoteAccessHostname") private var remoteAccessHostnameValue = ""
    /// Whether the server is also open to the internet through Tailscale Funnel. Off by default.
    @AppStorage("remoteAccessFunnelEnabled") private var remoteAccessFunnelEnabled = false
    @Published private(set) var remoteAccessState: RemoteAccessServer.State = .off
    private let tokenStore = AccessTokenStore.shared
    /// The apps that the owner approved through OAuth, for Settings.
    let oauthConnections = OAuthConnectionsModel()
    /// Applies remote access settings in the order that they change.
    private var remoteAccessConfigurationTask: Task<Void, Never>?

    // MARK: - Computed Properties for Service Configurations and Bindings
    var computedServiceConfigs: [ServiceConfig] {
        ServiceRegistry.configureServices(
            alarmsEnabled: $alarmsEnabled,
            calendarEnabled: $calendarEnabled,
            captureEnabled: $captureEnabled,
            contactsEnabled: $contactsEnabled,
            filesEnabled: $filesEnabled,
            healthEnabled: $healthEnabled,
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

    /// The clients that connect without an approval dialog, sorted by name.
    var trustedClients: [ClientRecord] {
        credentials.trustedRecords
    }

    /// The names of clients that an earlier version trusted by name.
    /// They need approval again, because a name doesn't identify a client.
    var legacyTrustedClientNames: [String] {
        credentials.legacyTrustedNames
    }

    /// Revokes the credential of a trusted client and closes its connections.
    func removeTrustedClient(_ record: ClientRecord) {
        objectWillChange.send()
        do {
            try credentials.revoke(id: record.id)
        } catch {
            log.error("Failed to remove trusted client: \(String(describing: error), privacy: .public)")
        }
        closeConnections(credentialSessions.revoke(credentialID: record.id))
    }

    func removeLegacyTrustedClient(_ name: String) {
        objectWillChange.send()
        credentials.removeLegacyTrustedName(name)
    }

    /// Revokes every credential and closes the connections that used one.
    func resetTrustedClients() {
        objectWillChange.send()
        do {
            try credentials.revokeAll()
        } catch {
            log.error("Failed to remove trusted clients: \(String(describing: error), privacy: .public)")
        }
        closeConnections(credentialSessions.revokeAll())
    }

    /// Closes connections whose credential was revoked.
    private func closeConnections(_ connectionIDs: Set<UUID>) {
        guard !connectionIDs.isEmpty else { return }
        log.notice("Closing \(connectionIDs.count) connection(s) whose credential was removed")
        Task {
            for id in connectionIDs {
                await networkManager.removeConnection(id)
            }
        }
    }

    /// Returns a credential for iMCP to write into a client's MCP settings.
    ///
    /// - Parameters:
    ///   - name: The client's name, which the approval dialog shows.
    ///   - existing: The credential that the settings already have, if any.
    ///     It's kept if iMCP issued it.
    func credentialForClientSettings(name: String, existing: String?, trusted: Bool = false) throws -> String {
        objectWillChange.send()
        return try credentials.credentialForSettings(name: name, existing: existing, trusted: trusted)
    }

    /// Revokes a credential that iMCP issued for settings it then failed to write.
    func discardCredential(_ credential: String) {
        guard let record = credentials.record(for: credential) else { return }
        try? credentials.revoke(id: record.id)
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

    /// Tells clients to list the tools again after a service's "Allow writes" setting
    /// changed which of its tools it offers.
    func toolListChanged() {
        Task { await networkManager.updateServiceBindings(self.currentServiceBindings) }
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
            if MobileService.serves(config.service) {
                // The Mac listens for paired devices only while a mobile service is on.
                await MobileService.shared.servicesChanged()
            }
            await networkManager.updateServiceBindings(self.currentServiceBindings)
        }
    }

    // MARK: - Remote Access Management
    var isRemoteAccessEnabled: Bool {
        get { remoteAccessEnabled }
        set {
            objectWillChange.send()
            remoteAccessEnabled = newValue
            applyRemoteAccessConfiguration()
        }
    }

    var isRemoteAccessFunnelEnabled: Bool {
        get { remoteAccessFunnelEnabled }
        set {
            guard newValue != remoteAccessFunnelEnabled else { return }
            objectWillChange.send()
            remoteAccessFunnelEnabled = newValue
            applyRemoteAccessConfiguration()
        }
    }

    var remoteAccessPort: Int {
        get { remoteAccessPortValue }
        set {
            let port = min(max(newValue, 1), Int(UInt16.max))
            guard port != remoteAccessPortValue else { return }
            objectWillChange.send()
            remoteAccessPortValue = port
            applyRemoteAccessConfiguration()
        }
    }

    /// The host name that iMCP's node asks for on the tailnet.
    /// Setting an empty name goes back to one made from the Mac's name.
    var remoteAccessHostname: String {
        get { remoteAccessHostnameValue.isEmpty ? defaultRemoteAccessHostname : remoteAccessHostnameValue }
        set {
            let name = RemoteAccessServer.sanitizedHostname(newValue) ?? ""
            let value = name == defaultRemoteAccessHostname ? "" : name
            guard value != remoteAccessHostnameValue else { return }
            objectWillChange.send()
            remoteAccessHostnameValue = value
            applyRemoteAccessConfiguration()
        }
    }

    /// A host name made from the Mac's name when iMCP starts.
    private(set) lazy var defaultRemoteAccessHostname = RemoteAccessServer.defaultHostname(
        computerName: Host.current().localizedName
    )

    /// Starts iMCP's node again with an auth key, which logs it in without a browser.
    func logInToRemoteAccess(authKey: String) {
        let key = authKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        afterRemoteAccessConfiguration { await $0.logIn(authKey: key) }
    }

    /// Starts iMCP's node again, such as to get a new login URL.
    func restartRemoteAccessNode() {
        afterRemoteAccessConfiguration { await $0.restartNode() }
    }

    /// Logs iMCP's node out of the tailnet.
    func logOutOfRemoteAccess() {
        afterRemoteAccessConfiguration { await $0.logOut() }
    }

    var accessTokens: [AccessToken] {
        tokenStore.all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Every tool that iMCP has, whether or not its service is on.
    var allTools: [Tool] {
        ServiceRegistry.services.flatMap(\.tools)
    }

    /// Each service's tools, in Settings order, with Utilities last.
    var toolGroups: [ToolGroup] {
        var groups = computedServiceConfigs.map { ToolGroup(name: $0.name, tools: $0.service.tools) }
        groups.append(ToolGroup(name: "Utilities", tools: UtilitiesService.shared.tools))
        return groups
    }

    /// The tools that iMCP's own settings let clients use:
    /// their services are on and the tools aren't turned off.
    var availableToolNames: Set<String> {
        let disabled = disabledTools
        let bindings = currentServiceBindings
        var names: Set<String> = []
        for service in ServiceRegistry.services
        where bindings[String(describing: type(of: service))]?.wrappedValue == true {
            for tool in service.tools where !disabled.contains(tool.name) {
                names.insert(tool.name)
            }
        }
        return names
    }

    /// Why iMCP can't read its access tokens, or `nil` if it can.
    var accessTokenStorageError: String? {
        tokenStore.storageError?.localizedDescription
    }

    /// Creates an access token and returns its secret, which iMCP can't show again.
    /// Throws if iMCP can't save the token.
    func createAccessToken(name: String, permissions: ToolPermissions) throws -> String {
        let (token, secret) = AccessToken.make(name: name, permissions: permissions)
        objectWillChange.send()
        try tokenStore.add(token)
        return secret
    }

    /// Changes a token's name and permissions.
    /// If iMCP can't save the change, the token stops working until a change saves.
    func updateAccessToken(id: UUID, name: String, permissions: ToolPermissions) throws {
        objectWillChange.send()
        do {
            try tokenStore.modify(id: id) {
                $0.name = name
                $0.permissions = permissions
            }
        } catch {
            Task { await networkManager.remoteAccess.closeSessions(forToken: id) }
            throw error
        }
        Task { await networkManager.remoteAccess.notifyToolListChanged(forToken: id) }
    }

    /// Gives a token a new secret and returns it.
    /// Clients that use the old secret lose access,
    /// even if iMCP can't save the new secret.
    func rerollAccessToken(id: UUID) throws -> String? {
        objectWillChange.send()
        defer { Task { await networkManager.remoteAccess.closeSessions(forToken: id) } }
        return try tokenStore.modify(id: id) { $0.reroll() }
    }

    /// Deletes a token.
    /// Clients that use it lose access, even if iMCP can't save the deletion.
    func deleteAccessToken(id: UUID) throws {
        objectWillChange.send()
        defer { Task { await networkManager.remoteAccess.closeSessions(forToken: id) } }
        try tokenStore.remove(id: id)
    }

    func refreshRemoteMobileConfiguration() {
        applyRemoteAccessConfiguration()
    }

    private func applyRemoteAccessConfiguration() {
        let mobileVPNEnabled =
            UserDefaults.standard.object(forKey: MobileService.tailscaleVPNEnabledKey) as? Bool ?? true
        let storedMobilePort = UserDefaults.standard.integer(forKey: MobileService.remotePortKey)
        let mobilePort: UInt16? =
            mobileVPNEnabled
            ? ((storedMobilePort > 0 && storedMobilePort <= Int(UInt16.max))
                ? UInt16(storedMobilePort) : MobileLink.defaultRemotePort)
            : nil
        let configuration = RemoteAccessServer.Configuration(
            isEnabled: remoteAccessEnabled,
            port: UInt16(clamping: remoteAccessPortValue),
            hostname: remoteAccessHostname,
            funnelEnabled: remoteAccessFunnelEnabled,
            mobilePort: mobilePort
        )
        afterRemoteAccessConfiguration { await $0.configure(configuration) }
    }

    /// Runs remote access changes one at a time, in the order that they're made.
    private func afterRemoteAccessConfiguration(_ body: @escaping @Sendable (RemoteAccessServer) async -> Void) {
        let previous = remoteAccessConfigurationTask
        let networkManager = self.networkManager
        remoteAccessConfigurationTask = Task {
            await previous?.value
            await body(await networkManager.remoteAccess)
        }
    }

    // MARK: - OAuth Approval

    /// Asks the owner to approve an app that wants public access, and waits for the answer.
    /// A denial, an expiry, and a refusal for too many requests all answer `.denied`.
    func requestOAuthApproval(_ request: OAuthApprovalRequest) async -> OAuthDecision {
        await withCheckedContinuation { continuation in
            let admission = oauthApprovals.enqueue(
                key: request.id,
                cooldownKey: nil,
                request: request,
                id: request.id,
                waiter: OAuthApprovalWaiter(resume: { continuation.resume(returning: $0) }),
                now: .now
            )
            switch admission {
            case .show(let deadline):
                scheduleOAuthExpiry(at: deadline)
                if let entry = oauthApprovals.entries.last { presentOAuthApproval(entry) }
            case .queued(let deadline):
                scheduleOAuthExpiry(at: deadline)
            case .coalesced, .rejected:
                continuation.resume(returning: .denied)
            }
        }
    }

    private func presentOAuthApproval(_ entry: ApprovalQueue<OAuthApprovalRequest, OAuthApprovalWaiter>.Entry) {
        let key = entry.key
        approvalWindowController.showOAuthApprovalWindow(
            id: key,
            request: entry.request,
            enabledServiceNames: computedServiceConfigs.filter { $0.binding.wrappedValue }.map { $0.name },
            onApprove: { readOnly in self.finishOAuthApproval(key: key, decision: .approved(readOnly: readOnly)) },
            onDeny: { self.finishOAuthApproval(key: key, decision: .denied) }
        )
        let request = entry.request
        var details = [
            "App: \(request.clientName)",
            "Client ID: \(request.clientID)",
            "Redirect URI: \(request.redirectURI)",
            "Verification code: \(request.verificationCode)",
            request.confirmationPrompt,
        ]
        if request.redirectsToThisMac {
            details.append("The response goes to this Mac, so any app on it could receive it.")
        }
        details.append("Approving on iPhone gives read-only access. Approve on the Mac to allow changes.")
        offerOnPhone(
            key: key,
            kind: .oauth,
            title: "Allow \(request.clientName) public access?",
            details: details,
            lifetime: oauthApprovals.policy.expiry
        ) { [weak self] outcome in
            self?.finishOAuthApproval(key: key, decision: outcome.isApproved ? .approved(readOnly: true) : .denied)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finishOAuthApproval(key: String, decision: OAuthDecision) {
        withdrawFromPhone(key: key)
        let resolution = oauthApprovals.resolve(key: key, approved: decision != .denied, now: .now)
        guard let entry = resolution.removed.first else { return }
        log.notice(
            "\(decision == .denied ? "Denying" : "Approving") public access for app: \(entry.request.clientName, privacy: .public)"
        )
        for (_, waiter) in entry.waiters { waiter.resume(decision) }
        resolution.promoted.forEach(presentOAuthApproval)
    }

    private func scheduleOAuthExpiry(at deadline: ContinuousClock.Instant) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard let self else { return }
            let resolution = self.oauthApprovals.expire(now: .now)
            for entry in resolution.removed {
                self.withdrawFromPhone(key: entry.key)
                self.approvalWindowController.closeWindow(for: entry.key)
                for (_, waiter) in entry.waiters { waiter.resume(.denied) }
            }
            resolution.promoted.forEach(self.presentOAuthApproval)
        }
    }

    // MARK: - Connection Approval Methods

    /// Shows the dialog for a request in the approval queue.
    private func presentApproval(_ entry: ApprovalQueue<ClientCredentialStore.Request, ApprovalWaiter>.Entry) {
        let key = entry.key
        approvalWindowController.showApprovalWindow(
            id: key,
            request: entry.request,
            enabledServiceNames:
                computedServiceConfigs
                .filter { $0.binding.wrappedValue }
                .map { $0.name },
            onApprove: { alwaysTrust in
                self.finishApproval(key: key, approved: true, alwaysTrust: alwaysTrust)
            },
            onDeny: {
                self.finishApproval(key: key, approved: false, alwaysTrust: false)
            }
        )
        offerOnPhone(
            key: key,
            kind: .connection,
            title: "Allow \(entry.request.claimedName) to connect?",
            details: connectionDetails(entry.request),
            lifetime: approvals.policy.expiry
        ) { [weak self] outcome in
            // Approving from the phone allows this connection once; it never trusts the client.
            self?.finishApproval(key: key, approved: outcome.isApproved, alwaysTrust: false)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Approve on iPhone

    /// Approvals that are also on the paired phone, by approval key.
    /// The phone sees a random ID, never the key, which can derive from a credential.
    private var phoneApprovals = PhoneApprovalBindings()

    private func offerOnPhone(
        key: String,
        kind: RemoteApprovalKind,
        title: String,
        details: [String],
        lifetime: Duration,
        onResolved: @escaping @MainActor (RemoteApprovalOutcome) -> Void
    ) {
        let id = phoneApprovals.register(key)
        let seconds = Double(lifetime.components.seconds)
        RemoteApprovals.shared.offer(
            RemoteApprovalRequest(
                id: id,
                kind: kind,
                title: title,
                details: details,
                expiresAt: Date().addingTimeInterval(seconds)
            )
        ) { [weak self] outcome in
            // Runs on the main actor, after the hop from the broker:
            // the answer counts only for this request, not a later one with the same key.
            guard let self else { return }
            self.phoneApprovals.answer(
                key: key,
                id: id,
                outcome: outcome,
                resolve: onResolved,
                closeWindow: { self.approvalWindowController.closeWindow(for: key) }
            )
        }
    }

    /// Removes an approval from the phone once the Mac has decided it.
    private func withdrawFromPhone(key: String) {
        guard let id = phoneApprovals.remove(key) else { return }
        RemoteApprovals.shared.withdraw(id)
    }

    private func connectionDetails(_ request: ClientCredentialStore.Request) -> [String] {
        var details = ["Client: \(request.claimedName)"]
        if let app = request.app {
            details.append("App: \(app.name)")
            if let signer = app.verifiedSigner { details.append("Signed by: \(signer)") }
        }
        details.append(request.identityNote)
        return details
    }

    /// Applies a person's decision to every connection waiting on the dialog for `key`.
    private func finishApproval(key: String, approved: Bool, alwaysTrust: Bool) {
        withdrawFromPhone(key: key)
        let resolution = approvals.resolve(key: key, approved: approved, now: .now)
        // The request expired or its connections closed while the dialog was open.
        guard let entry = resolution.removed.first else { return }
        let request = entry.request

        var newCredential: String?
        var setUpClaudeCode = false
        if approved && alwaysTrust {
            objectWillChange.send()
            do {
                switch request.offer {
                case .signature:
                    if let app = request.app {
                        let record = try credentials.trustApp(app)
                        for case let (connectionID as UUID, _) in entry.waiters {
                            credentialSessions.add(connectionID, credentialID: record.id)
                        }
                    }
                case .credential, .copiedCredential:
                    newCredential = try credentials.alwaysTrust(request)
                case .claudeCodeSetup:
                    credentials.removeLegacyTrustedName(request.claimedName)
                    setUpClaudeCode = true
                }
                // Revoking the new credential closes the connections that it was issued for.
                if let newCredential, let id = ClientCredential.identifier(for: newCredential) {
                    for case let (connectionID as UUID, _) in entry.waiters {
                        credentialSessions.add(connectionID, credentialID: id)
                    }
                }
            } catch {
                log.error("Failed to trust client: \(String(describing: error), privacy: .public)")
                showTrustError(error, clientName: request.claimedName)
            }

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

        log.notice(
            "\(approved ? "Approving" : "Denying") \(entry.waiters.count) connection(s) for client: \(request.claimedName)"
        )
        for (_, waiter) in entry.waiters {
            approved ? waiter.approve() : waiter.deny()
        }
        resolution.promoted.forEach(presentApproval)

        if setUpClaudeCode {
            Task { @MainActor in
                self.setUpClaudeCodeAfterApproval(
                    request: request,
                    connectionIDs: entry.waiters.compactMap { $0.id as? UUID }
                )
            }
        } else if let newCredential {
            Task { @MainActor in
                self.showNewCredential(newCredential, clientName: request.claimedName)
            }
        }
    }

    /// Denies requests that waited too long, and closes their dialogs.
    private func expireApprovals() {
        let resolution = approvals.expire(now: .now)
        for entry in resolution.removed {
            log.notice("Approval request for client \(entry.request.claimedName) expired")
            withdrawFromPhone(key: entry.key)
            approvalWindowController.closeWindow(for: entry.key)
            for (_, waiter) in entry.waiters {
                waiter.deny()
            }
        }
        resolution.promoted.forEach(presentApproval)
    }

    /// Releases what the app holds for a connection that closed.
    private func connectionClosed(_ connectionID: UUID) {
        credentialSessions.remove(connectionID)
        cancelApproval(for: connectionID)
    }

    /// Stops waiting for a decision on a connection that closed.
    func cancelApproval(for connectionID: UUID) {
        let (waiter, resolution) = approvals.cancel(id: connectionID)
        waiter?.deny()
        for entry in resolution.removed {
            withdrawFromPhone(key: entry.key)
            approvalWindowController.closeWindow(for: entry.key)
        }
        resolution.promoted.forEach(presentApproval)
    }

    private func scheduleExpiry(at deadline: ContinuousClock.Instant) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            self?.expireApprovals()
        }
    }

    init() {
        ServiceWrites.migrateLegacySettings()
        Task { [self] in
            // Initialize bindings from AppStorage before the server starts.
            // The menu sends the enabled state only when its content first appears,
            // so read the stored value here, before the socket accepts connections.
            await networkManager.setEnabled(UserDefaults.standard.object(forKey: "isEnabled") as? Bool ?? true)
            await networkManager.updateServiceBindings(self.currentServiceBindings)
            await networkManager.updateDisabledTools(self.disabledTools, generation: 0)

            // Register the approval handler before listening on the socket.
            // Otherwise the first connection after launch is rejected
            // immediately because the handler is still nil.
            await networkManager.setConnectionClosedHandler { [weak self] connectionID in
                await self?.connectionClosed(connectionID)
            }
            await networkManager.setConnectionApprovalHandler {
                [weak self] connectionID, clientInfo, credential, app in
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
                            connectionID: connectionID,
                            clientName: clientInfo.name,
                            credential: credential,
                            app: app,
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

            // Listen for a paired iPhone or iPad so it can sync before the first tool call.
            if self.alarmsEnabled || self.healthEnabled || MobileService.shared.hasPairedDevice {
                try? await MobileService.shared.start()
            }
            await self.networkManager.remoteAccess.setHandlers(
                state: { [weak self] state in
                    Task { @MainActor in self?.remoteAccessState = state }
                    Task {
                        if case .running(let endpoint) = state {
                            await MobileService.shared.updateRemoteEndpoints(
                                tailnetHost: endpoint.dnsName ?? endpoint.ipv4Address,
                                funnelURL: endpoint.mobileWebSocketURL
                            )
                        } else {
                            await MobileService.shared.updateRemoteEndpoints(tailnetHost: nil, funnelURL: nil)
                        }
                    }
                },
                tokenUsage: { [weak self] in
                    Task { @MainActor in
                        self?.objectWillChange.send()
                        self?.oauthConnections.reload()
                    }
                }
            )
            await self.networkManager.remoteAccess.setMobileHandlers(
                tcp: { connection in await MobileService.shared.acceptTailnetConnection(connection) },
                webSocket: { wire in await MobileService.shared.acceptWebSocket(wire, transportMode: .tailscaleFunnel) }
            )
            await self.networkManager.remoteAccess.setOAuthApprovalHandler { [weak self] request in
                guard let self else { return .denied }
                return await self.requestOAuthApproval(request)
            }
            self.oauthConnections.didRevoke = { [weak self] id in
                guard let self else { return }
                Task { await self.networkManager.remoteAccess.closeSessions(forToken: id) }
            }
            self.applyRemoteAccessConfiguration()
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
        // Stopping the server turns off remote access until the settings are applied again.
        applyRemoteAccessConfiguration()
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
        connectionID: UUID,
        clientName: String,
        credential: String?,
        app: ResponsibleApp?,
        approve: @escaping () -> Void,
        deny: @escaping () -> Void
    ) {
        log.notice("Connection approval requested for client: \(clientName)")

        // Only a trusted credential skips the dialog; the reported name never does.
        let request: ClientCredentialStore.Request
        switch credentials.evaluate(credential: credential, claimedName: clientName, app: app) {
        case .approve(let record):
            log.notice(
                "Client \(clientName) is trusted by \(record.isApp ? "signature" : "credential"), auto-approving"
            )
            credentialSessions.add(connectionID, credentialID: record.id)
            if record.isApp {
                objectWillChange.send()
                credentials.noteConnection(id: record.id)
            }
            approve()

            // Notify the user on auto-approved connections.
            sendClientConnectionNotification(clientName: record.name)

            return
        case .ask(let pendingRequest):
            request = pendingRequest
            // Revoking the credential also closes a connection that waits for approval.
            if let record = pendingRequest.record {
                credentialSessions.add(connectionID, credentialID: record.id)
            }
        }

        if request.hasUnrecognizedCredential {
            log.notice("Client \(clientName) presented a credential that iMCP didn't issue or revoked")
        }

        // Coalesce concurrent approvals for the same credential,
        // and bound the dialogs that clients can open.
        let admission = approvals.enqueue(
            key: request.approvalKey(connectionID: connectionID),
            cooldownKey: request.cooldownKey,
            request: request,
            id: connectionID,
            waiter: ApprovalWaiter(approve: approve, deny: deny),
            now: .now
        )
        switch admission {
        case .show(let deadline):
            scheduleExpiry(at: deadline)
            if let entry = approvals.entries.last {
                presentApproval(entry)
            }
        case .queued(let deadline):
            log.info("Queued approval for client \(clientName) until another dialog closes")
            scheduleExpiry(at: deadline)
        case .coalesced:
            log.info("Added connection to the open approval for client: \(clientName)")
        case .rejected(.coolingDown):
            log.notice("Denied client \(clientName): a request from it was denied moments ago")
            deny()
        case .rejected(.tooManyWaiting):
            log.notice("Denied client \(clientName): too many connections are waiting for approval")
            deny()
        }
    }

    /// Writes iMCP into Claude Code's settings with a trusted credential.
    /// If that isn't possible, shows the credential for the person to copy.
    private func setUpClaudeCodeAfterApproval(request: ClientCredentialStore.Request, connectionIDs: [UUID]) {
        do {
            try ClaudeCode.install(serverController: self, trusted: true)
            for record in credentials.records.values where record.name == ClaudeCode.clientName && record.isTrusted {
                for id in connectionIDs { credentialSessions.add(id, credentialID: record.id) }
            }
            objectWillChange.send()
        } catch {
            log.error("Couldn't set up Claude Code: \(String(describing: error), privacy: .public)")
            do {
                let credential = try credentials.issue(name: request.claimedName, trusted: true).credential
                objectWillChange.send()
                showNewCredential(credential, clientName: request.claimedName)
            } catch {
                showTrustError(error, clientName: request.claimedName)
            }
        }
    }

    /// Shows a credential that iMCP just issued, so that the person can add it to the client.
    /// iMCP stores only the credential's hash, so this is the only time it can be shown.
    private func showNewCredential(_ credential: String, clientName: String) {
        let alert = NSAlert()
        alert.messageText = "Add a Credential to \(clientName)"
        alert.informativeText = """
            To connect without approval next time, \
            add this environment variable to the iMCP server in the client's MCP settings. \
            iMCP doesn't keep a copy of the value.
            """

        let field = NSTextField(
            wrappingLabelWithString: "\(ClientCredential.environmentVariable)=\(credential)"
        )
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.preferredMaxLayoutWidth = 300
        field.frame.size = field.fittingSize
        alert.accessoryView = field

        alert.addButton(withTitle: "Copy Value")
        alert.addButton(withTitle: "Done")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            // Keep the credential off other devices and out of clipboard history.
            let pasteboard = NSPasteboard.general
            pasteboard.prepareForNewContents(with: .currentHostOnly)
            pasteboard.setString(credential, forType: .string)
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
    }

    private func showTrustError(_ error: any Swift.Error, clientName: String) {
        let alert = NSAlert()
        alert.messageText = "iMCP Couldn't Trust \(clientName)"
        alert.informativeText = """
            The connection is allowed this time, \
            but iMCP couldn't save a credential for the client: \(error)
            """
        alert.alertStyle = .warning
        Task { @MainActor in
            alert.runModal()
        }
    }
}

/// Resumes an app that waits for the owner to decide on public access.
private struct OAuthApprovalWaiter {
    let resume: (OAuthDecision) -> Void
}

/// The callbacks that resume a connection waiting for approval.
private struct ApprovalWaiter {
    let approve: () -> Void
    let deny: () -> Void
}

// MARK: - Connection Management Components

extension RemoteAccessServer {
    /// Where iMCP's node keeps its keys and state, in the app's container.
    static var nodeStateDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "iMCP", directoryHint: .isDirectory)
            .appending(path: "Tailscale", directoryHint: .isDirectory)
    }

    init(tokenStore: AccessTokenStore, networkManager: ServerNetworkManager) {
        self.init(
            tokenStore: tokenStore,
            stateDirectory: Self.nodeStateDirectory,
            makeNode: { try await EmbeddedTailnetNode.start($0) }
        ) { [weak networkManager] tokenID in
            guard let networkManager else { return nil }
            let server = MCP.Server.iMCP()
            // A valid access token approves a remote session,
            // so the session doesn't ask the user.
            let gate = ConnectionApprovalGate()
            try? await gate.approve { true }
            // Read current permissions so changes apply to open sessions.
            let initialClientName =
                tokenStore.token(id: tokenID)?.name
                ?? OAuthAuthority.shared.grant(id: tokenID)?.clientName
                ?? "Remote access"
            await networkManager.registerHandlers(
                for: server,
                connectionID: UUID(),
                gate: gate,
                clientName: initialClientName,
                clientNameProvider: {
                    tokenStore.token(id: tokenID)?.name
                        ?? OAuthAuthority.shared.grant(id: tokenID)?.clientName
                        ?? initialClientName
                }
            ) { tool in
                // A session belongs to an access token or to an OAuth grant.
                // Read current permissions so that revoking or editing applies at once.
                (tokenStore.token(id: tokenID)?.permissions ?? OAuthAuthority.shared.grant(id: tokenID)?.permissions)?
                    .allows(tool) ?? false
            }
            return server
        }
    }
}

extension MCP.Server {
    /// A server for one client connection.
    static func iMCP() -> MCP.Server {
        // Some clients, such as ChatGPT,
        // describe the server to the model with only the first line of the instructions,
        // so keep them on one line.
        MCP.Server(
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
}

// Manages a single MCP connection.
actor MCPConnectionManager {
    private let connectionID: UUID
    private let server: MCP.Server
    private let transport: SocketTransport
    private let parentManager: ServerNetworkManager
    private let approvalGate = ConnectionApprovalGate()
    private var isStopping = false
    /// The name that the client gave in its initialize request.
    private var clientName: String?

    /// Creates a manager for a socket whose client passed the code-signing check.
    /// The manager owns `descriptor` and closes it when it stops.
    init(connectionID: UUID, descriptor: Int32, parentManager: ServerNetworkManager) {
        self.connectionID = connectionID
        self.parentManager = parentManager
        self.transport = SocketTransport(descriptor: descriptor)

        // MCP server instance for this connection.
        self.server = MCP.Server.iMCP()
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
                    await self.setClientName(clientInfo.name)

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

    private func setClientName(_ name: String) {
        clientName = name
    }

    private func registerHandlers() async {
        await parentManager.registerHandlers(
            for: server,
            connectionID: connectionID,
            gate: approvalGate,
            clientName: clientName
        )
    }

    /// Tells the client that the tool list changed, if the connection is approved.
    func notifyToolListChanged() async {
        do {
            let sent = try await server.notify(ToolListChangedNotification.message(), ifApprovedBy: approvalGate)
            if sent {
                log.info("Notified client that tool list changed for connection: \(self.connectionID)")
            }
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
    /// The socket file that this listener bound.
    let fileStatus: LocalSocket.PathStatus

    /// Binds the socket at `path` and calls `onConnection` with each accepted descriptor.
    ///
    /// - Throws: ``LocalSocket/Error/addressInUse(_:)`` if another copy of iMCP listens at `path`.
    init(path: String, onConnection: @escaping @Sendable (Int32) -> Void) throws {
        let descriptor = try LocalSocket.listen(at: path) { occupant in
            LocalSocket.isOtherServer(occupant, requirement: CodeRequirement.server)
        }
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        self.path = path
        self.fileStatus = LocalSocket.status(at: path)

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

    /// Whether the socket file that this listener bound is still at its path.
    var isAtPath: Bool {
        LocalSocket.status(at: path) == fileStatus
    }

    /// Stops listening and removes the socket file if no other listener replaced it.
    func cancel() {
        source.cancel()
        if isAtPath {
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
    /// The last reason that listening failed, so that each reason is reported once.
    private var listenerFailure: String?
    private var connections: [UUID: MCPConnectionManager] = [:]
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    /// Timers that close connections that aren't approved in time, keyed by connection.
    /// The handshake gets ``setupTimeout``.
    /// While the person decides on the approval dialog,
    /// the connection gets ``approvalTimeout`` instead,
    /// so deliberation doesn't count as a stalled handshake (#193)
    /// but an unanswered dialog doesn't hold the connection open forever.
    private var setupTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    /// Connections that are accepted but not yet approved.
    private var unapprovedConnections: Set<UUID> = []
    /// Connections that wait for the approval handler.
    private var awaitingApproval: Set<UUID> = []
    private var removedConnections: Set<UUID> = []

    /// How long a connection has to send its hello and initialize request.
    static let setupTimeout: Duration = .seconds(10)
    /// How long a connection can wait for the person to decide.
    /// The approval dialog expires first; this is a backstop.
    static let approvalTimeout: Duration = ApprovalPolicy.default.expiry + .seconds(5)

    /// Decides whether to approve a connection,
    /// given the client's reported info and the credential it presented, if any.
    typealias ConnectionApprovalHandler = @Sendable (UUID, MCP.Client.Info, String?, ResponsibleApp?) async -> Bool
    private var connectionApprovalHandler: ConnectionApprovalHandler?

    /// Called when a connection closes,
    /// so that its approval dialog and its record of the credential it used are released.
    typealias ConnectionClosedHandler = @Sendable (UUID) async -> Void
    private var connectionClosedHandler: ConnectionClosedHandler?

    private let services = ServiceRegistry.services
    private var serviceBindings: [String: Binding<Bool>] = [:]
    private var disabledTools: Set<String> = []
    private var disabledToolsLastGeneration = -1

    private var remoteAccessIfStarted: RemoteAccessServer?
    /// The HTTP server for clients on other devices, created when first needed.
    var remoteAccess: RemoteAccessServer {
        if let remoteAccessIfStarted { return remoteAccessIfStarted }
        let server = RemoteAccessServer(tokenStore: .shared, networkManager: self)
        remoteAccessIfStarted = server
        return server
    }

    func isRunning() -> Bool {
        isRunningState
    }

    func setConnectionClosedHandler(_ handler: @escaping ConnectionClosedHandler) {
        self.connectionClosedHandler = handler
    }

    func setConnectionApprovalHandler(_ handler: @escaping ConnectionApprovalHandler) {
        log.debug("Setting connection approval handler")
        self.connectionApprovalHandler = handler
    }

    func start() async {
        log.info("Starting network manager")
        isRunningState = true

        // Keep trying while another copy of iMCP holds the socket,
        // and listen again if the socket file is removed or replaced.
        listenerRetryTask?.cancel()
        listenerRetryTask = Task {
            while !Task.isCancelled, self.isRunningState {
                self.checkListener()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Listens if the app doesn't, or if its socket file is no longer at its path.
    ///
    /// Clients connect by path, so a listener whose file was removed or replaced
    /// gets no connections. Listening again replaces a file that another process put there,
    /// unless a copy of iMCP listens on it.
    private func checkListener() {
        if let listener {
            guard !listener.isAtPath else { return }
            log.notice(
                "The socket file at \(listener.path, privacy: .public) was removed or replaced. Listening again."
            )
            listener.cancel()
            self.listener = nil
        }
        startListening()
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
            listenerFailure = nil
        } catch {
            // Report each reason once, not on every retry.
            let failure = String(describing: error)
            guard failure != listenerFailure else { return }
            listenerFailure = failure
            if case .notASocket = error as? LocalSocket.Error {
                log.fault(
                    "Clients can't connect: a file that isn't a socket is at \(path, privacy: .public). iMCP listens there again after the file is removed."
                )
            } else {
                log.error("Failed to listen at \(path, privacy: .public): \(failure, privacy: .public)")
            }
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

        for id in awaitingApproval.union(connections.keys) {
            await connectionClosedHandler?(id)
        }
        for task in setupTimeoutTasks.values {
            task.cancel()
        }

        connections.removeAll()
        connectionTasks.removeAll()
        setupTimeoutTasks.removeAll()
        unapprovedConnections.removeAll()
        awaitingApproval.removeAll()
        removedConnections.removeAll()

        listenerRetryTask?.cancel()
        listenerRetryTask = nil
        listener?.cancel()
        listener = nil
        listenerFailure = nil

        await remoteAccessIfStarted?.stop()
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
        unapprovedConnections.remove(id)
        cancelSetupTimeout(for: id)

        // Release the connection's approval dialog, if no other connection waits on it,
        // and its place in the record of credential sessions.
        awaitingApproval.remove(id)
        await connectionClosedHandler?(id)
    }

    // Handle new incoming connections.
    private func handleNewConnection(_ descriptor: Int32) async {
        let connectionID = UUID()
        log.info("Handling new connection: \(connectionID)")

        switch ConnectionAdmission.decide(isEnabled: isEnabledState, unapprovedCount: unapprovedConnections.count) {
        case .accept:
            unapprovedConnections.insert(connectionID)
        case .reject(.disabled):
            log.notice("Rejected connection \(connectionID): iMCP is disabled")
            close(descriptor)
            return
        case .reject(.tooManyUnapproved):
            log.notice("Rejected connection \(connectionID): too many connections are waiting for approval")
            close(descriptor)
            return
        }

        // Check the client's code signature before reading anything from it.
        let hello: LocalSocketHello
        let app: ResponsibleApp?
        do {
            (hello, app) = try await Self.admit(descriptor)
        } catch {
            log.error(
                "Rejected connection \(connectionID): \(String(describing: error), privacy: .public)"
            )
            unapprovedConnections.remove(connectionID)
            close(descriptor)
            return
        }
        log.debug(
            "Connection \(connectionID) sent hello version \(hello.version), credential: \(hello.credential != nil)"
        )

        // The server can stop while the hello is read.
        guard isRunningState else {
            unapprovedConnections.remove(connectionID)
            close(descriptor)
            return
        }

        let connectionManager = MCPConnectionManager(
            connectionID: connectionID,
            descriptor: descriptor,
            parentManager: self
        )

        connections[connectionID] = connectionManager

        // Drive the MCP handshake and approval flow.
        // `start` returns once the server's message loop runs;
        // the approval handler runs later, when the initialize request arrives.
        let task = Task {
            defer {
                self.connectionTasks.removeValue(forKey: connectionID)
            }

            do {
                guard let approvalHandler = self.connectionApprovalHandler else {
                    log.error("No connection approval handler set, rejecting connection")
                    await removeConnection(connectionID)
                    return
                }

                try await connectionManager.start { clientInfo in
                    await self.awaitApproval(for: connectionID) {
                        await approvalHandler(connectionID, clientInfo, hello.credential, app)
                    }
                }

                log.notice("Connection \(connectionID) started")
            } catch {
                log.error("Failed to establish connection \(connectionID): \(error)")
                await removeConnection(connectionID)
            }
        }

        connectionTasks[connectionID] = task

        // Time out stalled setups to avoid orphaned connections.
        scheduleSetupTimeout(for: connectionID, after: Self.setupTimeout)
    }

    /// Runs the approval handler for a connection under the approval timeout.
    private func awaitApproval(for connectionID: UUID, _ handler: () async -> Bool) async -> Bool {
        guard !removedConnections.contains(connectionID) else { return false }
        guard isEnabledState else {
            log.notice("Denied connection \(connectionID): iMCP is disabled")
            return false
        }

        // From here the wait is on a person, not the client.
        scheduleSetupTimeout(for: connectionID, after: Self.approvalTimeout)
        awaitingApproval.insert(connectionID)
        let approved = await handler()
        awaitingApproval.remove(connectionID)

        guard approved, !removedConnections.contains(connectionID) else { return false }
        cancelSetupTimeout(for: connectionID)
        unapprovedConnections.remove(connectionID)
        log.notice("Connection \(connectionID) approved")
        return true
    }

    /// Checks that `imcp-server` is on the other end of `descriptor`, then reads its hello.
    ///
    /// Both steps block, so they run off the actor.
    private nonisolated static func admit(_ descriptor: Int32) async throws -> (LocalSocketHello, ResponsibleApp?) {
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
                        let hello = try LocalSocketHello.decode(line)
                        let app = ResponsibleApp.resolve(responsibleFor: LocalSocket.processID(of: token))
                        return (hello, app)
                    }
                )
            }
        }
    }

    /// Closes the connection after `timeout` unless it's approved by then.
    /// Any previous timer for it is replaced.
    private func scheduleSetupTimeout(for connectionID: UUID, after timeout: Duration) {
        setupTimeoutTasks[connectionID]?.cancel()
        setupTimeoutTasks[connectionID] = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self.setupTimeoutTasks.removeValue(forKey: connectionID)

            if self.unapprovedConnections.contains(connectionID) {
                log.warning("Connection \(connectionID) wasn't approved in time, closing it")
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
    /// `isToolAllowed` narrows the tools that iMCP's settings allow,
    /// such as for a remote client's access token.
    func registerHandlers(
        for server: MCP.Server,
        connectionID: UUID,
        gate: ConnectionApprovalGate,
        clientName: String?,
        clientNameProvider: (@Sendable () -> String)? = nil,
        isToolAllowed: (@Sendable (Tool) async -> Bool)? = nil
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
            // Services can share a tool, such as mobile_status; list it once.
            var names = Set<String>()
            if await self.isEnabledState {
                for service in await self.services {
                    let serviceId = String(describing: type(of: service))

                    // Read binding on the actor for consistency.
                    if let isServiceEnabled = await self.serviceBindings[serviceId]?.wrappedValue,
                        isServiceEnabled
                    {
                        for tool in service.listedTools() {
                            if await self.disabledTools.contains(tool.name) {
                                log.debug("Skipping disabled tool: \(tool.name)")
                                continue
                            }
                            guard names.insert(tool.name).inserted else { continue }
                            if let isToolAllowed, await !isToolAllowed(tool) {
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

            let start = ContinuousClock.now
            let resolvedClient = clientNameProvider?() ?? clientName ?? "Unknown client"
            let services = await self.services
            let matchedService = services.first { $0.tools.contains { $0.name == params.name } }
            let matchedTool = matchedService?.tools.first { $0.name == params.name }
            let defaultServiceName = matchedService.map(Self.serviceDisplayName) ?? "Unknown"
            let defaultIsWrite = matchedTool?.isWrite ?? false

            func record(
                _ outcome: MobileActivityEvent.Outcome,
                serviceName: String = defaultServiceName,
                isWrite: Bool = defaultIsWrite,
                detail: String? = nil
            ) async {
                let elapsed = ContinuousClock.now - start
                let ms = max(
                    0,
                    Int(elapsed.components.seconds) * 1000
                        + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
                )
                let event = MobileActivityEvent(
                    timestamp: Date(),
                    clientName: resolvedClient,
                    serviceName: serviceName,
                    toolName: params.name,
                    isWrite: isWrite,
                    outcome: outcome,
                    detail: detail,
                    durationMs: ms
                )
                await MobileService.shared.recordActivity(event)
            }

            log.notice("Tool call received from \(connectionID): \(params.name)")

            guard await self.isEnabledState else {
                log.notice("Tool call rejected: iMCP is disabled")
                await record(.denied, detail: "iMCP is disabled")
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
                await record(.denied, detail: "Tool disabled in settings")
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

            if let isToolAllowed {
                let tool = services.lazy.flatMap(\.tools).first { $0.name == params.name }
                guard let tool, await isToolAllowed(tool) else {
                    log.notice("Tool call rejected: \(params.name) isn't allowed for this access token")
                    await record(.denied, detail: "Not allowed by access token")
                    return CallTool.Result(
                        content: [
                            .text(
                                text: "The iMCP access token for this client doesn't allow the tool \(params.name).",
                                annotations: nil,
                                _meta: nil
                            )
                        ],
                        isError: true
                    )
                }
            }

            for service in services {
                let serviceId = String(describing: type(of: service))
                let serviceName = Self.serviceDisplayName(service)
                let serviceTool = service.tools.first { $0.name == params.name }

                // Read binding on the actor for consistency.
                if let isServiceEnabled = await self.serviceBindings[serviceId]?.wrappedValue,
                    isServiceEnabled
                {
                    do {
                        // Make the captured client name available to tools.
                        guard
                            let value = try await ToolCallContext.$clientName.withValue(
                                resolvedClient,
                                operation: {
                                    try await service.call(
                                        tool: params.name,
                                        with: params.arguments ?? [:]
                                    )
                                }
                            )
                        else {
                            continue
                        }

                        log.notice("Tool \(params.name) executed successfully for \(connectionID)")
                        await record(
                            .succeeded,
                            serviceName: serviceName,
                            isWrite: serviceTool?.isWrite ?? defaultIsWrite
                        )
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
                        let outcome: MobileActivityEvent.Outcome =
                            (error is WritesDisabledError || error is OutboundConfirmationError) ? .denied : .failed
                        await record(
                            outcome,
                            serviceName: serviceName,
                            isWrite: serviceTool?.isWrite ?? defaultIsWrite,
                            detail: error.localizedDescription
                        )
                        return CallTool.Result(
                            content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                            isError: true
                        )
                    }
                }
            }

            // Say why no service answered, so that an intermittent failure can be traced.
            if let owner = matchedService {
                let serviceId = String(describing: type(of: owner))
                let binding = await self.serviceBindings[serviceId]
                let state = binding.map { $0.wrappedValue ? "on" : "off" } ?? "missing"
                log.error(
                    "Tool \(params.name, privacy: .public) belongs to \(serviceId, privacy: .public), whose binding is \(state, privacy: .public)"
                )
                await record(.denied, detail: "Service \(defaultServiceName) is disabled")
            } else {
                await record(.failed, detail: "Tool not found")
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

    private static func serviceDisplayName(_ service: any Service) -> String {
        switch service {
        case is AlarmsService: return "Alarms"
        case is CalendarService: return "Calendar"
        case is CaptureService: return "Capture"
        case is ContactsService: return "Contacts"
        case is FilesService: return "Files"
        case is HealthService: return "Health"
        case is HomeService: return "Home"
        case is LocationService: return "Location"
        case is MapsService: return "Maps"
        case is MailService: return "Mail"
        case is MessageService: return "Messages"
        case is MusicService: return "Music"
        case is NotesService: return "Notes"
        case is PhoneService: return "Phone"
        case is RemindersService: return "Reminders"
        case is ShortcutsService: return "Shortcuts"
        case is UtilitiesService: return "Utilities"
        case is VoiceMemosService: return "Voice Memos"
        default:
            let raw = String(describing: type(of: service))
            return raw.hasSuffix("Service") ? String(raw.dropLast("Service".count)) : raw
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
        await remoteAccessIfStarted?.notifyToolListChanged()
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
            await remoteAccessIfStarted?.notifyToolListChanged()
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
            await remoteAccessIfStarted?.notifyToolListChanged()
        }
    }
}
