import Foundation

/// One line of a setup checklist. The setup window shows each as a check,
/// a spinner, or a button, and re-evaluates them as the live state changes.
struct ChecklistItem: Equatable, Identifiable, Sendable {
    enum Status: Equatable, Sendable {
        /// Satisfied.
        case done
        /// Not satisfied yet, and nothing to do but wait: iMCP is working or the person is mid-step.
        case waiting
        /// Not checked yet, because an earlier line has to be done first.
        case pending
        /// Needs the person. `link` opens the page where they can fix it.
        case needsAction(link: URL?)
    }

    enum Kind: String, Sendable {
        case signedIn, online, name, funnelAllowed, publicAddress
        case cloudflareAccount, domain, signIn, hostname, willCreate
    }

    let kind: Kind
    let status: Status
    /// The reason or the value, in plain words.
    let detail: String?

    var id: Kind { kind }
    var isDone: Bool { status == .done }
}

/// Finds the page that Tailscale asks a person to open to turn on Funnel or HTTPS.
/// Tailscale puts that address in the error that the node returns, so iMCP uses it as it is
/// instead of building one.
enum TailscaleEnablementLink {
    static func url(in message: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(message.startIndex..., in: message)
        let matches = detector?.matches(in: message, range: range) ?? []
        for match in matches {
            guard var url = match.url, url.scheme == "https", let host = url.host?.lowercased(),
                host == "tailscale.com" || host.hasSuffix(".tailscale.com")
            else { continue }
            // A sentence can end right after the address.
            let text = url.absoluteString
            if let last = text.last, ".,;)".contains(last), let trimmed = URL(string: String(text.dropLast())) {
                url = trimmed
            }
            return url
        }
        return nil
    }
}

/// The Tailscale lines of the Remote Access step, from the node's live state.
enum TailscaleChecklist {
    enum Node: Equatable, Sendable {
        case off
        case needsLogin(URL?)
        case starting
        case needsApproval
        case failed(String)
        case running(dnsName: String?)
    }

    enum PublicAddress: Equatable, Sendable {
        case off
        case active(URL)
        case failed(String)
    }

    struct Inputs: Equatable, Sendable {
        var node: Node
        /// Whether Tailscale reports that this device may use Funnel. Nil until it has said.
        var funnelAllowed: Bool?
        var publicAddress: PublicAddress
        var wantsPublicAddress: Bool
        /// The person opened a Tailscale page and iMCP is re-checking.
        var isWaitingForApproval = false
    }

    static func items(_ inputs: Inputs) -> [ChecklistItem] {
        var items: [ChecklistItem] = []

        // Signed in, and online.
        switch inputs.node {
        case .off:
            items.append(.init(kind: .signedIn, status: .waiting, detail: nil))
            items.append(.init(kind: .online, status: .pending, detail: nil))
        case .needsLogin(let url):
            items.append(
                .init(kind: .signedIn, status: .needsAction(link: url), detail: "Sign in with your Tailscale account.")
            )
            items.append(.init(kind: .online, status: .pending, detail: nil))
        case .starting:
            items.append(.init(kind: .signedIn, status: .done, detail: nil))
            items.append(.init(kind: .online, status: .waiting, detail: "Connecting…"))
        case .needsApproval:
            items.append(.init(kind: .signedIn, status: .done, detail: nil))
            items.append(
                .init(
                    kind: .online,
                    status: .waiting,
                    detail: "Waiting for you to approve this Mac in Tailscale."
                )
            )
        case .failed(let reason):
            items.append(.init(kind: .signedIn, status: .done, detail: nil))
            items.append(.init(kind: .online, status: .needsAction(link: nil), detail: reason))
        case .running:
            items.append(.init(kind: .signedIn, status: .done, detail: nil))
            items.append(.init(kind: .online, status: .done, detail: nil))
        }

        guard case .running(let dnsName) = inputs.node else {
            if inputs.wantsPublicAddress {
                items.append(.init(kind: .name, status: .pending, detail: nil))
                items.append(.init(kind: .funnelAllowed, status: .pending, detail: nil))
                items.append(.init(kind: .publicAddress, status: .pending, detail: nil))
            }
            return items
        }

        // The name Tailscale gives this Mac.
        if let dnsName, !dnsName.isEmpty {
            items.append(.init(kind: .name, status: .done, detail: dnsName))
        } else {
            items.append(
                .init(
                    kind: .name,
                    status: .needsAction(link: nil),
                    detail:
                        "Tailscale has not given this Mac a name yet. Names are turned on in your Tailscale settings."
                )
            )
        }
        guard inputs.wantsPublicAddress else { return items }

        // Permission to use a public address, then the address.
        let enablement: URL? = {
            if case .failed(let message) = inputs.publicAddress { return TailscaleEnablementLink.url(in: message) }
            return nil
        }()
        switch (inputs.funnelAllowed, inputs.publicAddress) {
        case (_, .active(let url)):
            items.append(.init(kind: .funnelAllowed, status: .done, detail: nil))
            items.append(.init(kind: .publicAddress, status: .done, detail: url.absoluteString))
        case (.some(true), .off):
            items.append(.init(kind: .funnelAllowed, status: .done, detail: nil))
            items.append(.init(kind: .publicAddress, status: .waiting, detail: "Turning on…"))
        case (.some(true), .failed(let message)):
            items.append(.init(kind: .funnelAllowed, status: .done, detail: nil))
            items.append(.init(kind: .publicAddress, status: .needsAction(link: enablement), detail: message))
        case (_, .failed(let message)):
            items.append(
                .init(
                    kind: .funnelAllowed,
                    status: inputs.isWaitingForApproval ? .waiting : .needsAction(link: enablement),
                    detail: inputs.isWaitingForApproval
                        ? "Waiting for you to approve in Tailscale…"
                        : (enablement == nil ? message : "Tailscale needs you to allow public addresses.")
                )
            )
            items.append(.init(kind: .publicAddress, status: .pending, detail: nil))
        case (_, .off):
            items.append(
                .init(
                    kind: .funnelAllowed,
                    status: inputs.isWaitingForApproval ? .waiting : .needsAction(link: nil),
                    detail: inputs.isWaitingForApproval
                        ? "Waiting for you to approve in Tailscale…"
                        : "Tailscale has not said that this Mac may use a public address."
                )
            )
            items.append(.init(kind: .publicAddress, status: .pending, detail: nil))
        }
        return items
    }
}

/// What a Cloudflare Tunnel needs before iMCP tries anything, and what iMCP will do with it.
enum CloudflareChecklist {
    struct Inputs: Equatable, Sendable {
        var isSignedIn: Bool
        /// Domains that Cloudflare manages and that are active, once signed in.
        var activeDomains: [String]
        /// The domain chosen, when there is more than one.
        var selectedDomain: String?
        /// What the person typed for the address.
        var hostnameInput: String
        var isBinaryAvailable: Bool
    }

    static let accountSignupURL = URL(string: "https://dash.cloudflare.com/sign-up")!
    static let addSiteURL = URL(string: "https://dash.cloudflare.com/?to=/:account/add-site")!

    /// What iMCP asks Cloudflare to do, from the calls that `CloudflareAPIClient` makes.
    /// Each is the permission that the call needs, in Cloudflare's own words.
    struct Permission: Equatable, Sendable {
        let scope: String
        let name: String
        let access: String
        let reason: String
    }

    static let requiredPermissions: [Permission] = [
        Permission(scope: "Zone", name: "Zone", access: "Read", reason: "Find your domains"),
        Permission(scope: "Zone", name: "DNS", access: "Edit", reason: "Create the one address for iMCP"),
        Permission(scope: "Account", name: "Account Settings", access: "Read", reason: "Find your account"),
        Permission(scope: "Account", name: "Cloudflare Tunnel", access: "Edit", reason: "Create and run the tunnel"),
    ]

    /// The address to use: a typed name that is already on the domain stays as it is,
    /// and a short name gets the domain added.
    static func fullHostname(input: String, domain: String?) -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, let domain, !domain.isEmpty else { return nil }
        if name == domain || name.hasSuffix("." + domain) { return name }
        guard !name.contains("."), name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return name + "." + domain
    }

    static func items(_ inputs: Inputs) -> [ChecklistItem] {
        var items: [ChecklistItem] = []

        items.append(
            inputs.isSignedIn
                ? .init(kind: .cloudflareAccount, status: .done, detail: nil)
                : .init(
                    kind: .cloudflareAccount,
                    status: .needsAction(link: accountSignupURL),
                    detail: "You need a Cloudflare account. A free one is enough."
                )
        )

        if !inputs.isSignedIn {
            items.append(
                .init(kind: .domain, status: .pending, detail: "Checked after you sign in.")
            )
        } else if inputs.activeDomains.isEmpty {
            items.append(
                .init(
                    kind: .domain,
                    status: .needsAction(link: addSiteURL),
                    detail:
                        "No active domain found. The domain's name servers must point to Cloudflare. A domain that is only registered elsewhere will not work."
                )
            )
        } else {
            let domain = inputs.selectedDomain ?? inputs.activeDomains[0]
            items.append(.init(kind: .domain, status: .done, detail: domain))
        }

        if inputs.isSignedIn {
            items.append(.init(kind: .signIn, status: .done, detail: nil))
        } else if !inputs.isBinaryAvailable {
            items.append(
                .init(
                    kind: .signIn,
                    status: .needsAction(link: nil),
                    detail: "The Cloudflare helper is missing from this copy of iMCP."
                )
            )
        } else {
            items.append(
                .init(
                    kind: .signIn,
                    status: .needsAction(link: nil),
                    detail: "Sign in with your browser. iMCP does not see your password."
                )
            )
        }

        let domain = inputs.selectedDomain ?? inputs.activeDomains.first
        if let host = fullHostname(input: inputs.hostnameInput, domain: domain) {
            items.append(.init(kind: .hostname, status: .done, detail: host))
        } else if inputs.hostnameInput.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(
                .init(
                    kind: .hostname,
                    status: .pending,
                    detail: "Choose a name such as imcp.\(domain ?? "your-domain.com")."
                )
            )
        } else {
            items.append(
                .init(
                    kind: .hostname,
                    status: .needsAction(link: nil),
                    detail: "That name is not on \(domain ?? "your domain")."
                )
            )
        }

        items.append(
            .init(
                kind: .willCreate,
                status: .done,
                detail:
                    "iMCP creates one tunnel and one proxied address. Nothing else. Turning it off later deletes both."
            )
        )
        return items
    }

    /// Whether everything that the person has to provide is in place.
    static func isReady(_ items: [ChecklistItem]) -> Bool {
        items.filter { $0.kind != .willCreate }.allSatisfy(\.isDone)
    }
}
