import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var serverController: ServerController
    var isMenuBarExtraInserted: Bool

    // Settings reopens to the pane that was open last.
    @AppStorage("settingsPane") private var pane = SettingsPane.general

    var body: some View {
        let configs = serverController.computedServiceConfigs
        let selection = selection(in: configs)

        // Settings has no sidebar button, so the sidebar always shows.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(
                selection: Binding(
                    get: { selection },
                    set: { newValue in
                        if let newValue { pane = newValue }
                    }
                )
            ) {
                Label("General", systemImage: "gearshape")
                    .tag(SettingsPane.general)
                Label("Clients", systemImage: "app.connected.to.app.below.fill")
                    .tag(SettingsPane.clients)
                Label("Remote Access", systemImage: "network")
                    .tag(SettingsPane.remoteAccess)
                Label("iPhone & iPad", systemImage: "ipad.and.iphone")
                    .tag(SettingsPane.mobile)

                Section("Services") {
                    ForEach(configs) { config in
                        Label {
                            Text(config.name)
                        } icon: {
                            ServiceIcon(config: config, isOn: config.binding.wrappedValue)
                        }
                        .accessibilityValue(config.binding.wrappedValue ? "On" : "Off")
                        .tag(SettingsPane.service(config.id))
                    }
                }
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(200)
        } detail: {
            Group {
                switch selection {
                case .general:
                    GeneralSettingsView(
                        serverController: serverController,
                        isMenuBarExtraInserted: isMenuBarExtraInserted
                    )
                case .clients:
                    ClientsSettingsView(serverController: serverController)
                case .remoteAccess:
                    RemoteAccessSettingsView(serverController: serverController)
                case .mobile:
                    MobileSettingsView()
                case .service(let id):
                    if let config = configs.first(where: { $0.id == id }) {
                        ServiceSettingsView(serverController: serverController, config: config)
                            // Each service starts at the top, with its own state.
                            .id(id)
                    }
                }
            }
            // The detail column is always loaded, unlike a sidebar that the window restores collapsed.
            .background(NonCollapsibleSidebar())
        }
        .frame(width: 715, height: 560)
    }

    /// The stored pane, or General if the stored pane is for a service that this build doesn't include.
    private func selection(in configs: [ServiceConfig]) -> SettingsPane {
        if case .service(let id) = pane, !configs.contains(where: { $0.id == id }) {
            return .general
        }
        return pane
    }
}

/// Keeps people from dragging the Settings sidebar closed.
/// Settings has no sidebar button or View menu to show it again,
/// and SwiftUI has no setting for this, so this changes the sidebar's split view item.
private struct NonCollapsibleSidebar: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowReaderView {
        WindowReaderView()
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {
        nsView.keepSidebarExpanded()
    }

    final class WindowReaderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            keepSidebarExpanded()
        }

        func keepSidebarExpanded() {
            guard let contentView = window?.contentView,
                let controller = splitViewController(in: contentView)
            else { return }
            for item in controller.splitViewItems where item.behavior == .sidebar {
                item.canCollapse = false
                // The window can restore a sidebar that was collapsed before this change.
                if item.isCollapsed {
                    DispatchQueue.main.async { item.isCollapsed = false }
                }
            }
        }

        private func splitViewController(in view: NSView) -> NSSplitViewController? {
            if let splitView = view as? NSSplitView,
                let controller = splitView.delegate as? NSSplitViewController
            {
                return controller
            }
            for subview in view.subviews {
                if let controller = splitViewController(in: subview) {
                    return controller
                }
            }
            return nil
        }
    }
}

/// A pane in Settings, stored as its raw value so that Settings can reopen to it.
enum SettingsPane: Hashable, RawRepresentable {
    case general
    case clients
    case remoteAccess
    case mobile
    /// The pane for the service with this ``ServiceConfig/id``.
    case service(String)

    init(rawValue: String) {
        switch rawValue {
        case "general": self = .general
        case "clients": self = .clients
        case "remoteAccess": self = .remoteAccess
        case "mobile": self = .mobile
        default: self = .service(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .general: "general"
        case .clients: "clients"
        case .remoteAccess: "remoteAccess"
        case .mobile: "mobile"
        case .service(let id): id
        }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var serverController: ServerController
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    var isMenuBarExtraInserted: Bool
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showMenuBarExtra) {
                    Text("Show in Menu Bar")
                    if showMenuBarExtra && !isMenuBarExtraInserted {
                        if #available(macOS 26.0, *) {
                            Text("macOS hid the menu bar icon. Check System Settings > Menu Bar.")
                        } else {
                            Text("macOS hid the menu bar icon.")
                        }
                    }
                    Text("If the icon is hidden, open iMCP again to return to Settings.")
                }

                Toggle(isOn: $launchAtLogin) {
                    Text("Launch at Login")
                    Text("Opens iMCP automatically when you log in.")
                }
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            }

            ApprovalModeSection(serverController: serverController)
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct ApprovalModeSection: View {
    @ObservedObject var serverController: ServerController
    @State private var expandedAgents: Set<String> = ["claude-desktop", "claude-code"]

    private var selectedMode: ApprovalMode {
        serverController.approvalMode
    }

    var body: some View {
        Section {
            ForEach(ApprovalMode.allCases) { mode in
                Button {
                    serverController.approvalMode = mode
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selectedMode == mode ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selectedMode == mode ? Color.accentColor : .secondary)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                                .foregroundStyle(.primary)
                            Text(mode.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedMode == mode ? [.isSelected] : [])
            }
        } header: {
            Text("Approval Mode")
        } footer: {
            Text(
                "Applies to tool calls across all enabled services. Changing between iMCP-managed and full-access modes updates the tools offered to connected clients."
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if selectedMode.showsAgentConfigurationHelp {
            Section {
                ForEach(selectedMode.agentInstructions) { instruction in
                    DisclosureGroup(isExpanded: binding(for: instruction.id)) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(instruction.instructions)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            if let snippet = instruction.codeSnippet {
                                HStack(alignment: .top, spacing: 8) {
                                    Text(snippet)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color(NSColor.textBackgroundColor))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color(NSColor.separatorColor))
                                        )

                                    Button("Copy") {
                                        let pasteboard = NSPasteboard.general
                                        pasteboard.clearContents()
                                        pasteboard.setString(snippet, forType: .string)
                                        _ = NSSound.play(.pop)
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Text(instruction.agentName)
                            .fontWeight(.medium)
                    }
                }
            } header: {
                Text("Agent Setup Instructions")
            } footer: {
                if let heading = selectedMode.agentInstructionsHeading {
                    Text(heading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func binding(for agentID: String) -> Binding<Bool> {
        Binding(
            get: { expandedAgents.contains(agentID) },
            set: { isExpanded in
                if isExpanded {
                    expandedAgents.insert(agentID)
                } else {
                    expandedAgents.remove(agentID)
                }
            }
        )
    }
}

struct ClientsSettingsView: View {
    @ObservedObject var serverController: ServerController
    @State private var isConfirmingRemoveAll = false

    private let serverCommand = Bundle.main.bundleURL
        .appendingPathComponent("Contents/MacOS/imcp-server")
        .path

    var body: some View {
        let trustedClients = serverController.trustedClients
        let legacyTrustedClientNames = serverController.legacyTrustedClientNames

        Form {
            Section("Connect a Client") {
                LabeledContent {
                    Button("Set Up…") {
                        ClaudeDesktop.showConfigurationPanel(serverController: serverController)
                    }
                } label: {
                    Text("Claude Desktop")
                    Text("Adds iMCP to the MCP servers in Claude Desktop's configuration file.")
                }

                LabeledContent {
                    Button("Copy") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(serverCommand, forType: .string)
                        _ = NSSound.play(.pop)
                    }
                } label: {
                    Text("Server Command")
                    Text(serverCommand)
                        .textSelection(.enabled)
                }
            }

            Section {
                if trustedClients.isEmpty {
                    VStack(spacing: 4) {
                        Text("No Trusted Apps")
                        Text("To trust an app, choose Always Allow when you approve its connection.")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } else {
                    ForEach(trustedClients) { client in
                        TrustedAppRow(client: client) {
                            serverController.removeTrustedClient(client)
                        }
                    }
                }
            } header: {
                Text("Trusted Apps")
            } footer: {
                VStack(alignment: .trailing) {
                    Text(
                        "Trusted apps connect without an approval dialog, and iMCP shows a notification whenever one connects. iMCP identifies an app by its code signature. Claude Code and other clients that run in a terminal use a local credential instead. Removing an app revokes its trust."
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !trustedClients.isEmpty || !legacyTrustedClientNames.isEmpty {
                        Button("Remove All…") {
                            isConfirmingRemoveAll = true
                        }
                    }
                }
            }

            if !serverController.oauthConnections.grants.isEmpty || !serverController.activePublicURLs.isEmpty {
                ConnectedOAuthAppsSection(model: serverController.oauthConnections)
            }

            if !legacyTrustedClientNames.isEmpty {
                Section {
                    ForEach(legacyTrustedClientNames, id: \.self) { name in
                        LabeledContent(name) {
                            Button("Remove") {
                                serverController.removeLegacyTrustedClient(name)
                            }
                        }
                    }
                } header: {
                    Text("Approve Again")
                } footer: {
                    Text(
                        "Earlier versions of iMCP trusted these clients by the name they reported, which any app can claim. They need your approval the next time they connect."
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Clients")
        .alert("Remove All Trusted Apps?", isPresented: $isConfirmingRemoveAll) {
            Button("Remove All", role: .destructive) {
                serverController.resetTrustedClients()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each app needs your approval again the next time it connects.")
        }
    }
}
/// Connected OAuth 2.1 cloud apps, shown in the Clients pane.
struct ConnectedOAuthAppsSection: View {
    @ObservedObject var model: OAuthConnectionsModel
    @State private var appToRevoke: OAuthGrant?
    @State private var revokeError: String?

    var body: some View {
        Section {
            if let error = model.storageError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else if model.grants.isEmpty {
                Text("No cloud apps connected yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.grants) { grant in
                    LabeledContent {
                        Button("Revoke…", role: .destructive) { appToRevoke = grant }
                    } label: {
                        Text(grant.clientName)
                        Text("Returns to \(grant.redirectHost)")
                        Text(
                            "Connected \(grant.createdAt.formatted(date: .abbreviated, time: .omitted)). "
                                + (grant.lastUsedAt.map {
                                    "Last used \($0.formatted(.relative(presentation: .named)))."
                                } ?? "Not used yet.")
                        )
                    }
                }
            }
        } header: {
            Text("Connected Cloud Apps (OAuth)")
        } footer: {
            Text("Revoking a cloud app ends its access right away.")
        }
        .confirmationDialog(
            "Revoke \"\(appToRevoke?.clientName ?? "")\"?",
            isPresented: Binding(get: { appToRevoke != nil }, set: { if !$0 { appToRevoke = nil } }),
            presenting: appToRevoke
        ) { grant in
            Button("Revoke", role: .destructive) {
                do {
                    try model.revoke(grant.id)
                } catch {
                    revokeError = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Couldn't Revoke the App",
            isPresented: Binding(get: { revokeError != nil }, set: { if !$0 { revokeError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(revokeError ?? "")
        }
    }
}
