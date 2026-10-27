import AppKit
import Foundation
import OSLog

private let log = Logger.integration("chatgpt")
private let defaultConfigURL = FileManager.userHomeDirectoryURL
    .appendingPathComponent(".codex/config.toml")

/// One-click setup for the ChatGPT desktop app, through the file that it reads.
///
/// OpenAI documents that the desktop app, the CLI, and the IDE extension share
/// `~/.codex/config.toml`, where each MCP server is a `[mcp_servers.<name>]` table
/// with a `command`. This writes the iMCP entry in that format, like the
/// Claude Desktop integration writes its JSON file. The app's own
/// `codex` URL scheme has no documented add-server form, so no deep link is used.
///
/// iMCP is sandboxed, so the person picks the file in a save panel,
/// which grants access to it. An existing file is read back after the pick
/// and merged, so the panel's overwrite prompt does not lose its contents.
enum ChatGPT {
    enum Error: LocalizedError {
        case noLocationSelected

        var errorDescription: String? {
            switch self {
            case .noLocationSelected: "No location selected to save config"
            }
        }
    }

    static func showConfigurationPanel() {
        let alert = NSAlert()
        alert.messageText = "Set Up iMCP in ChatGPT"
        alert.informativeText = """
            This will add the iMCP server to the configuration file that ChatGPT reads.

            Location: \(defaultConfigURL.path)

            Your existing server configurations won't be affected. Then restart ChatGPT so that it starts iMCP.
            """
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            log.debug("User cancelled ChatGPT configuration")
            return
        }

        do {
            try chooseAndWriteConfig()
            log.notice("ChatGPT configuration updated successfully")
        } catch {
            log.error("Error configuring ChatGPT: \(error.localizedDescription)")
            let errorAlert = NSAlert()
            errorAlert.messageText = "Configuration Error"
            errorAlert.informativeText = error.localizedDescription
            errorAlert.alertStyle = .critical
            errorAlert.runModal()
        }
    }

    private static func chooseAndWriteConfig() throws {
        let savePanel = NSSavePanel()
        savePanel.message = "Choose the configuration file that ChatGPT reads."
        savePanel.prompt = "Set Up"
        savePanel.directoryURL = defaultConfigURL.deletingLastPathComponent()
        savePanel.nameFieldStringValue = defaultConfigURL.lastPathComponent
        savePanel.canCreateDirectories = true
        savePanel.showsHiddenFiles = true

        guard savePanel.runModal() == .OK, let selectedURL = savePanel.url else {
            throw Error.noLocationSelected
        }

        // The panel grants access to the selected file, so read any existing
        // contents from it and merge, rather than replacing the file.
        let existing = (try? String(contentsOf: selectedURL, encoding: .utf8)) ?? ""
        let updated = mergedConfig(existing, command: ServerCommand.path)
        try updated.write(to: selectedURL, atomically: true, encoding: .utf8)
    }

    /// Returns `toml` with an `[mcp_servers.iMCP]` table that starts `command`.
    ///
    /// An existing iMCP table keeps its other keys and gets a new command.
    /// Every other line stays as it was.
    static func mergedConfig(_ toml: String, command: String) -> String {
        let tableHeader = "[mcp_servers.iMCP]"
        var lines = toml.components(separatedBy: "\n")
        // A trailing newline makes a final empty element. Drop it and add one back at the end.
        if lines.last == "" { lines.removeLast() }

        guard let headerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == tableHeader })
        else {
            if !lines.isEmpty { lines.append("") }
            lines.append(tableHeader)
            lines.append("command = \"\(command)\"")
            return lines.joined(separator: "\n") + "\n"
        }

        // The table runs until the next table header.
        let tableEnd =
            lines[(headerIndex + 1)...]
            .firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
            ?? lines.endIndex
        if let commandIndex = lines[(headerIndex + 1) ..< tableEnd]
            .firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("command") })
        {
            lines[commandIndex] = "command = \"\(command)\""
        } else {
            lines.insert("command = \"\(command)\"", at: headerIndex + 1)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
