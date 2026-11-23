import AppKit
import Foundation
import MCP
import OSLog

private let log = Logger.integration("claude-code")
private let configBookmarkKey = "me.mattt.iMCP.claudeCodeConfigBookmark"

/// Adds iMCP to Claude Code's user-scope MCP servers, the same entry
/// that `claude mcp add-json --scope user iMCP …` writes to `~/.claude.json`.
///
/// iMCP runs in the App Sandbox, where it can't launch `claude` or see its settings,
/// so it edits the file that the person lets it open.
enum ClaudeCode {
    /// The name that iMCP gives the credential it writes for Claude Code.
    static let clientName = "Claude Code"
    static let serverName = "iMCP"

    /// Whether the person has let iMCP edit Claude Code's settings file, which setup does.
    static var isConfigured: Bool {
        UserDefaults.standard.data(forKey: configBookmarkKey) != nil
    }

    enum Error: LocalizedError {
        case noFileSelected

        var errorDescription: String? {
            "No Claude Code settings file was selected."
        }
    }

    /// The entry for iMCP, with `credential` in its environment.
    static func serverEntry(credential: String) -> [String: Value] {
        let command = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/imcp-server").path
        return [
            "type": "stdio",
            "command": .string(command),
            "args": .array([]),
            "env": .object([ClientCredential.environmentVariable: .string(credential)]),
        ]
    }

    /// Writes iMCP into Claude Code's settings, with a credential for it.
    ///
    /// - Parameter trusted: Whether the credential connects without a dialog.
    ///   iMCP trusts it when the person just chose to trust Claude Code.
    @MainActor
    static func install(serverController: ServerController, trusted: Bool) throws {
        let url = try configURL()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        // Read and write back-to-back: Claude Code updates this file too.
        let current = try? Data(contentsOf: url)
        let existing = MCPClientConfig.environmentValue(
            ClientCredential.environmentVariable,
            server: serverName,
            in: current
        )
        let credential = try serverController.credentialForClientSettings(
            name: clientName,
            existing: existing,
            trusted: trusted
        )
        do {
            let updated = try MCPClientConfig.upserting(
                server: serverName,
                entry: serverEntry(credential: credential),
                into: current
            )
            try MCPClientConfig.writeAtomically(updated, to: url)
            log.notice("Added iMCP to Claude Code settings")
        } catch {
            if credential != existing { serverController.discardCredential(credential) }
            throw error
        }
    }

    /// The menu command: confirms, then writes the settings.
    @MainActor
    static func showConfigurationPanel(serverController: ServerController) {
        let alert = NSAlert()
        alert.messageText = "Set Up iMCP Server"
        alert.informativeText = """
            This adds iMCP to Claude Code's MCP servers in ~/.claude.json, \
            including a credential that identifies Claude Code to iMCP.

            Your existing server configurations won't be affected.
            """
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try install(serverController: serverController, trusted: false)
        } catch Error.noFileSelected {
            return
        } catch {
            let failure = NSAlert(error: error)
            failure.messageText = "Configuration Error"
            failure.runModal()
        }
    }

    /// The settings file, which the person opens once and iMCP remembers.
    @MainActor
    private static func configURL() throws -> URL {
        if let data = UserDefaults.standard.data(forKey: configBookmarkKey) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }

        let panel = NSOpenPanel()
        panel.message = "Choose .claude.json in your home folder so that iMCP can add itself to Claude Code."
        panel.prompt = "Choose"
        panel.directoryURL = FileManager.userHomeDirectoryURL
        panel.nameFieldStringValue = ".claude.json"
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { throw Error.noFileSelected }

        if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(bookmark, forKey: configBookmarkKey)
        }
        return url
    }
}
