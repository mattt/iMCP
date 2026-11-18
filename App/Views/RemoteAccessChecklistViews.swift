import SwiftUI

extension RemoteChoice {
    /// One short line that says what the way is for.
    var settingsCaption: String {
        switch self {
        case .local: "Only on your own network. Nothing is exposed."
        case .tailscale: "Private, from your own devices anywhere."
        case .funnel: "A public address for cloud apps, through Tailscale."
        case .cloudflare: "A public address on your own domain."
        }
    }

    var settingsSymbol: String {
        switch self {
        case .local: "house"
        case .tailscale: "lock.shield"
        case .funnel: "network"
        case .cloudflare: "cloud"
        }
    }
}

// MARK: - Checklists

/// The container of a checklist. In Settings each line is its own row of the form, with its own separator
/// and height, like every other row. In the Setup Assistant the lines stack in one column.
private struct ChecklistStack<Content: View>: View {
    let compact: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        if compact {
            Group { content() }
        } else {
            VStack(alignment: .leading, spacing: 10) { content() }
        }
    }
}

/// The Tailscale lines of the checklist, with the live state beside each.
/// The Setup Assistant and the Remote Access tab in Settings both show it.
struct TailscaleChecklistView: View {
    let inputs: TailscaleChecklist.Inputs
    /// Opens a page that Tailscale asked the person to visit, and re-checks until the permission shows up.
    let openTailscalePage: (URL) -> Void
    let getSignInLink: () -> Void
    var compact = false
    @Environment(\.openURL) private var openURL

    private func open(_ item: ChecklistItem, _ url: URL) {
        if item.kind == .signedIn { openURL(url) } else { openTailscalePage(url) }
    }

    var body: some View {
        ChecklistStack(compact: compact) {
            if compact {
                CompactChecklist(
                    items: TailscaleChecklist.items(inputs),
                    openLink: open,
                    doneTitle: "Tailscale is on",
                    doneSymbol: "lock.shield",
                    doneColor: .indigo,
                    inline: { _ in EmptyView() }
                )
            } else {
                ForEach(TailscaleChecklist.items(inputs)) { item in
                    ChecklistRow(
                        title: ChecklistTitles.title(for: item.kind),
                        item: item,
                        openLink: { url in open(item, url) }
                    )
                }
            }
            if case .needsLogin(nil) = inputs.node {
                Button("Get Sign-In Link", action: getSignInLink)
                    .checklistButton(compact: compact)
            }
        }
    }
}

/// The Cloudflare lines of the checklist, with sign-in, domain and hostname where each is needed.
struct CloudflareChecklistView: View {
    @ObservedObject var cloudflare: CloudflareTunnelController
    var compact = false
    @Environment(\.openURL) private var openURL

    /// The ways to sign in, under the sign-in line.
    private var signInControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Sign In with Browser") {
                    Task { await cloudflare.logInWithBrowser() }
                }
                .checklistButton(compact: compact)
                .disabled(!cloudflare.isBinaryAvailable || cloudflare.state == .loggingIn)
                if cloudflare.detectedCertURL != nil {
                    Button("Use Account on This Mac") {
                        Task { await cloudflare.useDetectedCert() }
                    }
                    .checklistButton(compact: compact)
                }
            }
            CloudflareTokenEntry(cloudflare: cloudflare, compact: compact)
        }
        .padding(.leading, 28)
    }

    var body: some View {
        let inputs = CloudflareChecklist.Inputs(
            isSignedIn: cloudflare.account != nil,
            activeDomains: cloudflare.zones.map(\.name),
            selectedDomain: cloudflare.selectedZone?.name,
            hostnameInput: cloudflare.hostnameDraft,
            isBinaryAvailable: cloudflare.isBinaryAvailable
        )
        let items = CloudflareChecklist.items(inputs)

        ChecklistStack(compact: compact) {
            if compact {
                CompactChecklist(
                    items: items,
                    openLink: { _, url in openURL(url) },
                    doneTitle: cloudflare.state.activeURL == nil ? "Ready" : "Tunnel is on",
                    doneSubtitle: cloudflare.state.activeURL,
                    doneSymbol: "cloud.fill",
                    doneColor: .orange,
                    inline: { item in
                        if item.kind == .signIn, cloudflare.account == nil {
                            signInControls
                        }
                    }
                )
                if cloudflare.account != nil {
                    if cloudflare.zones.count > 1 {
                        LabeledContent {
                            Picker("Domain", selection: $cloudflare.selectedZoneID) {
                                ForEach(cloudflare.zones) { zone in Text(zone.name).tag(zone.id) }
                            }
                            .labelsHidden()
                        } label: {
                            RowLabel(title: "Domain") { SettingsIcon(symbol: "globe", color: .blue) }
                        }
                    }
                    LabeledContent {
                        TextField(
                            "Address",
                            text: $cloudflare.hostnameDraft,
                            prompt: Text("imcp.\(cloudflare.selectedZone?.name ?? "example.com")")
                        )
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("onboarding.cloudflare.hostname")
                    } label: {
                        RowLabel(title: "Address") { SettingsIcon(symbol: "link", color: .teal) }
                    }
                }
                if case .failed(let reason) = cloudflare.state {
                    RowLabel(title: "Couldn't connect", subtitle: reason) {
                        SettingsIcon(symbol: "exclamationmark.triangle.fill", color: .red)
                    }
                }
                if cloudflare.state.activeURL == nil, CloudflareChecklist.isReady(items) {
                    Button {
                        Task { await cloudflare.provisionAndConnect() }
                    } label: {
                        RowLabel(title: "Set up the tunnel") { SettingsIcon(symbol: "bolt.fill", color: .green) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("onboarding.cloudflare.setUp")
                }
            } else {
                ForEach(items) { item in
                    ChecklistRow(title: ChecklistTitles.title(for: item.kind), item: item, openLink: { openURL($0) })
                    if item.kind == .signIn, cloudflare.account == nil {
                        signInControls
                    }
                    if item.kind == .domain, cloudflare.zones.count > 1 {
                        Picker("Domain", selection: $cloudflare.selectedZoneID) {
                            ForEach(cloudflare.zones) { zone in Text(zone.name).tag(zone.id) }
                        }
                        .padding(.leading, 28)
                    }
                    if item.kind == .hostname, cloudflare.account != nil {
                        TextField(
                            "Hostname",
                            text: $cloudflare.hostnameDraft,
                            prompt: Text("imcp.\(cloudflare.selectedZone?.name ?? "example.com")")
                        )
                        .textFieldStyle(.roundedBorder)
                        .padding(.leading, 28)
                        .accessibilityIdentifier("onboarding.cloudflare.hostname")
                    }
                }
            }

            if !compact, let url = cloudflare.state.activeURL {
                Label("Connected at \(url)", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
            } else if !compact, case .failed(let reason) = cloudflare.state {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            // Once it is connected there is nothing left to set up, so the button goes in Settings.
            if !compact {
                Button("Set Up Tunnel") {
                    Task { await cloudflare.provisionAndConnect() }
                }
                .checklistButton(compact: compact)
                .disabled(!CloudflareChecklist.isReady(items) || cloudflare.state.activeURL != nil)
                .accessibilityIdentifier("onboarding.cloudflare.setUp")
            }
        }
    }
}

extension View {
    /// A checklist button: the Setup Assistant's glass button, or a plain bordered one in Settings.
    @ViewBuilder
    func checklistButton(compact: Bool) -> some View {
        if compact {
            self.buttonStyle(.bordered).controlSize(.regular)
        } else {
            self.onboardingSecondary()
        }
    }
}

enum ChecklistTitles {
    static func title(for kind: ChecklistItem.Kind) -> String {
        switch kind {
        case .signedIn: "Signed in to Tailscale"
        case .online: "This Mac is on your Tailscale network"
        case .name: "This Mac has a name"
        case .funnelAllowed: "Public addresses are allowed"
        case .publicAddress: "Public address is on"
        case .cloudflareAccount: "A Cloudflare account"
        case .domain: "A domain managed by Cloudflare"
        case .signIn: "iMCP can use your account"
        case .hostname: "A name for iMCP on that domain"
        case .willCreate: "What iMCP creates"
        }
    }
}

/// One line of a checklist: a check, a spinner, or a button, with the reason beneath.
struct ChecklistRow: View {
    let title: String
    let item: ChecklistItem
    let openLink: (URL) -> Void
    /// One line for a finished item, with its reason only when something is left to do.
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                if let detail = item.detail, !(compact && item.isDone) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if case .needsAction(let link) = item.status, let link {
                    Button(buttonTitle) { openLink(link) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var buttonTitle: String {
        switch item.kind {
        case .cloudflareAccount: "Create a Cloudflare account"
        case .domain: "Add a domain to Cloudflare"
        default: "Open in Tailscale"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item.status {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .waiting:
            ProgressView().controlSize(.small)
        case .pending:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .needsAction:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        }
    }
}

/// What a step in Settings says to do, in plain words.
extension ChecklistTitles {
    static func action(for kind: ChecklistItem.Kind) -> String {
        switch kind {
        case .signedIn: "Sign in to Tailscale"
        case .online: "Connect this Mac to Tailscale"
        case .name: "Give this Mac a name"
        case .funnelAllowed: "Allow public addresses"
        case .publicAddress: "Turn on the public address"
        case .cloudflareAccount: "Create a Cloudflare account"
        case .domain: "Add a domain to Cloudflare"
        case .signIn: "Sign in to Cloudflare"
        case .hostname: "Choose an address"
        case .willCreate: "What iMCP creates"
        }
    }

    static func symbol(for kind: ChecklistItem.Kind) -> String {
        switch kind {
        case .signedIn, .signIn: "person.crop.circle"
        case .online: "wifi"
        case .name, .hostname: "link"
        case .funnelAllowed, .publicAddress: "network"
        case .cloudflareAccount: "cloud"
        case .domain: "globe"
        case .willCreate: "info.circle"
        }
    }
}

/// A step in Settings that still needs something: an icon, what to do, one line of why, and a link if there is one.
private struct StepRow: View {
    let item: ChecklistItem
    let openLink: (URL) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if item.status == .waiting {
                    ProgressView().controlSize(.small).frame(width: 32, height: 32)
                } else {
                    SettingsIcon(symbol: ChecklistTitles.symbol(for: item.kind), color: tint)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ChecklistTitles.action(for: item.kind))
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .needsAction(let link) = item.status, let link {
                    Button(linkTitle) { openLink(link) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var linkTitle: String {
        switch item.kind {
        case .cloudflareAccount, .domain, .signIn, .hostname: "Open Cloudflare"
        default: "Open Tailscale"
        }
    }

    private var tint: Color {
        if case .needsAction = item.status { return .orange }
        return .gray
    }
}

/// A checklist for Settings. Finished steps disappear: when every step is done it is one row that says so,
/// and until then it shows only the steps that still need something.
struct CompactChecklist<Inline: View>: View {
    let items: [ChecklistItem]
    let openLink: (ChecklistItem, URL) -> Void
    var doneTitle = "Ready"
    var doneSubtitle: String?
    var doneSymbol = "checkmark"
    var doneColor: Color = .green
    /// Controls that belong under a step that is not done yet.
    @ViewBuilder var inline: (ChecklistItem) -> Inline

    var body: some View {
        // "What iMCP creates" is an explanation, not a step; Settings says it once under the section.
        let steps = items.filter { $0.kind != .willCreate }
        let todo = steps.filter { !$0.isDone }

        if todo.isEmpty {
            RowLabel(title: doneTitle, subtitle: doneSubtitle) {
                SettingsIcon(symbol: doneSymbol, color: doneColor)
            }
        } else {
            ForEach(todo) { item in
                StepRow(item: item, openLink: { openLink(item, $0) })
                inline(item)
            }
        }
    }
}
