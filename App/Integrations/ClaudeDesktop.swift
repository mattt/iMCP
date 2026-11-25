import AppKit
import Foundation
import OSLog

private let log = Logger.integration("claude-desktop")
private let configPath = FileManager.userHomeDirectoryURL
    .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json").path
private let configBookmarkKey = "me.mattt.iMCP.claudeConfigBookmark"

enum ClaudeDesktop {
    enum Error: LocalizedError {
        case noLocationSelected

        var errorDescription: String? {
            switch self {
            case .noLocationSelected:
                return "No location selected to save config"
            }
        }
    }

    /// The name that iMCP gives the credential it writes for Claude Desktop.
    static let clientName = "Claude Desktop"

    @MainActor
    static func showConfigurationPanel(serverController: ServerController) {
        do {
            let bookmarkedURL = try? getSecurityScopedConfigURL()
            let configURL = bookmarkedURL ?? URL(fileURLWithPath: configPath)
            let alert = NSAlert()
            alert.messageText = "Set Up iMCP Server"
            alert.informativeText = """
                This will set up the iMCP server in Claude Desktop, \
                including a credential that identifies Claude Desktop to iMCP.

                Location: \(configURL.path)

                Your existing server configurations won't be affected.
                """

            alert.addButton(withTitle: "Set Up")
            alert.addButton(withTitle: "Cancel")

            NSApp.activate(ignoringOtherApps: true)

            let alertResponse = alert.runModal()
            if alertResponse == .alertFirstButtonReturn {
                log.debug("User clicked Save, updating configuration")

                try updateConfig(at: configURL, hasBookmark: bookmarkedURL != nil) { url in
                    try ClaudeDesktopSettings.update(
                        at: url,
                        command: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/imcp-server").path,
                        credentialForSettings: { existing in
                            try serverController.credentialForClientSettings(name: clientName, existing: existing)
                        },
                        discardCredential: serverController.discardCredential
                    )
                }
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
        bookmarkDataIsStale: &isStale
    )

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

@MainActor
private func updateConfig(at url: URL, hasBookmark: Bool, write: (URL) throws -> Void) throws {
    let accessing = hasBookmark && url.startAccessingSecurityScopedResource()
    defer {
        if accessing { url.stopAccessingSecurityScopedResource() }
    }

    func save(to destination: URL) throws {
        try write(destination)
        do {
            try saveSecurityScopedAccess(for: destination)
        } catch {
            log.error("Saved configuration but could not save its bookmark: \(error.localizedDescription)")
        }
    }

    if accessing || FileManager.default.isWritableFile(atPath: url.path) {
        do {
            try save(to: url)
            return
        } catch let error as CocoaError
            where error.code == .fileWriteNoPermission || error.code == .fileReadNoPermission
        {
            log.debug("Requesting permission to access the configuration")
        }
    }

    let savePanel = NSSavePanel()
    savePanel.message = "Choose where to save the iMCP server settings."
    savePanel.prompt = "Set Up"
    savePanel.allowedContentTypes = [.json]
    savePanel.directoryURL = url.deletingLastPathComponent()
    savePanel.nameFieldStringValue = url.lastPathComponent
    savePanel.canCreateDirectories = true
    savePanel.showsHiddenFiles = false

    guard savePanel.runModal() == .OK, let selectedURL = savePanel.url else {
        log.error("No location selected to save configuration")
        throw ClaudeDesktop.Error.noLocationSelected
    }

    try save(to: selectedURL)
}
