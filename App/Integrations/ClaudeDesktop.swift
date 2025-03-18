import AppKit
import Foundation
import OSLog

private let log = Logger.integration("claude-desktop")
private let configPath =
    "/Users/\(NSUserName())/Library/Application Support/Claude/claude_desktop_config.json"
private let configBookmarkKey = "com.loopwork.iMCP.claudeConfigBookmark"

private let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

private let jsonDecoder = JSONDecoder()

enum ClaudeDesktop {
    struct Config: Codable {
        struct MCPServer: Codable {
            var command: String
            var args: [String]?
        }

        var mcpServers: [String: MCPServer]
    }

    enum Error: LocalizedError {
        case noLocationSelected

        var errorDescription: String? {
            switch self {
            case .noLocationSelected:
                return "No location selected to save config"
            }
        }
    }

    static func showConfigurationPanel() {
        do {
            log.debug("Loading existing Claude Desktop configuration")
            let config = try loadConfig()

            let fileExists = FileManager.default.fileExists(atPath: configPath)

            let alert = NSAlert()
            alert.messageText = "Configure Claude Desktop"
            alert.informativeText = """
                The iMCP server will be configured in Claude Desktop.
                This will \(fileExists ? "update" : "create") the MCP server configuration to use the iMCP executable from this application.

                The configuration will be saved to: \(configPath)

                Other MCP server configurations in the file will be preserved.
                """

            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")

            NSApp.activate(ignoringOtherApps: true)

            let alertResponse = alert.runModal()
            if alertResponse == .alertFirstButtonReturn {
                log.debug("User clicked Save, updating configuration")
                try saveConfig(config)
                log.notice("Configuration updated successfully")
            } else {
                log.debug("User cancelled configuration update")
            }
        } catch {
            log.error("Error configuring Claude Desktop: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Configuration Error"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
        }
    }
}

private func getSecurityScopedConfigURL() throws -> URL? {
    log.debug("Attempting to get security-scoped config URL")
    guard let bookmarkData = UserDefaults.standard.data(forKey: configBookmarkKey) else {
        log.debug("No bookmark data found in UserDefaults")
        return nil
    }

    var isStale = false
    let url = try URL(
        resolvingBookmarkData: bookmarkData,
        options: .withSecurityScope,
        relativeTo: nil,
        bookmarkDataIsStale: &isStale)

    if isStale {
        log.debug("Bookmark data is stale")
        return nil
    }

    log.debug("Successfully retrieved security-scoped URL: \(url.path)")
    return url
}

private func saveSecurityScopedAccess(for url: URL) throws {
    log.debug("Creating security-scoped bookmark for URL: \(url.path)")
    let bookmarkData = try url.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    )
    UserDefaults.standard.set(bookmarkData, forKey: configBookmarkKey)
    log.debug("Successfully saved security-scoped bookmark")
}

private func loadConfig() throws -> ClaudeDesktop.Config {
    log.debug("Creating default iMCP server configuration")
    let imcpServer = ClaudeDesktop.Config.MCPServer(
        command: Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/imcp-server")
            .path)

    var config = ClaudeDesktop.Config(mcpServers: ["iMCP": imcpServer])

    // Try to load existing config if it exists
    if let secureURL = try? getSecurityScopedConfigURL(),
        secureURL.startAccessingSecurityScopedResource(),
        FileManager.default.fileExists(atPath: secureURL.path)
    {
        defer { secureURL.stopAccessingSecurityScopedResource() }

        log.debug("Loading existing configuration from: \(secureURL.path)")
        let data = try Data(contentsOf: secureURL)
        config = try jsonDecoder.decode(ClaudeDesktop.Config.self, from: data)
        config.mcpServers["iMCP"] = imcpServer
    } else {
        log.debug("No existing config found or accessible, will create a new one")
    }

    return config
}

private func saveConfig(_ config: ClaudeDesktop.Config) throws {
    // If we have an existing security-scoped URL, try to use it
    if let secureURL = try? getSecurityScopedConfigURL() {
        if secureURL.startAccessingSecurityScopedResource() {
            defer { secureURL.stopAccessingSecurityScopedResource() }
            try writeConfig(config, to: secureURL)
            return
        }
    }

    // Show save panel for new location
    log.debug("Showing save panel for new configuration location")
    let savePanel = NSSavePanel()
    savePanel.message = "Select location to save Claude Desktop configuration"
    savePanel.prompt = "Save"
    savePanel.allowedContentTypes = [.json]
    savePanel.directoryURL = URL(fileURLWithPath: configPath).deletingLastPathComponent()
    savePanel.nameFieldStringValue = "claude_desktop_config.json"
    savePanel.canCreateDirectories = true
    savePanel.showsHiddenFiles = false

    guard savePanel.runModal() == .OK, let selectedURL = savePanel.url else {
        log.error("No location selected to save configuration")
        throw ClaudeDesktop.Error.noLocationSelected
    }

    // Create the file first
    log.debug("Creating configuration at selected URL: \(selectedURL.path)")
    try writeConfig(config, to: selectedURL)

    // Then create the security-scoped bookmark
    log.debug("Creating security-scoped access for selected URL")
    try saveSecurityScopedAccess(for: selectedURL)
}

private func writeConfig(_ config: ClaudeDesktop.Config, to url: URL) throws {
    log.debug("Creating directory if needed: \(url.deletingLastPathComponent().path)")
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
    )

    log.debug("Encoding and writing configuration")
    let data = try jsonEncoder.encode(config)
    try data.write(to: url, options: .atomic)
    log.notice("Successfully saved config to \(url.path)")
}
