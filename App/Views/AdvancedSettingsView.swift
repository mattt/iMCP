import AppKit
import SwiftUI

/// The Advanced tab: technical details and settings that people rarely change.
struct AdvancedSettingsView: View {
    @ObservedObject var serverController: ServerController

    @State private var hostnameDraft = ""
    @State private var showsPhoneOverrides = false
    @State private var isEnteringAuthKey = false
    @State private var editingToken: EditingToken?
    @State private var revealedSecret: RevealedSecret?
    @State private var tokenToReroll: AccessToken?
    @State private var tokenToDelete: AccessToken?
    @State private var tokenError: String?

    @AppStorage(MobileService.tailscaleVPNEnabledKey) private var tailscaleVPNEnabled = true
    @AppStorage(MobileService.tailscaleHostOverrideKey) private var tailscaleHostOverride = ""
    @AppStorage(MobileService.cloudflareEnabledKey) private var cloudflareEnabled = false
    @AppStorage(MobileService.cloudflareURLKey) private var cloudflareURL = ""
    @AppStorage(MobileService.cloudflareLocalPortKey) private var cloudflareLocalPort = Int(
        MobileLink.defaultWebSocketPort
    )

    private let serverCommand = Bundle.main.bundleURL
        .appendingPathComponent("Contents/MacOS/imcp-server")
        .path

    private var activeTailnetHost: String? {
        if case .running(let endpoint) = serverController.remoteAccessState {
            return endpoint.dnsName ?? endpoint.ipv4Address
        }
        return nil
    }

    var body: some View {
        let tokens = serverController.accessTokens
        let storageError = serverController.accessTokenStorageError

        Form {
            Section {
                LabeledContent {
                    Button("Copy") { copyToSettingsPasteboard(serverCommand) }
                } label: {
                    RowLabel(title: "Server command", subtitle: serverCommand) {
                        SettingsIcon(symbol: "terminal.fill", color: .gray)
                    }
                }
            } header: {
                Text("Developer")
            }

            MobileDetailsSection()

            Section {
                ExpandableRow(isExpanded: $showsPhoneOverrides) {
                    RowLabel(title: "Phone connection overrides") {
                        SettingsIcon(symbol: "ipad.and.iphone", color: .blue)
                    }
                } content: {
                    Toggle(isOn: $tailscaleVPNEnabled) {
                        RowLabel(title: "Allow Tailscale") {
                            SettingsIcon(symbol: "lock.shield", color: .indigo)
                        }
                    }
                    if tailscaleVPNEnabled {
                        LabeledContent {
                            TextField(
                                "Tailscale host",
                                text: $tailscaleHostOverride,
                                prompt: Text(activeTailnetHost ?? "Automatic")
                            )
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                        } label: {
                            RowLabel(title: "Tailscale host") {
                                SettingsIcon(symbol: "server.rack", color: .gray)
                            }
                        }
                    }
                    Toggle(isOn: $cloudflareEnabled) {
                        RowLabel(title: "Use my own Cloudflare address") {
                            SettingsIcon(symbol: "cloud", color: .orange)
                        }
                    }
                    if cloudflareEnabled {
                        LabeledContent {
                            TextField("wss://example.com/mobile", text: $cloudflareURL)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                        } label: {
                            RowLabel(title: "Cloudflare address") {
                                SettingsIcon(symbol: "link", color: .orange)
                            }
                        }
                        LabeledContent {
                            TextField("Port", value: $cloudflareLocalPort, format: .number.grouping(.never))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        } label: {
                            RowLabel(title: "Local port") {
                                SettingsIcon(symbol: "number", color: .gray)
                            }
                        }
                    }
                }
            }
            .onChange(of: tailscaleVPNEnabled) { _, _ in applyMobileSettings() }
            .onChange(of: cloudflareEnabled) { _, _ in applyMobileSettings() }
            .onChange(of: cloudflareLocalPort) { _, _ in applyMobileSettings() }

            if serverController.isRemoteAccessEnabled {
                tailscaleSection
            }

            Section {
                if let storageError {
                    Label(storageError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if tokens.isEmpty {
                    EmptyRow(symbol: "key", text: "No access tokens")
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
                Button("Create Token…") { editingToken = EditingToken(token: nil) }
                    .disabled(storageError != nil)
            } header: {
                Text("Access tokens")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Advanced")
        .onAppear { hostnameDraft = serverController.remoteAccessHostname }
        .onChange(of: serverController.remoteAccessHostname) { _, name in hostnameDraft = name }
        .sheet(isPresented: $isEnteringAuthKey) {
            AuthKeyView { key in serverController.logInToRemoteAccess(authKey: key) }
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
            "Re-roll “\(tokenToReroll?.name ?? "")”?",
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
            Text("Clients that use the current token lose access right away. iMCP shows the new token once.")
        }
        .alert(
            "Delete “\(tokenToDelete?.name ?? "")”?",
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
            "Couldn't save access tokens",
            isPresented: Binding(get: { tokenError != nil }, set: { if !$0 { tokenError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(tokenError ?? "")
        }
    }

    private var tailscaleSection: some View {
        Section {
            LabeledContent {
                TextField(
                    "Device name",
                    text: $hostnameDraft,
                    prompt: Text(serverController.defaultRemoteAccessHostname)
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .onSubmit { serverController.remoteAccessHostname = hostnameDraft }
            } label: {
                RowLabel(title: "Device name") {
                    SettingsIcon(symbol: "desktopcomputer", color: .gray)
                }
            }
            LabeledContent {
                TextField(
                    "Port",
                    value: Binding(
                        get: { serverController.remoteAccessPort },
                        set: { serverController.remoteAccessPort = $0 }
                    ),
                    format: .number.grouping(.never)
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            } label: {
                RowLabel(title: "Port") {
                    SettingsIcon(symbol: "number", color: .gray)
                }
            }
            if case .running(let endpoint) = serverController.remoteAccessState {
                LabeledContent {
                    Button("Copy") { copyToSettingsPasteboard(endpoint.url) }
                } label: {
                    RowLabel(title: "Private address", subtitle: endpoint.url) {
                        SettingsIcon(symbol: "link", color: .teal)
                    }
                }
                LabeledContent {
                    VStack(alignment: .trailing) {
                        if let dnsName = endpoint.dnsName {
                            Text(dnsName)
                        }
                        Text(endpoint.ipv4Address)
                        if let ipv6Address = endpoint.ipv6Address {
                            Text(ipv6Address)
                        }
                    }
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                } label: {
                    RowLabel(title: "Name and IP address") {
                        SettingsIcon(symbol: "network", color: .gray)
                    }
                }
            }
            LabeledContent {
                Button("Use an Auth Key…") { isEnteringAuthKey = true }
            } label: {
                RowLabel(title: "Sign in without a browser") {
                    SettingsIcon(symbol: "key.fill", color: .gray)
                }
            }
        } header: {
            Text("Tailscale")
        }
    }

    private func applyMobileSettings() {
        Task { await MobileService.shared.applyTransportSettings() }
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

/// What this Mac has sent to paired devices, and what it keeps for them: revisions, addresses, sync times.
private struct MobileDetailsSection: View {
    @State private var devices: [MobileDevice] = []
    @State private var routes: [MobileConfigurationBuilder.Entry] = []
    @State private var configurationRevision = 0
    @State private var appliedRevisions: [String: Int] = [:]
    @State private var syncedAt: [MobileDomain: Date] = [:]
    @State private var isConfirmingDelete = false
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent {
                Text(String(configurationRevision)).font(.callout.monospaced())
            } label: {
                RowLabel(title: "Configuration revision") {
                    SettingsIcon(symbol: "number.circle.fill", color: .gray)
                }
            }
            ForEach(devices) { device in
                LabeledContent {
                    Text(revisionText(for: device)).font(.callout.monospaced())
                } label: {
                    RowLabel(title: device.name) {
                        SettingsIcon(
                            symbol: device.name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone",
                            color: .gray
                        )
                    }
                }
            }
            ForEach(routes.filter { $0.address != nil }) { entry in
                LabeledContent {
                    Text(entry.address ?? "")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } label: {
                    RowLabel(title: entry.kind.settingsName) {
                        SettingsIcon(symbol: entry.kind.settingsSymbol, color: .gray)
                    }
                }
            }
            ForEach(MobileDomain.allCases, id: \.self) { domain in
                LabeledContent {
                    Text(syncText(domain)).foregroundStyle(.secondary)
                } label: {
                    RowLabel(title: domain.label) {
                        SettingsIcon(symbol: domain == .health ? "heart.fill" : "alarm.fill", color: .pink)
                    }
                }
            }
            LabeledContent {
                Button("Delete…", role: .destructive) { isConfirmingDelete = true }
            } label: {
                RowLabel(title: "Cached phone data", subtitle: error) {
                    SettingsIcon(symbol: "trash", color: .red)
                }
            }
        } header: {
            Text("iPhone and iPad")
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .alert("Delete the cached data?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await MobileService.shared.deleteCache()
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                    await refresh()
                }
            }
        } message: {
            Text("Paired devices send their data again the next time they connect.")
        }
    }

    private func refresh() async {
        let service = MobileService.shared
        devices = await service.devices
        routes = MobileConfigurationBuilder.entries(await service.currentState)
        configurationRevision = await service.currentConfiguration.revision
        for device in devices {
            appliedRevisions[device.id] = await service.appliedConfigurationRevision(for: device.id)
        }
        for domain in MobileDomain.allCases {
            syncedAt[domain] = await service.syncedAt(domain)
        }
    }

    private func revisionText(for device: MobileDevice) -> String {
        guard let applied = appliedRevisions[device.id] else { return "Not confirmed" }
        return applied == configurationRevision ? String(applied) : "\(applied), Mac is on \(configurationRevision)"
    }

    private func syncText(_ domain: MobileDomain) -> String {
        guard let date = syncedAt[domain] else { return "Never synced" }
        let stale = MobileEnvelope.isStale(domain, syncedAt: date, now: Date())
        return "\(date.formatted(.relative(presentation: .named)))\(stale ? ", stale" : "")"
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
                    copyToSettingsPasteboard(secret)
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
                            copyToSettingsPasteboard(command)
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
