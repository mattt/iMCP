import Foundation

/// The commands in the menu bar menu that run an action.
enum MenuAction: String, CaseIterable, Equatable {
    case configureClaudeDesktop
    case copyServerCommand
    case settings
    case checkForUpdates
    case about
    case quit

    var title: String {
        switch self {
        case .configureClaudeDesktop: "Configure Claude Desktop"
        case .copyServerCommand: "Copy server command to clipboard"
        case .settings: "Settings…"
        case .checkForUpdates: "Check for Updates…"
        case .about: "About iMCP"
        case .quit: "Quit iMCP"
        }
    }
}

/// A service as a checkable menu item.
struct MenuServiceItem: Equatable, Identifiable {
    let id: String
    let name: String
    let symbol: String
    let isOn: Bool
}

/// A group of menu items. The menu draws a separator between groups.
enum MenuSection: Equatable {
    /// The "Enable MCP Server" switch.
    case server(isOn: Bool)
    /// The services, under a "Services" header. Not shown while the server is off.
    case services(items: [MenuServiceItem])
    case actions([MenuAction])
}

/// What the menu bar menu contains, built from the app's state so that tests can check it.
///
/// This only decides which items appear, and in which groups; ``ContentView`` draws them.
enum MenuStructure {
    static func make(isServerEnabled: Bool, services: [MenuServiceItem]) -> [MenuSection] {
        var sections: [MenuSection] = [.server(isOn: isServerEnabled)]
        if isServerEnabled { sections.append(.services(items: services)) }
        return sections + [
            .actions([.configureClaudeDesktop, .copyServerCommand]),
            .actions([.settings, .checkForUpdates, .about]),
            .actions([.quit]),
        ]
    }
}
