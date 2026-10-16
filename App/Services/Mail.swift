import AppKit
import Foundation
import Emlx
import Mail
import OSLog

private let log = Logger.service("mail")
private let mailDirectoryURL = URL(
    fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? "/Users/\(NSUserName())"
).appendingPathComponent("Library/Mail")
private let mailDirectoryBookmarkKey = "me.mattt.iMCP.mailDirectoryBookmark"
private let defaultLimit = 30
private let maximumLimit = 100

final class MailService: NSObject, Service, NSOpenSavePanelDelegate, Sendable {
    static let shared = MailService()

    /// The store runs one operation at a time, so concurrent reads wait their turn.
    /// The default configuration is valid, so the initializer does not throw.
    private let store = try! Mail.Store(root: mailDirectoryURL)

    var isActivated: Bool {
        get async {
            let isActivated = await canAccessDatabase
            log.debug("Mail service activation status: \(isActivated)")
            return isActivated
        }
    }

    /// Asks for the Mail folder when the index is not readable yet.
    ///
    /// Activation reports failures in an alert and never throws.
    /// `mail_compose` needs no folder access,
    /// so a canceled or denied grant must leave the service on.
    func activate() async throws {
        guard !Task.isCancelled else { return }
        if await canAccessDatabase {
            log.debug("Using the Mail index with the current grant")
            return
        }

        log.debug("Opening folder picker for the Mail folder")
        guard let selectedURL = await showFolderPicker() else { return }
        guard !Task.isCancelled else { return }

        do {
            try await withSecurityScopedAccess(selectedURL) { url in
                try await store.checkAccess()
                try Task.checkCancellation()
                try storeBookmark(for: url)
            }
            log.debug("Granted access to the Mail folder")
        } catch is CancellationError {
            return
        } catch {
            log.error("Mail folder access failed: \(error.localizedDescription)")
            await showAlert(
                title: "Mail reading is unavailable",
                message: MailToolError(underlying: error).localizedDescription + " Composition is still available."
            )
        }
    }

    var tools: [Tool] {
        Tool(
            name: "mail_mailboxes_list",
            description:
                "List mailboxes in the local Mail index. Use each @id as the mailbox search filter. Account email is included when available. Requires folder access.",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Mailboxes",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let mailboxes = try await self.withStore { store in try await store.mailboxes() }

            log.debug("Successfully listed \(mailboxes.count) mailboxes")
            return [
                "@context": "https://schema.org",
                "@type": "ItemList",
                "itemListElement": Value.array(mailboxes.map(\.value)),
            ]
        }

        Tool(
            name: "mail_messages_search",
            description:
                "Search local sender and subject metadata. Filters combine with AND; newest first. To get the next page, pass nextCursor as cursor with the same filters. Does not search bodies or download messages. Sync status is unknown; empty results do not prove the server mailbox is empty.",
            inputSchema: .object(
                properties: [
                    "sender": .string(
                        description: "Sender address substring"
                    ),
                    "subject": .string(
                        description: "Subject substring"
                    ),
                    "mailbox": .string(
                        description:
                            "The numeric @id string from mail_mailboxes_list, for example \"12\". Do not use the url field."
                    ),
                    "start": .string(
                        description:
                            "Start of the date range (inclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End of the date range (exclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "isRead": .boolean(
                        description: "If true, fetch read messages; if false, unread; if omitted, fetch all"
                    ),
                    "limit": .integer(
                        description: "Maximum messages to return",
                        default: .int(defaultLimit),
                        minimum: 1,
                        maximum: maximumLimit
                    ),
                    "cursor": .string(
                        description: "The nextCursor value from a previous search with the same filters"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Mail",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            log.debug("Starting mail search with arguments: \(arguments)")

            var request = Mail.Message.FetchRequest()
            request.sender = try self.argument("sender", in: arguments, as: \.stringValue)
            request.subject = try self.argument("subject", in: arguments, as: \.stringValue)
            if let mailbox = arguments["mailbox"], !mailbox.isNull {
                request.mailboxID = try self.mailboxID(from: mailbox)
            }
            if let start = try self.argument("start", in: arguments, as: \.stringValue) {
                guard let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: start) else {
                    throw MailError.invalidArgument("start must be an ISO 8601 date")
                }
                request.startDate = Calendar.current.normalizedStartDate(
                    from: parsed.date,
                    isDateOnly: parsed.isDateOnly
                )
            }
            if let end = try self.argument("end", in: arguments, as: \.stringValue) {
                guard let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: end) else {
                    throw MailError.invalidArgument("end must be an ISO 8601 date")
                }
                request.endDate = Calendar.current.normalizedEndDate(
                    from: parsed.date,
                    isDateOnly: parsed.isDateOnly
                )
            }
            request.isRead = try self.argument("isRead", in: arguments, as: \.boolValue)
            request.limit = try self.argument("limit", in: arguments, as: \.intValue) ?? defaultLimit
            if let cursor = try self.argument("cursor", in: arguments, as: \.stringValue) {
                guard let parsed = Mail.Message.FetchRequest.Cursor(cursor) else {
                    throw MailError.invalidArgument("cursor must be a nextCursor value from mail_messages_search")
                }
                request.cursor = parsed
            }

            let fetchRequest = request
            return try await self.withStore { store in try await store.search(fetchRequest).value }
        }

        Tool(
            name: "mail_messages_read",
            description:
                "Read local MIME content by a returned message identifier. HTML is returned as labeled data; remote content is never loaded.",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Message identifier from mail_messages_search"
                    )
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read Mail",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let id = try self.argument("id", in: arguments, as: \.stringValue),
                let identifier = Mail.Message.Identifier(id)
            else {
                throw MailError.invalidArgument("id must be an identifier from mail_messages_search")
            }

            // The store closes its database connection before it reads the message file.
            let content = try await self.withStore { store in
                try await store.readMessage(identifier) { file in
                    try Emlx.Content(emlx: file.data, expectedMessageID: file.message.messageID)
                }
            }
            return content.value(for: identifier)
        }

        Tool(
            name: "mail_compose",
            description: "Open a compose URL in the default email app. Does not save or send a message.",
            inputSchema: .object(
                properties: [
                    "to": .string(
                        description: "Comma-separated recipient addresses"
                    ),
                    "cc": .string(
                        description: "Comma-separated CC addresses"
                    ),
                    "bcc": .string(
                        description: "Comma-separated BCC addresses"
                    ),
                    "subject": .string(),
                    "body": .string(
                        description: "Plain-text body"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Compose Mail",
                readOnlyHint: false,
                destructiveHint: false,
                openWorldHint: true
            )
        ) { arguments in
            let composition = MailComposition(
                to: try self.argument("to", in: arguments, as: \.stringValue),
                cc: try self.argument("cc", in: arguments, as: \.stringValue),
                bcc: try self.argument("bcc", in: arguments, as: \.stringValue),
                subject: try self.argument("subject", in: arguments, as: \.stringValue),
                body: try self.argument("body", in: arguments, as: \.stringValue)
            )

            log.debug("Opening a compose URL in the default email app")
            try composition.open(using: NSWorkspace.shared.open)

            return [
                "@context": "https://schema.org",
                "@type": "CommunicateAction",
                "description": "Opened the compose URL in the default email app. No message was saved or sent by iMCP.",
            ]
        }
    }

    /// Returns an optional argument, or throws if it is present with the wrong type.
    private func argument<T>(
        _ name: String,
        in arguments: [String: Value],
        as transform: (Value) -> T?
    ) throws -> T? {
        guard let value = arguments[name], !value.isNull else { return nil }
        guard let result = transform(value) else {
            throw MailError.invalidArgument("\(name) has the wrong type")
        }
        return result
    }

    /// Returns the mailbox row identifier from a `mail_mailboxes_list` `@id` string.
    func mailboxID(from value: Value) throws -> Int64 {
        guard let string = value.stringValue, let id = Int64(string), id > 0 else {
            throw MailError.invalidArgument(
                "mailbox must be a positive numeric @id string from mail_mailboxes_list, for example \"12\"; do not use the url field."
            )
        }
        return id
    }

    // MARK: - Database Access

    private var canAccessDatabase: Bool {
        get async {
            // Status checks must not join Mail's SQLite locking protocol.
            // Schema and journal checks belong to explicit read requests.
            do {
                let root = try resolveBookmarkURL() ?? mailDirectoryURL
                return try await withSecurityScopedAccess(root) { _ in
                    let location = try await store.location()
                    return FileManager.default.isReadableFile(atPath: location.indexURL.path)
                }
            } catch {
                return false
            }
        }
    }

    /// Runs an operation on the store inside the grant for the bookmarked folder,
    /// or at the default path when nothing is bookmarked.
    private func withStore<T>(_ operation: (Mail.Store) async throws -> T) async throws -> T {
        do {
            let root = try resolveBookmarkURL() ?? mailDirectoryURL

            // Each store call finishes its database and file work before it returns,
            // so the grant must stay open until the operation returns.
            return try await withSecurityScopedAccess(root) { _ in
                try await operation(store)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MailToolError(underlying: error)
        }
    }

    /// Returns the bookmarked Mail folder, or nil when no bookmark is stored.
    private func resolveBookmarkURL() throws -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: mailDirectoryBookmarkKey) else {
            return nil
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                log.debug("Renewing the stale Mail folder bookmark")
                try withSecurityScopedAccess(url, storeBookmark)
            }
            return url
        } catch {
            log.error("Failed to resolve the Mail folder bookmark: \(error.localizedDescription)")
            throw MailError.accessExpired
        }
    }

    /// Runs an operation inside the security scope of a URL.
    /// URLs without a scope, such as the default path, run the operation as they are.
    private func withSecurityScopedAccess<T>(_ url: URL, _ operation: (URL) throws -> T) rethrows -> T {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        return try operation(url)
    }

    private func withSecurityScopedAccess<T>(
        _ url: URL,
        _ operation: (URL) async throws -> T
    ) async rethrows -> T {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        return try await operation(url)
    }

    private func storeBookmark(for url: URL) throws {
        let bookmarkData = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmarkData, forKey: mailDirectoryBookmarkKey)
        log.debug("Successfully created and stored bookmark")
    }

    // MARK: - UI

    /// Returns the selected Mail folder, or nil when the user dismisses the panel.
    @MainActor
    private func showFolderPicker() -> URL? {
        let openPanel = NSOpenPanel()
        openPanel.delegate = self
        openPanel.message =
            "Select ~/Library/Mail to read local mail. If access is canceled or denied, composition stays available."
        openPanel.prompt = "Grant Access"
        openPanel.directoryURL = mailDirectoryURL.deletingLastPathComponent()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.showsHiddenFiles = true

        guard openPanel.runModal() == .OK, let url = openPanel.url else {
            return nil
        }
        guard isMailDirectory(url) else {
            showAlert(
                title: "Select ~/Library/Mail to enable reading",
                message: "Other folders and exported mail are unsupported. Composition remains available."
            )
            return nil
        }

        return url
    }

    @MainActor
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func isMailDirectory(_ url: URL) -> Bool {
        return url.resolvingSymlinksInPath().path == mailDirectoryURL.resolvingSymlinksInPath().path
    }

    // NSOpenSavePanelDelegate method to constrain the selection to the Mail folder
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        return isMailDirectory(url)
    }
}

enum MailError: LocalizedError, Equatable {
    case invalidArgument(String)
    case accessExpired
    case folderNotReadable
    case composeFailed

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message):
            return "Invalid argument: \(message)"
        case .accessExpired:
            return "Mail folder access has expired. Switch Mail off and on to select the folder again."
        case .folderNotReadable:
            return
                "Mail folder access is unavailable. Switch Mail off and on to select ~/Library/Mail. Composition remains available."
        case .composeFailed:
            return "The default email app could not open the compose URL."
        }
    }
}

struct MailToolError: LocalizedError, CustomStringConvertible {
    let underlying: any Swift.Error

    var description: String { localizedDescription }

    var errorDescription: String? {
        switch underlying {
        case Mail.MailError.mailboxNotFound:
            return
                "Invalid argument: mailbox does not exist in the local index. Use a current numeric @id string from mail_mailboxes_list, for example \"12\"; do not use the url field."
        case Mail.Message.FetchRequest.ValidationError.limitOutOfRange:
            return "Invalid argument: limit must be 1 through 100"
        case Mail.Message.FetchRequest.ValidationError.invalidDateRange:
            return "Invalid argument: start must be before end"
        case Mail.MailError.indexNotFound:
            return
                "Mail access is unavailable: no local Envelope Index was found. Switch Mail off and on to select ~/Library/Mail."
        case Mail.MailError.indexNotReadable:
            return
                "Mail access is unavailable. The index and its live WAL files must be readable. Switch Mail off and on to retry folder access."
        case Mail.MailError.unsupportedJournalMode:
            return
                "Mail reading is unavailable because the index is not in WAL mode. iMCP will not change Mail's database settings."
        case Mail.MailError.databaseBusy:
            return "Mail reading is busy. Try again later; iMCP does not wait for database locks."
        case Mail.MailError.unsupportedMailbox:
            return "Unsupported mailbox storage mapping. Metadata search and composition remain available."
        default:
            return underlying.localizedDescription
        }
    }
}

extension Mail.Account {
    var value: Value {
        [
            "@id": .string(id),
            "email": email.map(Value.string) ?? .null,
        ]
    }
}

extension Mail.Mailbox {
    /// The mailbox as a JSON object for tool output.
    var value: Value {
        [
            "@id": .string(String(id)),
            "@type": "Collection",
            "name": name.map(Value.string) ?? .null,
            "url": url.map(Value.string) ?? .null,
            "account": account?.value ?? .null,
        ]
    }
}

extension Mail.Message {
    /// The record as a JSON object for tool output.
    var value: Value {
        [
            "@type": "EmailMessage",
            "@id": .string(id.description),
            "mailbox": .string(String(id.mailboxID)),
            "subject": subject.map(Value.string) ?? .null,
            "sender": [
                "@type": "Person",
                "email": sender.map(Value.string) ?? .null,
            ],
            "dateReceived": .string(date.formatted(.iso8601)),
            "isRead": .bool(isRead),
        ]
    }
}

extension Emlx.Content {
    /// The content as a JSON object for tool output.
    func value(for identifier: Mail.Message.Identifier) -> Value {
        [
            "@context": "https://schema.org",
            "@type": "EmailMessage",
            "@id": .string(identifier.description),
            "headers": .array(headers.map { ["name": .string($0.name), "value": .string($0.value)] }),
            "text": .string(body),
            "encodingFormat": .string(mediaType),
            "attachment": .array(attachmentFilenames.map { ["@type": "MediaObject", "name": .string($0)] }),
        ]
    }
}

extension Mail.Store.SearchResult {
    var value: Value {
        return [
            "@context": "https://schema.org",
            "@type": "ItemList",
            "itemListElement": .array(records.map(\.value)),
            "nextCursor": nextCursor.map { .string($0.description) } ?? .null,
            "localIndex": [
                "indexedMessageCount": .int(indexedMessageCount),
                "syncStatus": "unknown",
                "description": .string(
                    indexedMessageCount == 0
                        ? "No messages are indexed locally in the selected scope. The mailbox may be empty or Mail may not have indexed it yet. Open Mail to check account sync."
                        : "The count covers locally indexed messages in the selected scope before search filters and pagination. Sync status and server message counts are unavailable."
                ),
            ],
        ]
    }
}

/// A draft that the default email app opens from a `mailto` URL.
struct MailComposition {
    /// Comma-separated recipient addresses.
    var to: String?
    var cc: String?
    var bcc: String?
    var subject: String?
    /// Plain-text body. Line breaks of any kind become CRLF in the URL.
    var body: String?

    var url: URL {
        get throws {
            let forbidden = CharacterSet.controlCharacters.union(.newlines)
            for field in [to, cc, bcc, subject].compactMap({ $0 }) {
                guard !field.unicodeScalars.contains(where: forbidden.contains) else {
                    throw MailError.invalidArgument(
                        "recipients and subject must not contain line breaks or control characters"
                    )
                }
            }

            let body = body?
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\n", with: "\r\n")
            let fields = [("cc", cc), ("bcc", bcc), ("subject", subject), ("body", body)]
                .compactMap { name, value in value.map { name + "=" + Self.encode($0) } }
            let recipients = (to ?? "")
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { Self.encode(String($0)) }
                .joined(separator: ",")

            let query = fields.isEmpty ? "" : "?" + fields.joined(separator: "&")
            guard let url = URL(string: "mailto:" + recipients + query) else {
                throw MailError.composeFailed
            }
            return url
        }
    }

    /// Opens the draft. The opener returns whether an app accepted the URL.
    func open(using opener: (URL) -> Bool) throws {
        guard opener(try url) else {
            throw MailError.composeFailed
        }
    }

    /// Encodes everything but RFC 3986 unreserved characters,
    /// so no part of a field can act as a `mailto` delimiter.
    private static func encode(_ text: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        )
        return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
