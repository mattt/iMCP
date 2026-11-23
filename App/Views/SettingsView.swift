import AppKit
import ServiceManagement
import Sparkle
import SwiftUI

/// The Settings window: a sidebar with the app tabs and the Services section, and the pane that is selected.
/// The window can be resized, and the sidebar can be collapsed.
struct SettingsView: View {
    @ObservedObject var serverController: ServerController
    var isMenuBarExtraInserted: Bool
    var updater: SPUUpdater?

    // Settings reopens to the pane that was open last.
    @AppStorage("settingsPane") private var pane = SettingsPane.general
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        let configs = serverController.computedServiceConfigs
        let selection = selection(in: configs)

        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(
                selection: Binding(
                    get: { selection },
                    set: { newValue in
                        if let newValue { pane = newValue }
                    }
                )
            ) {
                ForEach(SettingsPane.tabs, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.symbol)
                        .tag(tab)
                }

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
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } detail: {
            Group {
                switch selection {
                case .general:
                    GeneralSettingsView(
                        serverController: serverController,
                        isMenuBarExtraInserted: isMenuBarExtraInserted,
                        updater: updater
                    )
                case .clients:
                    ClientsSettingsView(serverController: serverController)
                case .mobile:
                    MobileSettingsView(serverController: serverController)
                case .remoteAccess:
                    RemoteAccessSettingsView(serverController: serverController)
                case .advanced:
                    AdvancedSettingsView(serverController: serverController)
                case .service(let id):
                    if let config = configs.first(where: { $0.id == id }) {
                        ServiceSettingsView(serverController: serverController, config: config)
                            // Each service starts at the top, with its own state.
                            .id(id)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .toolbarBackground(.bar, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .frame(
            minWidth: SettingsWindowMetrics.minimumSize.width,
            minHeight: SettingsWindowMetrics.minimumSize.height
        )
    }

    /// The stored pane, or General if the stored pane is for a service that this build doesn't include.
    private func selection(in configs: [ServiceConfig]) -> SettingsPane {
        if case .service(let id) = pane, !configs.contains(where: { $0.id == id }) {
            return .general
        }
        return pane
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var serverController: ServerController
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("isEnabled") private var isEnabled = true
    var isMenuBarExtraInserted: Bool
    var updater: SPUUpdater?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $isEnabled) {
                    RowLabel(title: "Server", subtitle: isEnabled ? nil : "Off. AI apps can't connect.") {
                        SettingsIcon(symbol: "power", color: .green)
                    }
                }

                Toggle(isOn: $showMenuBarExtra) {
                    RowLabel(
                        title: "Show in menu bar",
                        subtitle: showMenuBarExtra && !isMenuBarExtraInserted
                            ? "macOS hid the icon. Check System Settings."
                            : nil
                    ) {
                        SettingsIcon(symbol: "menubar.rectangle", color: .blue)
                    }
                }

                Toggle(isOn: $launchAtLogin) {
                    RowLabel(title: "Launch at login") {
                        SettingsIcon(symbol: "sunrise.fill", color: .orange)
                    }
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

            Section {
                Picker(
                    selection: Binding(
                        get: { serverController.approvalMode },
                        set: { serverController.approvalMode = $0 }
                    )
                ) {
                    ForEach(ApprovalMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    RowLabel(title: "Ask before", subtitle: serverController.approvalMode.settingsCaption) {
                        SettingsIcon(symbol: "hand.raised.fill", color: .purple)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Approvals")
            }

            Section {
                LabeledContent {
                    Button("Open…") {
                        OnboardingWindowController.shared.present(
                            serverController: serverController,
                            isEnabled: $isEnabled
                        )
                    }
                } label: {
                    RowLabel(title: "Setup Assistant") {
                        SettingsIcon(symbol: "wand.and.stars", color: .indigo)
                    }
                }

                LabeledContent {
                    Button("Check Now") { updater?.checkForUpdates() }
                        .disabled(!(updater?.canCheckForUpdates ?? false))
                } label: {
                    RowLabel(title: "Updates", subtitle: version) {
                        SettingsIcon(symbol: "arrow.triangle.2.circlepath", color: .teal)
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
