import AppKit
import SwiftUI

/// The Remote Access tab: how AI apps and your devices reach this Mac from outside.
/// It shares the Setup Assistant's choices and checklists.
struct RemoteAccessSettingsView: View {
    @ObservedObject var serverController: ServerController
    @ObservedObject private var cloudflare: CloudflareTunnelController
    /// The Setup Assistant's model, which holds the chosen way and its live checklist state.
    @StateObject private var remote: OnboardingModel

    @State private var isConfirmingTailscaleLogOut = false
    @State private var isConfirmingCloudflareLogOut = false

    init(serverController: ServerController) {
        self.serverController = serverController
        self.cloudflare = serverController.cloudflareTunnel
        _remote = StateObject(
            wrappedValue: OnboardingModel(
                mode: .finishSetup,
                serverController: serverController,
                isEnabled: Binding(
                    get: { UserDefaults.standard.object(forKey: "isEnabled") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "isEnabled") }
                )
            )
        )
    }

    var body: some View {
        let selection = remote.remoteSelection

        Form {
            Section {
                Picker(
                    selection: Binding(get: { remote.remoteSelection }, set: { remote.choose($0) })
                ) {
                    ForEach(RemoteChoice.allCases, id: \.self) { choice in
                        Label(choice.summaryName, systemImage: choice.settingsSymbol).tag(choice)
                    }
                } label: {
                    RowLabel(title: "Reach this Mac", subtitle: selection.settingsCaption) {
                        SettingsIcon(symbol: selection.settingsSymbol, color: .blue)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Access")
            }

            switch selection {
            case .local:
                EmptyView()
            case .tailscale, .funnel:
                tailscaleSection(selection)
            case .cloudflare:
                cloudflareSection
            }

            if let url = serverController.activePublicURLs.first?.url {
                Section {
                    LabeledContent {
                        Button("Copy") { copyToSettingsPasteboard(url) }
                    } label: {
                        RowLabel(title: "Connector address", subtitle: url) {
                            SettingsIcon(symbol: "link", color: .teal)
                        }
                    }
                } header: {
                    Text("Public address")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Remote Access")
        .onAppear {
            remote.reset(mode: .finishSetup)
            #if DEBUG
                // Screenshots show a way's checklist without turning anything on.
                if let raw = UserDefaults.standard.string(forKey: "debugRemoteSelection"),
                    let choice = RemoteChoice.allCases.first(where: { String(describing: $0) == raw })
                {
                    remote.remoteSelection = choice
                }
            #endif
            cloudflare.refreshEnvironment()
        }
        .onDisappear { remote.windowWillClose() }
        .alert("Log out of Tailscale?", isPresented: $isConfirmingTailscaleLogOut) {
            Button("Log Out", role: .destructive) {
                serverController.logOutOfRemoteAccess()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your devices can't connect until iMCP logs in again.")
        }
        .alert("Log out of Cloudflare?", isPresented: $isConfirmingCloudflareLogOut) {
            Button("Log Out", role: .destructive) {
                cloudflare.logOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops the tunnel and removes the saved sign-in.")
        }
    }

    // MARK: Tailscale

    private func tailscaleSection(_ choice: RemoteChoice) -> some View {
        Section {
            TailscaleChecklistView(
                inputs: remote.tailscaleInputs,
                openTailscalePage: remote.openTailscalePage,
                getSignInLink: { serverController.restartRemoteAccessNode() },
                compact: true
            )

            if case .running(let endpoint) = serverController.remoteAccessState {
                if choice == .funnel, endpoint.funnelCapabilityGranted == false {
                    FunnelACLGuidanceView(ipv4Address: endpoint.ipv4Address)
                }
                Button {
                    isConfirmingTailscaleLogOut = true
                } label: {
                    RowLabel(title: "Log out of Tailscale…") {
                        SettingsIcon(symbol: "rectangle.portrait.and.arrow.right", color: .red)
                    }
                }
                .buttonStyle(.plain)
            } else if case .needsApproval = serverController.remoteAccessState {
                Button {
                    isConfirmingTailscaleLogOut = true
                } label: {
                    RowLabel(title: "Log out of Tailscale…") {
                        SettingsIcon(symbol: "rectangle.portrait.and.arrow.right", color: .red)
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text(choice.summaryName)
        }
    }

    // MARK: Cloudflare

    private var cloudflareSection: some View {
        Section {
            CloudflareChecklistView(cloudflare: cloudflare, compact: true)

            if cloudflare.account != nil {
                HStack {
                    if case .connected = cloudflare.state, isHostnameDirty {
                        Button("Update and Reconnect") { Task { await cloudflare.provisionAndConnect() } }
                    }
                    Button("Refresh Domains") { Task { await cloudflare.refreshZones() } }
                    Button("Log Out of Cloudflare…", role: .destructive) { isConfirmingCloudflareLogOut = true }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.bordered)
            }
        } header: {
            Text("Cloudflare Tunnel")
        } footer: {
            Text(
                "iMCP creates one tunnel and one address on your domain, and nothing else. Turning it off deletes both."
            )
        }
    }

    private var isHostnameDirty: Bool {
        guard let zone = cloudflare.selectedZone,
            let resolved = CloudflareTunnelController.resolvedHostname(
                input: cloudflare.hostnameDraft,
                zoneName: zone.name
            )
        else { return false }
        return resolved != cloudflare.configuredHostname
    }
}

extension RemoteAccessServer.State {
    var endpoint: String? {
        if case .running(let endpoint) = self { endpoint.url } else { nil }
    }
}

/// Shows a copyable Tailscale ACL `nodeAttrs` snippet when the node lacks the `funnel` capability.
private struct FunnelACLGuidanceView: View {
    let ipv4Address: String
    @Environment(\.openURL) private var openURL

    private var snippet: String {
        FunnelPolicy.tailscaleNodeAttrsSnippet(ipv4Address: ipv4Address)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Tailscale must allow public addresses for this Mac", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
            HStack {
                Button("Copy Policy Snippet") {
                    copyToSettingsPasteboard(snippet)
                }
                Button("Open Tailscale Policy…") {
                    if let url = URL(string: "https://login.tailscale.com/admin/acls/file") {
                        openURL(url)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
