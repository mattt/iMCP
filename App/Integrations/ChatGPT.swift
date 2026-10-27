import AppKit
import Foundation
import OSLog

private let log = Logger.integration("chatgpt")
private let codexDirectoryURL = FileManager.userHomeDirectoryURL.appendingPathComponent(".codex")
private let defaultConfigURL = codexDirectoryURL.appendingPathComponent("config.toml")

/// One-click setup for the ChatGPT desktop app, through the file that it reads.
///
/// OpenAI documents that the desktop app, the CLI, and the IDE extension share
/// `~/.codex/config.toml`, where each MCP server is a `[mcp_servers.<name>]` table
/// with a `command`. The app's own `codex` URL scheme has no documented
/// add-server form, so no deep link is used.
///
/// The edit itself is in `ChatGPTConfig`: parse with swift-toml, edit the text
/// as little as possible, and parse the result again before writing.
/// swift-toml encodes and decodes Codable values, but it has no
/// format-preserving document, so re-serializing the file would lose its
/// comments and formatting. The text edit keeps them.
///
/// iMCP is sandboxed, so the person picks the file in a panel that opens in
/// `~/.codex`, which grants access to it. Before writing, the original is
/// copied to `config.toml.imcp-backup` next to it, and the new contents go in
/// with an atomic write. When the backup cannot be written under the file's
/// grant, the person picks the `.codex` folder, which grants the folder.
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

            Your existing server configurations won't be affected. iMCP keeps a copy of the file as config.toml.imcp-backup first. Then restart ChatGPT so that it starts iMCP.
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
            errorAlert.alertStyle = .critical
            if error is ChatGPTConfig.ConfigError {
                // Point to ChatGPT's own settings, with the command ready to paste.
                errorAlert.informativeText =
                    "\(error.localizedDescription)\n\nServer command:\n\(ServerCommand.path)"
                errorAlert.addButton(withTitle: "Copy Server Command")
                errorAlert.addButton(withTitle: "OK")
                if errorAlert.runModal() == .alertFirstButtonReturn {
                    ServerCommand.copy()
                }
            } else {
                errorAlert.informativeText = error.localizedDescription
                errorAlert.runModal()
            }
        }
    }

    private static func chooseAndWriteConfig() throws {
        let selectedURL = try pickConfigFile()
        let existing = (try? String(contentsOf: selectedURL, encoding: .utf8)) ?? ""
        let updated = try ChatGPTConfig.updatedConfig(original: existing, command: ServerCommand.path)

        // Keep the original next to the file before replacing it.
        do {
            try writeBackup(of: selectedURL, original: existing)
        } catch {
            // A file grant may not cover a new file next to it. Ask for the folder, then retry.
            log.debug("Backup under the file grant failed: \(error.localizedDescription)")
            guard let folderURL = pickCodexFolder() else { throw Error.noLocationSelected }
            let scoped = folderURL.startAccessingSecurityScopedResource()
            defer { if scoped { folderURL.stopAccessingSecurityScopedResource() } }
            try writeBackup(of: selectedURL, original: existing)
        }

        try updated.write(to: selectedURL, atomically: true, encoding: .utf8)
    }

    private static func writeBackup(of selectedURL: URL, original: String) throws {
        let backup = selectedURL.deletingLastPathComponent()
            .appendingPathComponent("config.toml.imcp-backup")
        try original.write(to: backup, atomically: true, encoding: .utf8)
    }

    /// Opens the open panel in `~/.codex`, or a save panel there when no file exists yet.
    private static func pickConfigFile() throws -> URL {
        NSApp.activate(ignoringOtherApps: true)
        if FileManager.default.fileExists(atPath: defaultConfigURL.path) {
            let panel = NSOpenPanel()
            panel.message = "Choose the configuration file that ChatGPT reads."
            panel.prompt = "Set Up"
            panel.directoryURL = codexDirectoryURL
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.showsHiddenFiles = true
            // The panel opens in ~/.codex. It cannot preselect a file by name,
            // so its message and the alert name config.toml instead.
            guard panel.runModal() == .OK, let url = panel.url else {
                throw Error.noLocationSelected
            }
            return url
        }

        let panel = NSSavePanel()
        panel.message = "Choose where to create the configuration file that ChatGPT reads."
        panel.prompt = "Set Up"
        panel.directoryURL = codexDirectoryURL
        panel.nameFieldStringValue = defaultConfigURL.lastPathComponent
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else {
            throw Error.noLocationSelected
        }
        return url
    }

    /// Asks for the `.codex` folder, for the backup write that a file grant may not cover.
    private static func pickCodexFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Choose the .codex folder, so that iMCP can keep a backup of config.toml next to it."
        panel.prompt = "Choose Folder"
        panel.directoryURL = FileManager.userHomeDirectoryURL
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
