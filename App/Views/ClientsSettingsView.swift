import AppKit
import SwiftUI

/// The Clients tab: the AI apps that connect to iMCP, and the ones it trusts.
struct ClientsSettingsView: View {
    @ObservedObject var serverController: ServerController
    @ObservedObject private var oauthConnections: OAuthConnectionsModel
    @AppStorage("settingsPane") private var tab = SettingsPane.clients
    @State private var isConfirmingRemoveAll = false
    @State private var expanded: Set<String> = []
    /// Read again after Claude Desktop or Claude Code is set up.
    @State private var setupRevision = 0

    init(serverController: ServerController) {
        self.serverController = serverController
        self.oauthConnections = serverController.oauthConnections
    }

    var body: some View {
        let _ = setupRevision
        let trustedClients = serverController.trustedClients
        let legacyNames = serverController.legacyTrustedClientNames
        let publicURL = serverController.activePublicURLs.first?.url

        Form {
            Section {
                ForEach(KnownClient.all) { client in
                    clientRow(client, publicURL: publicURL)
                }
                if let publicURL {
                    ExpandableRow(isExpanded: expansion(of: "connectorAddress")) {
                        HStack {
                            RowLabel(title: "Connector address", subtitle: publicURL) {
                                SettingsIcon(symbol: "link", color: .teal)
                            }
                            Spacer(minLength: 8)
                            Button("Copy") { copyToSettingsPasteboard(publicURL) }
                        }
                    } content: {
                        Text(
                            "Copy this address. In your AI app, add a custom connector and paste it. The first time the app connects, iMCP asks once to allow it."
                        )
                        .font(.callout)
                        .padding(.vertical, 4)
                    }
                } else {
                    LabeledContent {
                        Button("Open Remote Access") { tab = .remoteAccess }
                    } label: {
                        RowLabel(title: "Cloud apps need a public address") {
                            SettingsIcon(symbol: "network", color: .orange)
                        }
                    }
                }
            } header: {
                Text("AI apps")
            }

            Section {
                if trustedClients.isEmpty && legacyNames.isEmpty {
                    EmptyRow(symbol: "checkmark.shield", text: "No trusted apps yet")
                }
                ForEach(trustedClients) { client in
                    TrustedAppRow(client: client) {
                        serverController.removeTrustedClient(client)
                    }
                }
                ForEach(legacyNames, id: \.self) { name in
                    LabeledContent {
                        Button("Remove") { serverController.removeLegacyTrustedClient(name) }
                    } label: {
                        RowLabel(title: name, subtitle: "Needs approval again") {
                            ClientIdentityIcon(name: name) {
                                SettingsIcon(symbol: "questionmark.app.fill", color: .gray)
                            }
                        }
                    }
                }
                if !trustedClients.isEmpty || !legacyNames.isEmpty {
                    Button("Remove All…", role: .destructive) { isConfirmingRemoveAll = true }
                }
            } header: {
                Text("Trusted")
            }

            if !oauthConnections.grants.isEmpty || oauthConnections.storageError != nil {
                ConnectedOAuthAppsSection(model: oauthConnections)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Clients")
        .alert("Remove all trusted apps?", isPresented: $isConfirmingRemoveAll) {
            Button("Remove All", role: .destructive) {
                serverController.resetTrustedClients()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each app asks again the next time it connects.")
        }
    }

    // MARK: Rows

    private func clientRow(_ client: KnownClient, publicURL: String?) -> some View {
        let mode = serverController.approvalMode
        let instruction = mode.agentInstructions.first { $0.id == client.instructionID }
        return ExpandableRow(isExpanded: expansion(of: client.id)) {
            HStack(spacing: 10) {
                ClientLogo(client: client)
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.name)
                    clientStatus(client, hasAddress: publicURL != nil)
                }
                Spacer(minLength: 8)
                clientAction(client, publicURL: publicURL)
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Text(client.steps)
                if let instruction {
                    Text(instruction.instructions)
                        .foregroundStyle(.secondary)
                    if let snippet = instruction.codeSnippet {
                        HStack(alignment: .top) {
                            Text(snippet)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                            Button("Copy") { copyToSettingsPasteboard(snippet) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .font(.callout)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func clientStatus(_ client: KnownClient, hasAddress: Bool) -> some View {
        switch client.kind {
        case .onThisMac:
            if isSetUp(client) {
                StatusBadge(text: "Set up", kind: .good, symbol: "checkmark")
            } else {
                StatusBadge(text: "Not set up")
            }
        case .cloud:
            if let grant = grant(for: client) {
                HStack(spacing: 6) {
                    StatusBadge(text: "Connected", kind: .good, symbol: "checkmark")
                    Text(grant.lastUsedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "Not used yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if hasAddress {
                StatusBadge(text: "Not connected")
            } else {
                StatusBadge(text: "Needs address", kind: .attention)
            }
        }
    }

    @ViewBuilder
    private func clientAction(_ client: KnownClient, publicURL: String?) -> some View {
        switch client.kind {
        case .onThisMac:
            Button(isSetUp(client) ? "Set Up Again" : "Set Up") {
                if client == .claudeDesktop {
                    ClaudeDesktop.showConfigurationPanel(serverController: serverController)
                } else {
                    ClaudeCode.showConfigurationPanel(serverController: serverController)
                }
                setupRevision += 1
            }
        case .cloud:
            Button("Copy Address") {
                if let publicURL { copyToSettingsPasteboard(publicURL) }
            }
            .disabled(publicURL == nil)
        }
    }

    private func isSetUp(_ client: KnownClient) -> Bool {
        switch client {
        case .claudeDesktop: ClaudeDesktop.isConfigured
        case .claudeCode: ClaudeCode.isConfigured
        default: false
        }
    }

    /// The approved cloud app that belongs to this client, if there is one.
    private func grant(for client: KnownClient) -> OAuthGrant? {
        oauthConnections.grants
            .filter { KnownClient.match(name: $0.clientName) == client }
            .max { ($0.lastUsedAt ?? $0.createdAt) < ($1.lastUsedAt ?? $1.createdAt) }
    }

    private func expansion(of id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isExpanded in
                if isExpanded { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }
}

/// The cloud apps that the owner approved, with a button to end each one.
struct ConnectedOAuthAppsSection: View {
    @ObservedObject var model: OAuthConnectionsModel
    @State private var appToRevoke: OAuthGrant?
    @State private var revokeError: String?

    var body: some View {
        Section {
            if let error = model.storageError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            ForEach(model.grants) { grant in
                LabeledContent {
                    Button("Revoke…", role: .destructive) { appToRevoke = grant }
                } label: {
                    RowLabel(
                        title: grant.clientName,
                        subtitle: grant.lastUsedAt.map { "Used \($0.formatted(.relative(presentation: .named)))" }
                            ?? "Not used yet"
                    ) {
                        ClientIdentityIcon(name: grant.clientName) {
                            SettingsIcon(symbol: "cloud.fill", color: .teal)
                        }
                    }
                }
            }
        } header: {
            Text("Connected cloud apps")
        }
        .confirmationDialog(
            "Revoke “\(appToRevoke?.clientName ?? "")”?",
            isPresented: Binding(get: { appToRevoke != nil }, set: { if !$0 { appToRevoke = nil } }),
            presenting: appToRevoke
        ) { grant in
            Button("Revoke", role: .destructive) {
                do {
                    try model.revoke(grant.id)
                } catch {
                    revokeError = "\(error.localizedDescription) The app can't connect until iMCP saves the change."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The app loses access right away.")
        }
        .alert(
            "Couldn't revoke the app",
            isPresented: Binding(get: { revokeError != nil }, set: { if !$0 { revokeError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(revokeError ?? "")
        }
    }
}
