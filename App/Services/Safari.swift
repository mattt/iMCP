import AppKit
import Foundation
import MCP
import OSLog
import UniformTypeIdentifiers

private let log = Logger.service("safari")
private let exportBookmarkKey = "me.mattt.iMCP.safariBookmarksExportBookmark"

/// Runs the Reading List script in Safari.
///
/// The Safari service uses Safari through `NSAppleScript`;
/// tests use a stand-in that sends nothing.
protocol SafariScriptRunning: Sendable {
    /// Whether Safari is open. A script would start it otherwise, which iMCP never does.
    var isRunning: Bool { get }

    func run(calling subroutine: NSAppleScript.Subroutine) async throws
}

/// Runs the script in Safari, which asks the person to allow it the first time.
struct AppleSafariRunner: SafariScriptRunning {
    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: SafariScripts.bundleID).isEmpty
    }

    func run(calling subroutine: NSAppleScript.Subroutine) async throws {
        guard isRunning else { throw SafariError.notRunning }
        do {
            _ = try await NSAppleScript.execute(SafariScripts.source, calling: subroutine)
        } catch let error as NSAppleScript.ExecutionError {
            if error.number == Int(errAEEventNotPermitted) { throw SafariError.automationDenied }
            log.error("Safari script failed: \(error.message)")
            throw SafariError.scriptFailed(error.message)
        }
    }
}

/// Reads Safari's bookmarks from an export, and adds to Safari's Reading List.
///
/// Safari has no scripting or framework interface for bookmarks,
/// and iMCP's sandbox can't read the property list that Safari keeps them in,
/// so iMCP doesn't touch that file.
/// The one supported way to hand bookmarks to another program is Safari's File > Export > Bookmarks.
/// The person exports once and chooses the file when they turn the service on,
/// and the tools read that snapshot. It doesn't follow later changes in Safari until they export again.
/// Nothing can change or remove a bookmark, or move one between folders.
final class SafariService: NSObject, Service {
    static let shared = SafariService()

    /// Adding to the Reading List is new, so it starts off until the person turns on "Allow writes".
    var writesEnabledByDefault: Bool { false }

    /// Asks for the exported file when none is chosen yet.
    ///
    /// The Reading List tool needs no file, so a canceled or unreadable choice leaves the service on.
    func activate() async throws {
        guard !Task.isCancelled else { return }
        if (try? resolveExportURL()) != nil { return }
        guard let url = await showFilePicker() else { return }
        do {
            try Self.withAccess(url) { url in
                _ = try Self.snapshot(of: url)
                try storeBookmark(for: url)
            }
        } catch {
            log.error("The exported bookmarks file was not usable: \(error.localizedDescription)")
            await showAlert(
                title: "That file has no bookmarks",
                message:
                    "Choose the file that Safari writes with File > Export > Bookmarks. Adding to the Reading List still works."
            )
        }
    }

    var tools: [Tool] {
        // An explicit return keeps the protocol's result builder from rewriting the array.
        return [
            Tool(
                name: "safari_bookmarks_search",
                description:
                    "Search the Safari bookmarks that were exported from Safari with File > Export > Bookmarks. Results are in the file's order. The result says when the file was exported: bookmarks added in Safari since then aren't in it. Filters combine with AND. To get the next page, pass nextOffset as offset. Bookmarks can't be changed or removed through iMCP.",
                inputSchema: .object(
                    properties: [
                        "query": .string(
                            description:
                                "Words to look for in the bookmark's title, address, and folder. Every word must appear (case-insensitive)"
                        ),
                        "folder": .string(
                            description:
                                "Only bookmarks in this folder and its subfolders, written as Parent/Child, as safari_bookmark_folders lists them"
                        ),
                        "addedAfter": .string(
                            description:
                                "Only bookmarks added at or after this ISO 8601 date or date and time. Bookmarks that have no added date don't match. A date alone means midnight in the local time zone",
                            format: .dateTime
                        ),
                        "addedBefore": .string(
                            description:
                                "Only bookmarks added before this ISO 8601 date or date and time. Bookmarks that have no added date don't match",
                            format: .dateTime
                        ),
                        "limit": .integer(
                            description: "Maximum bookmarks to return",
                            default: .int(SafariBookmarkQuery.defaultLimit),
                            minimum: 1,
                            maximum: SafariBookmarkQuery.maximumLimit
                        ),
                        "offset": .integer(
                            description: "Number of matching bookmarks to skip",
                            default: .int(0),
                            minimum: 0
                        ),
                    ],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Search Safari Bookmarks",
                    readOnlyHint: true,
                    openWorldHint: false
                )
            ) { arguments in
                var query = SafariBookmarkQuery()
                query.text = try Self.string("query", in: arguments)
                query.folder = try Self.string("folder", in: arguments)
                query.addedAfter = try Self.date("addedAfter", in: arguments)
                query.addedBefore = try Self.date("addedBefore", in: arguments)
                if let limit = try Self.integer("limit", in: arguments) { query.limit = limit }
                if let offset = try Self.integer("offset", in: arguments) { query.offset = offset }
                query = try query.validated()

                let (snapshot, exportedAt, fileName) = try await self.loadSnapshot()
                let (page, total) = query.run(on: snapshot)
                let next = query.offset + page.count
                return [
                    "@context": "https://schema.org",
                    "@type": "ItemList",
                    "name": "Safari Bookmarks",
                    "export": Self.exportValue(fileName: fileName, exportedAt: exportedAt, snapshot: snapshot),
                    "numberOfItems": .int(total),
                    "nextOffset": next < total ? .int(next) : .null,
                    "itemListElement": .array(page.map(Self.value(of:))),
                ] as Value
            },

            Tool(
                name: "safari_bookmark_folders",
                description:
                    "List the bookmark folders in the exported Safari bookmarks file, as paths such as Favorites/News, with the number of bookmarks directly in each. Use a path as the folder of safari_bookmarks_search.",
                inputSchema: .object(
                    properties: [:],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "List Safari Bookmark Folders",
                    readOnlyHint: true,
                    openWorldHint: false
                )
            ) { _ in
                let (snapshot, exportedAt, fileName) = try await self.loadSnapshot()
                var counts: [String: Int] = [:]
                for bookmark in snapshot.bookmarks { counts[bookmark.folderPath, default: 0] += 1 }
                return [
                    "export": Self.exportValue(fileName: fileName, exportedAt: exportedAt, snapshot: snapshot),
                    "folders": .array(
                        snapshot.folderPaths.map { ["path": .string($0), "bookmarks": .int(counts[$0] ?? 0)] }
                    ),
                    "unfiledBookmarks": .int(counts[""] ?? 0),
                ] as Value
            },

            Tool(
                name: "safari_reading_list_add",
                description:
                    "Add a web page to Safari's Reading List. Only http and https addresses are accepted. Safari must be open, and iMCP doesn't start it. Allowed only while \"Allow writes\" is on in iMCP's Safari settings.",
                inputSchema: .object(
                    properties: [
                        "url": .string(
                            description:
                                "The page's address, starting with http:// or https://, up to \(SafariReadingListItem.maximumURLLength) characters"
                        ),
                        "title": .string(
                            description:
                                "A title for the item. Leave it out to let Safari use the page's title"
                        ),
                        "previewText": .string(
                            description:
                                "The text that the Reading List shows under the title, such as the article's first sentences"
                        ),
                    ],
                    required: ["url"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Add to Reading List",
                    readOnlyHint: false,
                    destructiveHint: false,
                    openWorldHint: false
                )
            ) { arguments in
                try await Self.addToReadingList(arguments, runner: AppleSafariRunner())
            },
        ]
    }

    /// Checks a request to add to the Reading List, then runs it.
    static func addToReadingList(_ arguments: [String: Value], runner: any SafariScriptRunning) async throws -> Value {
        guard let url = try string("url", in: arguments) else { throw SafariError.invalid("url is required") }
        let item = try SafariReadingListItem(
            url: url,
            title: try string("title", in: arguments),
            previewText: try string("previewText", in: arguments)
        )
        try await runner.run(calling: SafariScripts.addReadingListItem(item))
        return ["added": true, "url": .string(item.url)] as Value
    }

    // MARK: - Results

    private static func value(of bookmark: SafariBookmark) -> Value {
        var value: [String: Value] = [
            "@type": "WebPage",
            "name": .string(bookmark.title),
            "url": .string(bookmark.url),
        ]
        if !bookmark.folders.isEmpty { value["folder"] = .string(bookmark.folderPath) }
        if let added = bookmark.addedDate {
            value["dateCreated"] = .string(ISO8601DateFormatter().string(from: added))
        }
        return .object(value)
    }

    private static func exportValue(
        fileName: String,
        exportedAt: Date?,
        snapshot: SafariBookmarksSnapshot
    ) -> Value {
        [
            "file": .string(fileName),
            "exportedAt": exportedAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "bookmarks": .int(snapshot.bookmarks.count),
        ]
    }

    // MARK: - The exported file

    private func loadSnapshot() async throws -> (SafariBookmarksSnapshot, Date?, String) {
        let url = try resolveExportURL()
        return try await Task.detached {
            try Self.withAccess(url) { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                return (try Self.snapshot(of: url), values?.contentModificationDate, url.lastPathComponent)
            }
        }.value
    }

    /// Reads and parses a file, refusing one that is too big or holds no bookmarks.
    static func snapshot(of url: URL) throws -> SafariBookmarksSnapshot {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= SafariBookmarksFile.maximumBytes else {
                throw SafariError.exportUnreadable(
                    "it is larger than \(SafariBookmarksFile.maximumBytes / 1_000_000) MB"
                )
            }
            let snapshot = SafariBookmarksFile.parse(try Data(contentsOf: url))
            guard !snapshot.bookmarks.isEmpty else {
                throw SafariError.exportUnreadable("it holds no bookmarks")
            }
            return snapshot
        } catch let error as SafariError {
            throw error
        } catch {
            throw SafariError.exportUnreadable(error.localizedDescription)
        }
    }

    private func resolveExportURL() throws -> URL {
        guard let data = UserDefaults.standard.data(forKey: exportBookmarkKey) else { throw SafariError.noExport }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale { try? Self.withAccess(url) { try storeBookmark(for: $0) } }
            return url
        } catch {
            throw SafariError.exportUnreadable("iMCP can no longer open the file that was chosen")
        }
    }

    private func storeBookmark(for url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: exportBookmarkKey)
    }

    private static func withAccess<T>(_ url: URL, _ operation: (URL) throws -> T) rethrows -> T {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        return try operation(url)
    }

    // MARK: - UI

    @MainActor
    private func showFilePicker() -> URL? {
        let panel = NSOpenPanel()
        panel.message =
            "Choose the file that Safari wrote with File > Export > Bookmarks. Without it, only adding to the Reading List works."
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - Arguments

    private static func string(_ name: String, in arguments: [String: Value]) throws -> String? {
        guard let value = arguments[name], !value.isNull else { return nil }
        guard let string = value.stringValue else { throw SafariError.invalid("\(name) must be a string") }
        return string
    }

    private static func integer(_ name: String, in arguments: [String: Value]) throws -> Int? {
        guard let value = arguments[name], !value.isNull else { return nil }
        guard let integer = value.intValue else { throw SafariError.invalid("\(name) must be an integer") }
        return integer
    }

    private static func date(_ name: String, in arguments: [String: Value]) throws -> Date? {
        guard let text = try string(name, in: arguments) else { return nil }
        guard let date = SafariDates.parse(text) else {
            throw SafariError.invalid("\(name) must be an ISO 8601 date")
        }
        return date
    }
}
