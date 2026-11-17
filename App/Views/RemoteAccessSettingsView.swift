import AppKit
import SwiftUI

/// The Settings pane for clients on the owner's other devices,
/// which connect over HTTP to iMCP's own Tailscale node or Cloudflare Tunnel.
struct RemoteAccessSettingsView: View {
    @ObservedObject var serverController: ServerController

    @Environment(\.openURL) private var openURL
    @State private var hostnameDraft = ""
    @State private var isEnteringAuthKey = false
    @State private var isConfirmingLogOut = false
    @State private var editingToken: EditingToken?
    @State private var revealedSecret: RevealedSecret?
    @State private var tokenToReroll: AccessToken?
    @State private var tokenToDelete: AccessToken?
    @State private var tokenError: String?
    @State private var isAdvancedExpanded = false

    var body: some View {
        let tokens = serverController.accessTokens
        let storageError = serverController.accessTokenStorageError

        Form {
            CloudflareTunnelSection(cloudflare: serverController.cloudflareTunnel)

            Section {
                Toggle(isOn: enabledBinding) {
                    Text("Tailscale")
                    Text("Connects this Mac to your Tailscale network for private VPN or public Funnel access.")
                }

                if serverController.isRemoteAccessEnabled {
                    LabeledContent("Status") {
                        RemoteAccessStatusView(state: serverController.remoteAccessState)
                    }
                    nodeRows(for: serverController.remoteAccessState)

                    Toggle(isOn: funnelBinding) {
                        Text("Public Access (Tailscale Funnel)")
                        Text("Exposes iMCP at a public .ts.net HTTPS address for cloud agents.")
                    }
                    if case .running(let endpoint) = serverController.remoteAccessState {
                        switch endpoint.funnel {
                        case .active(let url):
                            LabeledContent("Public URL") {
                                HStack {
                                    Text(url)
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Button("Copy") { copyToPasteboard(url) }
                                }
                            }
                        case .failed(let reason):
                            Label(reason, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                            if FunnelPolicy.isMissingFunnelACLError(reason) {
                                FunnelACLGuidanceView(ipv4Address: endpoint.ipv4Address)
                            }
                        case .off:
                            if endpoint.funnelCapabilityGranted == false {
                                FunnelACLGuidanceView(ipv4Address: endpoint.ipv4Address)
                            }
                        }
                    }
                }
            } header: {
                Text("Tailscale")
            } footer: {
                Text(
                    "iMCP joins your tailnet as its own device. Turn on Public Access (Tailscale Funnel) when you want cloud agents to connect through Tailscale."
                )
            }

            Section {
                DisclosureGroup("Developer & Advanced", isExpanded: $isAdvancedExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        if serverController.isRemoteAccessEnabled {
                            LabeledContent("Tailscale Device Name") {
                                TextField(
                                    "Device Name",
                                    text: $hostnameDraft,
                                    prompt: Text(serverController.defaultRemoteAccessHostname)
                                )
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 220)
                                .onSubmit { serverController.remoteAccessHostname = hostnameDraft }
                            }
                            LabeledContent("Tailscale Port") {
                                TextField("Port", value: portBinding, format: .number.grouping(.never))
                                    .labelsHidden()
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                            }
                            if case .running(let endpoint) = serverController.remoteAccessState {
                                LabeledContent("Tailnet URL") {
                                    HStack {
                                        Text(endpoint.url)
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                        Button("Copy") { copyToPasteboard(endpoint.url) }
                                    }
                                }
                            }
                            LabeledContent("Headless Login") {
                                Button("Use Tailscale Auth Key…") { isEnteringAuthKey = true }
                            }
                        }

                        Divider()

                        HStack {
                            Text("Manual Bearer Access Tokens")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Button("Create Token…") {
                                editingToken = EditingToken(token: nil)
                            }
                            .disabled(storageError != nil)
                        }

                        if let storageError {
                            Label(storageError, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        } else if tokens.isEmpty {
                            Text("No manual bearer tokens created. Cloud connectors use OAuth 2.1 automatically.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(tokens) { token in
                                AccessTokenRow(
                                    serverController: serverController,
                                    token: token,
                                    edit: { editingToken = EditingToken(token: token) },
                                    reroll: { tokenToReroll = token },
                                    delete: { tokenToDelete = token }
                                )
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Remote Access")
        .onAppear { hostnameDraft = serverController.remoteAccessHostname }
        .onChange(of: serverController.remoteAccessHostname) { _, name in hostnameDraft = name }
        .sheet(isPresented: $isEnteringAuthKey) {
            AuthKeyView { key in serverController.logInToRemoteAccess(authKey: key) }
        }
        .alert("Log Out of Tailscale?", isPresented: $isConfirmingLogOut) {
            Button("Log Out", role: .destructive) {
                serverController.logOutOfRemoteAccess()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Clients on your other devices can't connect until iMCP logs in again. Your access tokens stay the same."
            )
        }
        .sheet(item: $editingToken) { editing in
            AccessTokenEditor(serverController: serverController, token: editing.token) { name, permissions in
                reportingTokenError(suspendsToken: editing.token != nil) {
                    if let token = editing.token {
                        try serverController.updateAccessToken(id: token.id, name: name, permissions: permissions)
                    } else {
                        let secret = try serverController.createAccessToken(name: name, permissions: permissions)
                        revealedSecret = RevealedSecret(name: name, secret: secret)
                    }
                }
            }
        }
        .sheet(item: $revealedSecret) { revealed in
            AccessTokenSecretView(
                name: revealed.name,
                secret: revealed.secret,
                endpoint: serverController.preferredClientEndpoint
            )
        }
        .alert(
            "Re-roll \"\(tokenToReroll?.name ?? "")\"?",
            isPresented: isPresented($tokenToReroll),
            presenting: tokenToReroll
        ) { token in
            Button("Re-roll", role: .destructive) {
                reportingTokenError {
                    if let secret = try serverController.rerollAccessToken(id: token.id) {
                        revealedSecret = RevealedSecret(name: token.name, secret: secret)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(
                "Clients that use the current token lose access right away. The token keeps its name and access, and iMCP shows the new token once."
            )
        }
        .alert(
            "Delete \"\(tokenToDelete?.name ?? "")\"?",
            isPresented: isPresented($tokenToDelete),
            presenting: tokenToDelete
        ) { token in
            Button("Delete", role: .destructive) {
                reportingTokenError { try serverController.deleteAccessToken(id: token.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Clients that use this token lose access right away.")
        }
        .alert(
            "Couldn't Save Access Tokens",
            isPresented: Binding(get: { tokenError != nil }, set: { if !$0 { tokenError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(tokenError ?? "")
        }
    }

    @ViewBuilder
    private func nodeRows(for state: RemoteAccessServer.State) -> some View {
        switch state {
        case .needsLogin(let url):
            LabeledContent {
                HStack {
                    Button("Use Auth Key…") { isEnteringAuthKey = true }
                    if let url {
                        Button("Log In…") { openURL(url) }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Get Login Link") { serverController.restartRemoteAccessNode() }
                    }
                }
            } label: {
                Text("Log In to Tailscale")
                Text(
                    url == nil
                        ? "iMCP is waiting for a login link from Tailscale."
                        : "Log in with the account that you use on your other devices to add iMCP to your tailnet."
                )
            }
        case .needsApproval:
            LabeledContent {
                Button("Log Out…") { isConfirmingLogOut = true }
            } label: {
                Text("Waiting for Approval")
                Text("An admin of your tailnet must approve this device in the Tailscale admin console.")
            }
        case .running(let endpoint):
            LabeledContent("URL") {
                HStack {
                    Text(endpoint.url)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Copy") {
                        copyToPasteboard(endpoint.url)
                    }
                }
            }
            if let dnsName = endpoint.dnsName {
                LabeledContent("MagicDNS Name") {
                    Text(dnsName)
                        .textSelection(.enabled)
                }
            }
            LabeledContent("Tailnet Address") {
                VStack(alignment: .trailing) {
                    Text(endpoint.ipv4Address)
                    if let ipv6Address = endpoint.ipv6Address {
                        Text(ipv6Address)
                    }
                }
                .textSelection(.enabled)
            }
            LabeledContent("Tailscale Account") {
                Button("Log Out…") { isConfirmingLogOut = true }
            }
        case .failed:
            HStack {
                Spacer()
                Button("Try Again") { serverController.restartRemoteAccessNode() }
            }
        case .off, .starting, .loggingOut:
            EmptyView()
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { serverController.isRemoteAccessEnabled },
            set: { serverController.isRemoteAccessEnabled = $0 }
        )
    }

    private var funnelBinding: Binding<Bool> {
        Binding(
            get: { serverController.isRemoteAccessFunnelEnabled },
            set: { serverController.isRemoteAccessFunnelEnabled = $0 }
        )
    }

    private var portBinding: Binding<Int> {
        Binding(
            get: { serverController.remoteAccessPort },
            set: { serverController.remoteAccessPort = $0 }
        )
    }

    /// Runs a token change and shows an alert if iMCP can't save it.
    /// A change to an existing token that doesn't save suspends the token.
    private func reportingTokenError(suspendsToken: Bool = true, _ change: () throws -> Void) {
        do {
            try change()
        } catch {
            tokenError =
                suspendsToken
                ? "\(error.localizedDescription) The token doesn't work until a change to it saves."
                : error.localizedDescription
        }
    }

    private func isPresented(_ item: Binding<AccessToken?>) -> Binding<Bool> {
        Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )
    }
}

private struct EditingToken: Identifiable {
    let id = UUID()
    /// The token to edit, or `nil` for a new token.
    let token: AccessToken?
}

private struct RevealedSecret: Identifiable {
    let id = UUID()
    let name: String
    let secret: String
}

extension RemoteAccessServer.State {
    var endpoint: String? {
        if case .running(let endpoint) = self { endpoint.url } else { nil }
    }
}

private struct RemoteAccessStatusView: View {
    let state: RemoteAccessServer.State

    var body: some View {
        switch state {
        case .off:
            Text("Off")
                .foregroundStyle(.secondary)
        case .starting:
            Text("Connecting to Tailscale…")
                .foregroundStyle(.secondary)
        case .needsLogin:
            Text("Not logged in")
                .foregroundStyle(.orange)
        case .needsApproval:
            Text("Waiting for approval")
                .foregroundStyle(.orange)
        case .loggingOut:
            Text("Logging out…")
                .foregroundStyle(.secondary)
        case .failed(let reason):
            Text(reason)
                .foregroundStyle(.red)
        case .running:
            Text("On")
                .foregroundStyle(.green)
        }
    }
}

/// Logs iMCP's node in with an auth key, which iMCP uses once and doesn't keep.
private struct AuthKeyView: View {
    let logIn: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Log In with an Auth Key")
                .font(.headline)
            Text(
                "Create an auth key in the Keys page of the Tailscale admin console. Use a key without tags, so that iMCP's device belongs to you. iMCP uses the key once and doesn't keep it."
            )
            .fixedSize(horizontal: false, vertical: true)
            SecureField("Auth Key", text: $key, prompt: Text("tskey-auth-…"))
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Log In") {
                    logIn(key)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// The apps that the owner approved through public access, with a button to end each one.
private struct ConnectedAppsSection: View {
    @ObservedObject var model: OAuthConnectionsModel
    @State private var appToRevoke: OAuthGrant?
    @State private var revokeError: String?

    var body: some View {
        Section {
            if let error = model.storageError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else if model.grants.isEmpty {
                Text(
                    "No apps are connected. When an app asks to connect through public access, you approve it here on your Mac."
                )
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
                                }
                                    ?? "Not used yet.")
                        )
                    }
                }
            }
        } header: {
            Text("Connected Apps")
        } footer: {
            Text("Revoking an app ends its access right away. It has to ask you to connect again.")
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
                    revokeError = "\(error.localizedDescription) The app can't connect until iMCP saves the change."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The app loses access right away.")
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

private struct AccessTokenRow: View {
    @ObservedObject var serverController: ServerController
    let token: AccessToken
    let edit: () -> Void
    let reroll: () -> Void
    let delete: () -> Void

    var body: some View {
        LabeledContent {
            HStack {
                Button("Edit…", action: edit)
                Menu {
                    Button("Re-roll…", action: reroll)
                    Button("Delete…", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }
        } label: {
            Text(token.name)
            Text(accessSummary)
            Text(token.boundDevice.map { "Bound to \($0.name)" } ?? "Not yet bound to a device")
            Text(usageSummary)
        }
    }

    private var accessSummary: String {
        let availableNames = serverController.availableToolNames
        let available = serverController.allTools.filter {
            token.permissions.allows($0) && availableNames.contains($0.name)
        }.count
        let access =
            switch token.permissions {
            case .readOnly: "Read-only tools"
            case .allTools: "All tools"
            case .custom: "Custom"
            }
        return "\(access), \(available) available now"
    }

    private var usageSummary: String {
        guard let lastUsedAt = token.lastUsedAt else {
            return token.rolledAt == nil ? "Not used yet" : "Not used since it was re-rolled"
        }
        let date = lastUsedAt.formatted(.relative(presentation: .named))
        if let device = token.lastUsedDevice {
            return "Last used \(date) from \(device)"
        }
        return "Last used \(date)"
    }
}

/// Creates or changes a token's name and access.
private struct AccessTokenEditor: View {
    @ObservedObject var serverController: ServerController
    let token: AccessToken?
    let save: (String, ToolPermissions) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var access: Access
    @State private var customTools: Set<String>

    enum Access: Hashable {
        case readOnly
        case allTools
        case custom
    }

    init(
        serverController: ServerController,
        token: AccessToken?,
        save: @escaping (String, ToolPermissions) -> Void
    ) {
        self.serverController = serverController
        self.token = token
        self.save = save
        _name = State(initialValue: token?.name ?? "")
        switch token?.permissions ?? .readOnly {
        case .readOnly:
            _access = State(initialValue: .readOnly)
            _customTools = State(initialValue: [])
        case .allTools:
            _access = State(initialValue: .allTools)
            _customTools = State(initialValue: [])
        case .custom(let names):
            _access = State(initialValue: .custom)
            _customTools = State(initialValue: names)
        }
    }

    private var permissions: ToolPermissions {
        switch access {
        case .readOnly: .readOnly
        case .allTools: .allTools
        case .custom: .custom(customTools)
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let availableNames = serverController.availableToolNames

        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("MacBook Pro"))
                } footer: {
                    Text("Use a name that helps you recognize the client, such as its device or app.")
                }

                Section("Access") {
                    Picker("Access", selection: $access) {
                        Text("Read-only tools").tag(Access.readOnly)
                        Text("All tools").tag(Access.allTools)
                        Text("Custom").tag(Access.custom)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .onChange(of: access) { oldValue, newValue in
                        // Start a custom selection from the access that was selected before.
                        guard newValue == .custom, customTools.isEmpty else { return }
                        let previous: ToolPermissions = oldValue == .allTools ? .allTools : .readOnly
                        customTools = previous.allowedNames(in: serverController.allTools)
                    }

                    Text(accessDescription)
                        .foregroundStyle(.secondary)
                }

                if access == .custom {
                    ForEach(serverController.toolGroups, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.tools, id: \.name) { tool in
                                toolToggle(tool, isAvailable: availableNames.contains(tool.name))
                            }
                        }
                    }
                }

                Section {
                    Text(availabilitySummary(availableNames: availableNames))
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(token == nil ? "Create" : "Save") {
                    save(trimmedName, permissions)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: access == .custom ? 620 : 440)
    }

    private var accessDescription: String {
        switch access {
        case .readOnly:
            "Tools that only read data, including read-only tools in later versions of iMCP."
        case .allTools:
            "Every tool, including tools that change your data or act for you, and tools in later versions of iMCP."
        case .custom:
            "Only the tools that you select. Tools in later versions of iMCP aren't included."
        }
    }

    private func toolToggle(_ tool: Tool, isAvailable: Bool) -> some View {
        Toggle(
            isOn: Binding(
                get: { customTools.contains(tool.name) },
                set: { isOn in
                    if isOn {
                        customTools.insert(tool.name)
                    } else {
                        customTools.remove(tool.name)
                    }
                }
            )
        ) {
            HStack(spacing: 6) {
                if let title = tool.annotations.title {
                    Text(title)
                } else {
                    Text(tool.name)
                        .monospaced()
                }
                if tool.annotations.readOnlyHint == true {
                    Text("Read-only")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                }
            }
            if !isAvailable {
                Text("Off in iMCP. The token can't use this tool until you turn it on.")
            }
        }
        .controlSize(.mini)
        .help(tool.description)
    }

    private func availabilitySummary(availableNames: Set<String>) -> String {
        let allowed = serverController.allTools.filter(permissions.allows)
        let available = allowed.filter { availableNames.contains($0.name) }.count
        let unavailable = allowed.count - available
        var summary = "Clients with this token can use \(available) \(available == 1 ? "tool" : "tools") now."
        if unavailable > 0 {
            summary +=
                " The token also allows \(unavailable) \(unavailable == 1 ? "tool that is" : "tools that are") off in iMCP. Clients can use \(unavailable == 1 ? "it" : "them") only after you turn \(unavailable == 1 ? "it" : "them") on in Services."
        }
        return summary
    }
}

/// Shows a new token's secret, which iMCP can't show again.
private struct AccessTokenSecretView: View {
    let name: String
    let secret: String
    let endpoint: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Copy the Token for \"\(name)\"")
                .font(.headline)
            Text(
                "iMCP doesn't keep a copy of this token, so you can't see it again. If you lose it, re-roll the token to get a new one."
            )
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(secret)
                    .monospaced()
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy") {
                    copyToPasteboard(secret)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))

            VStack(alignment: .leading, spacing: 8) {
                Text("Client Setup")
                    .font(.subheadline.weight(.semibold))
                LabeledContent("URL") {
                    Text(endpoint ?? "Turn on remote access to see the URL.")
                        .textSelection(.enabled)
                }
                LabeledContent("Header") {
                    Text("Authorization: Bearer <token>")
                        .monospaced()
                }
                if let endpoint {
                    let command =
                        "claude mcp add --transport http iMCP \(endpoint) --header \"Authorization: Bearer \(secret)\""
                    LabeledContent("Claude Code") {
                        Button("Copy Command") {
                            copyToPasteboard(command)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
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
            Text("Tailscale ACL Missing `funnel` Capability")
                .font(.subheadline.weight(.semibold))
            Text(
                "Add this `nodeAttrs` entry to your Tailscale ACL policy so this node (\(ipv4Address)) can serve Funnel traffic:"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(snippet)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            HStack {
                Button("Copy nodeAttrs Snippet") {
                    copyToPasteboard(snippet)
                }
                Button("Open Tailscale ACLs…") {
                    if let url = URL(string: "https://login.tailscale.com/admin/acls/file") {
                        openURL(url)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Guided setup and status for Cloudflare Tunnel (`cloudflared`).
private struct CloudflareTunnelSection: View {
    @ObservedObject var cloudflare: CloudflareTunnelController

    @State private var isShowingCredentialSheet = false
    @State private var isConfirmingLogOut = false

    var body: some View {
        Section {
            if cloudflare.account == nil {
                loginRows
            } else {
                configuredRows
            }
        } header: {
            Text("Cloudflare Tunnel")
        } footer: {
            Text(
                "Exposes iMCP at your own custom HTTPS hostname via Cloudflare without needing Tailscale. iMCP provisions a per-Mac tunnel, sets its ingress to the local loopback server, and manages the proxied DNS CNAME record automatically."
            )
        }
        .onAppear { cloudflare.refreshEnvironment() }
        .sheet(isPresented: $isShowingCredentialSheet) {
            CloudflareCredentialSheet(cloudflare: cloudflare)
        }
        .alert("Log Out of Cloudflare?", isPresented: $isConfirmingLogOut) {
            Button("Log Out", role: .destructive) {
                cloudflare.logOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stops the Cloudflare tunnel and removes the saved Cloudflare token from the Keychain.")
        }
    }

    @ViewBuilder
    private var loginRows: some View {
        LabeledContent("Status") {
            CloudflareStatusView(state: cloudflare.state)
        }

        if case .failed(let reason) = cloudflare.state {
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }

        if !cloudflare.isBinaryAvailable {
            HStack {
                Label(
                    "Install `cloudflared` (`brew install cloudflared`) to run browser login and tunnels.",
                    systemImage: "terminal"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Copy Command") {
                    copyToPasteboard("brew install cloudflared")
                }
            }
        }

        LabeledContent {
            HStack {
                Button("Use API Token…") {
                    isShowingCredentialSheet = true
                }
                Button("Log In with Browser") {
                    Task { await cloudflare.logInWithBrowser() }
                }
                .disabled(!cloudflare.isBinaryAvailable || cloudflare.state == .loggingIn)
                if cloudflare.detectedCertURL != nil {
                    Button("Use Local cert.pem") {
                        Task { await cloudflare.useDetectedCert() }
                    }
                }
            }
        } label: {
            Text("Connect Cloudflare")
            Text("Sign in with `cloudflared tunnel login` or paste a Cloudflare API token / `cert.pem`.")
        }
    }

    @ViewBuilder
    private var configuredRows: some View {
        Toggle(isOn: enabledBinding) {
            Text("Public Access (Cloudflare Tunnel)")
            Text("Serves iMCP publicly over HTTPS on your Cloudflare domain.")
        }
        .disabled(cloudflare.zones.isEmpty && !cloudflare.isEnabled)

        LabeledContent("Status") {
            CloudflareStatusView(state: cloudflare.state)
        }

        if case .failed(let reason) = cloudflare.state {
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }

        if !cloudflare.isBinaryAvailable {
            HStack {
                Label("`cloudflared` binary not found (`brew install cloudflared`).", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
                Button("Copy Command") {
                    copyToPasteboard("brew install cloudflared")
                }
            }
        }

        if cloudflare.zones.count > 1 {
            Picker("Domain", selection: $cloudflare.selectedZoneID) {
                ForEach(cloudflare.zones) { zone in
                    Text(zone.name).tag(zone.id)
                }
            }
        } else if let zone = cloudflare.selectedZone {
            LabeledContent("Domain") {
                Text(zone.name)
                    .textSelection(.enabled)
            }
        }

        LabeledContent("Hostname") {
            TextField(
                "Hostname",
                text: $cloudflare.hostnameDraft,
                prompt: Text("imcp.\(cloudflare.selectedZone?.name ?? "example.com")")
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 240)
            .onSubmit {
                Task { await cloudflare.provisionAndConnect() }
            }
        }

        if case .connected(let url, let tunnelName, _) = cloudflare.state {
            LabeledContent("Public URL") {
                HStack {
                    Text(url)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Copy") { copyToPasteboard(url) }
                }
            }
            LabeledContent("Tunnel") {
                Text(tunnelName)
                    .monospaced()
                    .textSelection(.enabled)
            }
        }

        LabeledContent("Actions") {
            HStack {
                if case .connected = cloudflare.state {
                    if isHostnameDirty {
                        Button("Update & Reconnect") {
                            Task { await cloudflare.provisionAndConnect() }
                        }
                    }
                    Button("Disconnect") {
                        cloudflare.disconnect()
                    }
                } else {
                    Button("Provision & Connect") {
                        Task { await cloudflare.provisionAndConnect() }
                    }
                    .disabled(
                        cloudflare.selectedZone == nil
                            || cloudflare.hostnameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || cloudflare.state == .provisioning
                            || !cloudflare.isBinaryAvailable
                    )
                }
                Button("Refresh Domains") {
                    Task { await cloudflare.refreshZones() }
                }
                Button("Log Out…", role: .destructive) {
                    isConfirmingLogOut = true
                }
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { cloudflare.isEnabled },
            set: { cloudflare.setEnabled($0) }
        )
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

private struct CloudflareStatusView: View {
    let state: CloudflareTunnelController.State

    var body: some View {
        switch state {
        case .off:
            Text("Not signed in")
                .foregroundStyle(.secondary)
        case .loggingIn:
            Text("Waiting for browser login…")
                .foregroundStyle(.secondary)
        case .discoveringZones:
            Text("Discovering domains…")
                .foregroundStyle(.secondary)
        case .ready:
            Text("Ready")
                .foregroundStyle(.secondary)
        case .provisioning:
            Text("Provisioning tunnel & DNS…")
                .foregroundStyle(.secondary)
        case .connected:
            Text("Connected")
                .foregroundStyle(.green)
        case .failed(let reason):
            Text(reason)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}

private struct CloudflareCredentialSheet: View {
    @ObservedObject var cloudflare: CloudflareTunnelController

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign In to Cloudflare")
                .font(.headline)
            Text(
                "Paste a Cloudflare API token (with Zone:Read, DNS:Edit, and Cloudflare Tunnel:Edit permissions) or paste the contents of `cert.pem`."
            )
            .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $input)
                .font(.body.monospaced())
                .frame(height: 110)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            HStack {
                Button("Import cert.pem…") {
                    chooseCertFile()
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    let value = input
                    dismiss()
                    Task { await cloudflare.logIn(credentialInput: value) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func chooseCertFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Select your Cloudflare cert.pem file (for example ~/.cloudflared/cert.pem)."
        if panel.runModal() == .OK, let url = panel.url {
            dismiss()
            Task { await cloudflare.importCertPEM(from: url) }
        }
    }
}

private func copyToPasteboard(_ string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
    _ = NSSound.play(.pop)
}
