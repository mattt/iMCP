import Foundation

// Where each setting lives, and which AI apps iMCP knows by name.
// Foundation-only, so the placement is unit tested without AppKit.

/// A pane in Settings, stored as its raw value so that Settings can reopen to it.
/// The four tabs sit above the Services section of the sidebar, which has a pane for each service.
enum SettingsPane: Hashable, RawRepresentable, Sendable {
    case general
    case clients
    case mobile
    case remoteAccess
    case advanced
    /// The pane for the service with this `ServiceConfig.id`.
    case service(String)

    /// The tabs, in the order the sidebar lists them.
    static let tabs: [SettingsPane] = [.general, .clients, .mobile, .remoteAccess, .advanced]

    init(rawValue: String) {
        switch rawValue {
        case "general": self = .general
        case "clients": self = .clients
        case "mobile": self = .mobile
        case "remoteAccess": self = .remoteAccess
        case "advanced": self = .advanced
        default: self = .service(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .general: "general"
        case .clients: "clients"
        case .mobile: "mobile"
        case .remoteAccess: "remoteAccess"
        case .advanced: "advanced"
        case .service(let id): id
        }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .clients: "Clients"
        case .mobile: "iPhone & iPad"
        case .remoteAccess: "Remote Access"
        case .advanced: "Advanced"
        case .service(let id): id
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .clients: "app.connected.to.app.below.fill"
        case .mobile: "ipad.and.iphone"
        case .remoteAccess: "network"
        case .advanced: "wrench.and.screwdriver"
        case .service: "square.grid.2x2"
        }
    }
}

/// Every control in the five tabs and the tab it lives in.
/// The list guards against a setting vanishing when a tab is rearranged.
/// The per-service panes are not listed: they are unchanged.
enum SettingsItem: CaseIterable, Sendable {
    // General
    case serverSwitch, menuBarIcon, launchAtLogin, approvalMode, setupAssistant, checkForUpdates
    // Clients
    case claudeDesktopSetup, claudeCodeSetup, connectorAddress, cloudClients, clientInstructions
    case trustedApps, approveAgainList, connectedCloudApps
    // iPhone & iPad
    case pairedDevices, pairDevice, unpairDevice, routeList, connectVia, approveOnIPhone, activityHistory
    // Remote Access
    case accessChoice, tailscaleChecklist, cloudflareChecklist, publicAddress, funnelPolicySnippet
    case tailscaleLogOut, cloudflareAccount
    // Advanced
    case serverCommand, accessTokens, tailscaleDeviceName, tailscalePort, tailscaleAddresses, tailscaleAuthKey
    case mobileOverrides, mobileDetails, cachedData

    var tab: SettingsPane {
        switch self {
        case .serverSwitch, .menuBarIcon, .launchAtLogin, .approvalMode, .setupAssistant, .checkForUpdates:
            .general
        case .claudeDesktopSetup, .claudeCodeSetup, .connectorAddress, .cloudClients, .clientInstructions,
            .trustedApps, .approveAgainList, .connectedCloudApps:
            .clients
        case .pairedDevices, .pairDevice, .unpairDevice, .routeList, .connectVia, .approveOnIPhone,
            .activityHistory:
            .mobile
        case .accessChoice, .tailscaleChecklist, .cloudflareChecklist, .publicAddress, .funnelPolicySnippet,
            .tailscaleLogOut, .cloudflareAccount:
            .remoteAccess
        case .serverCommand, .accessTokens, .tailscaleDeviceName, .tailscalePort, .tailscaleAddresses,
            .tailscaleAuthKey, .mobileOverrides, .mobileDetails, .cachedData:
            .advanced
        }
    }

    static func items(in tab: SettingsPane) -> [SettingsItem] {
        allCases.filter { $0.tab == tab }
    }
}

extension ApprovalMode {
    /// One short line for the chosen mode, shown under the picker.
    var settingsCaption: String {
        switch self {
        case .askEverything: "Every request asks first."
        case .askWritesOnly: "Changes ask first. Reading is automatic."
        case .agentManaged: "Your AI app asks. iMCP allows everything."
        case .allowEverything: "Nothing asks. Use with care."
        }
    }
}

extension MobileRouteKind {
    var settingsSymbol: String {
        switch self {
        case .local: "house"
        case .cloudflare: "cloud"
        case .tailscaleVPN: "lock.shield"
        case .tailscaleFunnel: "network"
        }
    }

    /// The name people know the route by.
    var settingsName: String {
        switch self {
        case .local: "Your network"
        case .cloudflare: "Cloudflare Tunnel"
        case .tailscaleVPN: "Tailscale"
        case .tailscaleFunnel: "Tailscale public address"
        }
    }
}
