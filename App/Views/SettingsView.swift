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
                    GeneralSettingsView(isMenuBarExtraInserted: isMenuBarExtraInserted)
                case .clients:
                    ClientsSettingsView(serverController: serverController)
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
    /// The pane for the service with this ``ServiceConfig/id``.
    case service(String)

    init(rawValue: String) {
        switch rawValue {
        case "general": self = .general
        case "clients": self = .clients
        default: self = .service(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .general: "general"
        case .clients: "clients"
        case .service(let id): id
        }
    }
}

struct GeneralSettingsView: View {
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
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct ClientsSettingsView: View {
    @ObservedObject var serverController: ServerController
    @State private var isConfirmingRemoveAll = false

    private let serverCommand = Bundle.main.bundleURL
        .appendingPathComponent("Contents/MacOS/imcp-server")
        .path

    var body: some View {
        let trustedClients = serverController.getTrustedClients()

        Form {
            Section("Connect a Client") {
                LabeledContent {
                    Button("Set Up…") {
                        ClaudeDesktop.showConfigurationPanel()
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
                        Text("No Trusted Clients")
                        Text("To trust a client, select \"Always trust this client\" when you approve its connection.")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } else {
                    ForEach(trustedClients, id: \.self) { client in
                        LabeledContent(client) {
                            Button("Remove") {
                                serverController.removeTrustedClient(client)
                            }
                        }
                    }
                }
            } header: {
                Text("Trusted Clients")
            } footer: {
                VStack(alignment: .trailing) {
                    Text(
                        "Trusted clients connect without an approval dialog, and iMCP shows a notification whenever one connects. Clients are identified by the name they report, not by a verified identity."
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !trustedClients.isEmpty {
                        Button("Remove All…") {
                            isConfirmingRemoveAll = true
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Clients")
        .alert("Remove All Trusted Clients?", isPresented: $isConfirmingRemoveAll) {
            Button("Remove All", role: .destructive) {
                serverController.resetTrustedClients()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each client needs your approval again the next time it connects.")
        }
    }
}
