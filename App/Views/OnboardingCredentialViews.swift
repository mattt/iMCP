import SwiftUI

// Optional credential entry for the Remote Access set-up screen. Both are quiet, secondary choices:
// the main path stays the browser sign-in and Tailscale's own page.

/// Cloudflare: paste an API token instead of signing in with the browser.
struct CloudflareTokenEntry: View {
    @ObservedObject var cloudflare: CloudflareTunnelController
    /// In Settings, buttons are plain bordered ones; the Setup Assistant uses its glass buttons.
    var compact = false
    @Environment(\.openURL) private var openURL

    @State private var isOpen = false
    @State private var token = ""
    @State private var verdict: CloudflareTokenVerification?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: OnboardingSpacing.small) {
            if cloudflare.account != nil {
                if cloudflare.isSignedInWithToken {
                    HStack {
                        Text("Signed in with an API token.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Remove Token") {
                            cloudflare.logOut()
                            token = ""
                            verdict = nil
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .accessibilityIdentifier("onboarding.cloudflare.removeToken")
                    }
                }
            } else {
                Button(isOpen ? "Hide API Token" : "Use an API Token") { isOpen.toggle() }
                    .checklistButton(compact: compact)
                    .accessibilityIdentifier("onboarding.cloudflare.useToken")
                if isOpen { entry }
            }
        }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: OnboardingSpacing.small) {
            Text("Create a token on Cloudflare with these permissions, then paste it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(CloudflareChecklist.permissionLines, id: \.self) { line in
                    Text(line).font(.caption.monospaced())
                }
            }
            .textSelection(.enabled)
            Button("Open Cloudflare's Token Page") { openURL(CloudflareChecklist.apiTokensURL) }
                .buttonStyle(.link)
                .font(.caption)

            SecureField("API token", text: $token)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("onboarding.cloudflare.token")
                .onChange(of: token) { verdict = nil }

            HStack {
                Button("Check and Use Token") { Task { await checkAndUse() } }
                    .checklistButton(compact: compact)
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                    .accessibilityIdentifier("onboarding.cloudflare.checkToken")
                if isWorking { ProgressView().controlSize(.small) }
            }
            if let verdict {
                Label(
                    verdict.summary,
                    systemImage: verdict.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(verdict.isValid ? Color.green : Color.red)
                .fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let reason) = cloudflare.state, verdict?.isValid == true {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func checkAndUse() async {
        isWorking = true
        defer { isWorking = false }
        let result = await cloudflare.checkAPIToken(token)
        verdict = result
        guard result.isValid else { return }
        await cloudflare.signIn(withAPIToken: token)
        if cloudflare.account != nil {
            token = ""
            isOpen = false
        }
    }
}

/// Tailscale: let iMCP change the access controls itself, with a review and a confirmation first.
struct TailscaleAutoEnable: View {
    @ObservedObject var access: TailscaleAccessController
    /// The Tailscale address of this Mac. Nil until the node is online.
    let target: String?
    var compact = false
    @Environment(\.openURL) private var openURL

    @State private var isOpen = false
    @State private var credential = ""
    @State private var showsExactChange = false

    var body: some View {
        VStack(alignment: .leading, spacing: OnboardingSpacing.small) {
            if target != nil {
                Button(isOpen ? "Hide" : "Let iMCP turn this on for me") { isOpen.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityIdentifier("onboarding.tailscale.autoEnable")
                if isOpen, let target { content(target: target) }
            }
        }
    }

    @ViewBuilder
    private func content(target: String) -> some View {
        switch access.phase {
        case .review(let plan):
            review(plan)
        case .working(let message):
            HStack {
                ProgressView().controlSize(.small)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        case .done:
            Label("Done. Public addresses are allowed for this Mac.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .alreadyAllowed:
            Label("Your policy already allows this. Nothing to change.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .idle, .failed:
            credentialEntry(target: target)
        }
    }

    private func credentialEntry(target: String) -> some View {
        VStack(alignment: .leading, spacing: OnboardingSpacing.small) {
            Text(
                "Paste a Tailscale API access token, or the secret of an OAuth client, that can edit access controls. iMCP keeps it in your Keychain."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button("Open Tailscale's Key Page") {
                openURL(URL(string: "https://login.tailscale.com/admin/settings/keys")!)
            }
            .buttonStyle(.link)
            .font(.caption)

            if access.hasCredential {
                HStack {
                    Button("Review the Change") { Task { await access.prepare(target: target) } }
                        .checklistButton(compact: compact)
                    Button("Remove Token") { access.removeCredential() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            } else {
                SecureField("Access token", text: $credential)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("onboarding.tailscale.token")
                Button("Review the Change") {
                    let pasted = credential
                    credential = ""
                    Task { await access.useCredential(pasted, target: target) }
                }
                .checklistButton(compact: compact)
                .disabled(credential.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if case .failed(let reason) = access.phase {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func review(_ plan: TailscaleAccessController.Plan) -> some View {
        VStack(alignment: .leading, spacing: OnboardingSpacing.small) {
            Label(plan.summary, systemImage: "plus.circle")
                .font(.subheadline)
            Text("Nothing else in your policy changes. If someone edits it first, iMCP saves nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ExpandableRow(isExpanded: $showsExactChange) {
                Text("Show the exact change")
            } content: {
                Text("nodeAttrs, new entry:\n" + plan.entryText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            HStack {
                Button("Allow Public Addresses") { Task { await access.confirm() } }
                    .checklistButton(compact: compact)
                    .accessibilityIdentifier("onboarding.tailscale.confirm")
                Button("Cancel") { access.cancelReview() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}
