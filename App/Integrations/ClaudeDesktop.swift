import AppKit
import Foundation
import MCP
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
            var env: [String: String]?
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
            let (config, imcpServer) = try loadConfig()

            let fileExists = FileManager.default.fileExists(atPath: configPath)

            let alert = NSAlert()
            alert.messageText = "Set Up iMCP Server"
            alert.informativeText = """
                This will \(fileExists ? "update" : "create") the iMCP server settings in Claude Desktop.

                Location: \(configPath)

                Your existing server configurations won't be affected.
                """

            alert.addButton(withTitle: "Set Up")
            alert.addButton(withTitle: "Cancel")

            NSApp.activate(ignoringOtherApps: true)

            let alertResponse = alert.runModal()
            if alertResponse == .alertFirstButtonReturn {
                log.debug("User clicked Save, updating configuration")
                try updateConfig(config, upserting: imcpServer)
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
        log.debug("Bookmark data is stale but URL was resolved: \(url.path). Attempting to use it.")
        // We will still return the URL and let the caller try to use it and refresh the bookmark.
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

private func loadConfig() throws -> ([String: Value], ClaudeDesktop.Config.MCPServer) {
    log.debug("Creating default iMCP server configuration")
    let imcpServer = ClaudeDesktop.Config.MCPServer(
        command: Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/imcp-server")
            .path)

    var loadedConfiguration: [String: Value]?

    // 1. Try to load using security-scoped URL
    if let secureURL = try? getSecurityScopedConfigURL() {
        log.debug("Attempting to load from security-scoped URL: \(secureURL.path)")
        if secureURL.startAccessingSecurityScopedResource() {
            defer { secureURL.stopAccessingSecurityScopedResource() }
            if FileManager.default.fileExists(atPath: secureURL.path) {
                do {
                    log.debug("Loading existing configuration from: \(secureURL.path)")
                    let data = try Data(contentsOf: secureURL)
                    loadedConfiguration = try jsonDecoder.decode([String: Value].self, from: data)
                    log.debug(
                        "Successfully loaded from security-scoped URL. Attempting to refresh bookmark."
                    )
                    try saveSecurityScopedAccess(for: secureURL)  // Refresh bookmark
                } catch {
                    log.error(
                        "Failed to load or decode from security-scoped URL \(secureURL.path): \(error.localizedDescription)"
                    )
                }
            } else {
                log.debug(
                    "Security-scoped URL \(secureURL.path) does not point to an existing file.")
            }
        } else {
            log.debug(
                "Failed to start accessing security-scoped resource for URL: \(secureURL.path)")
        }
    } else {
        log.debug("No security-scoped URL obtained or an error occurred retrieving it.")
    }

    // 2. If config is still nil (not loaded via security scope), try to load from default direct path
    if loadedConfiguration == nil {
        let defaultURL = URL(fileURLWithPath: configPath)
        log.debug("Attempting to load from default direct path: \(defaultURL.path)")
        if FileManager.default.fileExists(atPath: defaultURL.path) {
            do {
                let data = try Data(contentsOf: defaultURL)
                loadedConfiguration = try jsonDecoder.decode([String: Value].self, from: data)
                log.debug(
                    "Successfully loaded from default path. Attempting to save security bookmark for it."
                )
                try saveSecurityScopedAccess(for: defaultURL)  // Establish bookmark if loaded directly
            } catch {
                log.error(
                    "Failed to load or decode from default path \(defaultURL.path): \(error.localizedDescription)"
                )
            }
        } else {
            log.debug("Default config file \(defaultURL.path) does not exist.")
        }
    }

    // 3. Use loaded configuration or fall back to default if still nil
    let finalConfig =
        loadedConfiguration
        ?? {
            log.notice(
                "No existing config found or accessible after all attempts. Creating a new default configuration."
            )
            return ["mcpServers": .object([:])]
        }()

    return (finalConfig, imcpServer)
}

private func updateConfig(
    _ config: [String: Value],
    upserting imcpServer: ClaudeDesktop.Config.MCPServer
)
    throws
{
    // Update the iMCP server entry
    var updatedConfig = config
    let imcpServerValue = try Value(imcpServer)

    if var mcpServers = config["mcpServers"]?.objectValue {
        mcpServers["iMCP"] = imcpServerValue
        updatedConfig["mcpServers"] = .object(mcpServers)
    } else {
        updatedConfig["mcpServers"] = .object(["iMCP": imcpServerValue])
    }

    // First try with the security-scoped URL if available
    if let secureURL = try? getSecurityScopedConfigURL() {
        if secureURL.startAccessingSecurityScopedResource() {
            defer { secureURL.stopAccessingSecurityScopedResource() }
            do {
                try writeConfig(updatedConfig, to: secureURL)
                return
            } catch {
                log.error("Failed to write to security-scoped URL: \(error.localizedDescription)")
                // Continue to fallback options
            }
        } else {
            log.error("Failed to access security-scoped resource")
        }
    }

    // Then try to use the default path directly if it exists and is writable
    let defaultURL = URL(fileURLWithPath: configPath)
    if FileManager.default.fileExists(atPath: configPath) {
        do {
            // Test if we can write to this file
            if FileManager.default.isWritableFile(atPath: configPath) {
                try writeConfig(updatedConfig, to: defaultURL)

                // Since we succeeded with direct path, create a bookmark for future use
                try? saveSecurityScopedAccess(for: defaultURL)
                return
            }
        } catch {
            log.error("Failed to write to default config path: \(error.localizedDescription)")
            // Continue to show save panel
        }
    }

    // Finally, show save panel as a last resort
    log.debug("Showing save panel for new configuration location")
    let savePanel = NSSavePanel()
    savePanel.message = "Choose where to save the iMCP server settings."
    savePanel.prompt = "Set Up"
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
    do {
        try writeConfig(updatedConfig, to: selectedURL)

        // Then create the security-scoped bookmark
        log.debug("Creating security-scoped access for selected URL")
        try saveSecurityScopedAccess(for: selectedURL)
    } catch {
        log.error("Failed to write config to selected URL: \(error)")
        throw error
    }
}

private func writeConfig(_ config: [String: Value], to url: URL) throws {
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
