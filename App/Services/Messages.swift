import AppKit
import OSLog
import os
import SQLite3
import iMessage

private let log = Logger.service("messages")
private let messagesDirectoryPath = FileManager.userHomeDirectoryURL.appendingPathComponent("Library/Messages").path
private let messagesDatabasePath = messagesDirectoryPath + "/chat.db"
private let messagesDatabaseBookmarkKey: String = "me.mattt.iMCP.messagesDatabaseBookmark"
private let messagesAttachmentsBookmarkKey: String = "me.mattt.iMCP.messagesAttachmentsBookmark"
private let defaultLimit = 30
private let defaultAttachmentMaxBytes = 25 * 1024 * 1024

/// Files are served base64-encoded, so one read allocates several times the
/// file's size; the ceiling keeps a single call from taking the process down.
private let maxAttachmentMaxBytes = 100 * 1024 * 1024

final class MessageService: NSObject, Service, NSOpenSavePanelDelegate {
    static let shared = MessageService()

    /// Whether the once-per-launch warning about a grant on `chat.db` alone has been logged.
    /// Tool calls run concurrently, so the check-and-set is guarded.
    private let fileGrantWarningLogged = OSAllocatedUnfairLock(initialState: false)

    /// Set while the Attachments folder picker is on screen, so the shared
    /// panel delegate enables that folder for that panel alone.
    private var activePanelAcceptsAttachments = false

    func activate() async throws {
        try await activate(offeringUpgrade: true)
    }

    /// Makes sure the database is reachable, asking for the Messages folder when nothing is
    /// granted yet. `offeringUpgrade` decides what happens with a grant on `chat.db` alone, as
    /// earlier versions requested: that grant cannot reach the write-ahead log next to it,
    /// where Messages keeps everything since its last checkpoint, so the newest messages stay
    /// invisible for hours. The menu-bar toggle passes `true` and offers the folder; tool calls
    /// pass `false` and keep working with the old grant instead of parking the whole server
    /// behind a modal alert that nobody may be there to answer.
    private func activate(offeringUpgrade: Bool) async throws {
        log.debug("Starting message service activation")

        if canAccessDatabaseAtDefaultPath {
            log.debug("Successfully activated using default database path")
            return
        }

        let grant = try? resolveBookmarkedGrant()
        var upgrading = false
        if canAccessDatabaseUsingBookmark {
            switch grant {
            case .directory:
                log.debug("Successfully activated using stored bookmark")
                // Existing installs already hold the Messages folder grant;
                // offer the Attachments grant they are missing. Dismissing
                // keeps the service on; only attachment reads stay limited.
                if offeringUpgrade,
                    UserDefaults.standard.data(forKey: messagesAttachmentsBookmarkKey) == nil
                {
                    await offerAttachmentsGrant()
                }
                return
            case .file:
                upgrading = true
            case nil:
                break
            }
        }

        if upgrading, !offeringUpgrade {
            let isFirstWarning = fileGrantWarningLogged.withLock { logged in
                defer { logged = true }
                return !logged
            }
            if isFirstWarning {
                log.warning(
                    "The Messages grant covers chat.db alone, so messages since its last checkpoint are not visible. Switch Messages off and on in the iMCP menu to grant the Messages folder."
                )
            }
            return
        }

        log.debug("Opening folder picker for manual database selection")
        guard try await showDatabaseAccessAlert(upgrading: upgrading) else {
            // Keeping the old grant is a valid answer; the service stays on.
            if upgrading { return }
            throw DatabaseAccessError.userDeclinedAccess
        }

        guard let selectedURL = try await showFolderPicker() else {
            // Dismissing the picker is the same answer as Cancel on the alert.
            if upgrading { return }
            throw DatabaseAccessError.userDeclinedAccess
        }

        guard FileManager.default.isReadableFile(atPath: databaseURL(in: selectedURL).path) else {
            throw DatabaseAccessError.fileNotReadable
        }

        storeBookmark(for: selectedURL)

        // The Attachments subfolder needs a grant of its own (see
        // withAttachmentsGrantScope). Offer it in the same user-initiated
        // flow only — a tool call that just walked the Messages picker must
        // not stack a second modal panel on top. Declining leaves only
        // messages_attachment_read unable to read files.
        if offeringUpgrade,
            UserDefaults.standard.data(forKey: messagesAttachmentsBookmarkKey) == nil
        {
            await offerAttachmentsGrant()
        }

        log.debug("Successfully activated message service")
    }

    var isActivated: Bool {
        get async {
            // A grant on chat.db alone still serves tool calls, but the service is only fully set
            // up once the Messages folder is granted; until then the toggle offers the upgrade.
            var isActivated = canAccessDatabaseAtDefaultPath
            if case .directory = try? resolveBookmarkedGrant() {
                isActivated = isActivated || canAccessDatabaseUsingBookmark
            }
            // The Attachments grant is optional, but while it is missing
            // the toggle must keep calling activate(), whose directory
            // branch offers it — otherwise the remediation the read errors
            // and the README point at ("switch off and on") never runs.
            if !canAccessDatabaseAtDefaultPath, isActivated,
                UserDefaults.standard.data(forKey: messagesAttachmentsBookmarkKey) == nil
            {
                isActivated = false
            }
            log.debug("Message service activation status: \(isActivated)")
            return isActivated
        }
    }

    var tools: [Tool] {
        Tool(
            name: "messages_fetch",
            description:
                """
                Fetch messages from Messages, with each conversation (isPartOf) and its participants. \
                When available, messages whose sender is me include isDelivered, \
                deliveredAt if recorded, and error if nonzero.
                """,
            inputSchema: .object(
                properties: [
                    "participants": .array(
                        description:
                            "Participant handles (phone or email). Phone numbers should use E.164 format",
                        items: .string()
                    ),
                    "chatId": .string(
                        description:
                            "Conversation @id, as reported in a message's isPartOf. Fetches only messages in that conversation"
                    ),
                    "start": .string(
                        description:
                            "Start of the date range (inclusive). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End of the date range (exclusive). If timezone is omitted, local time is assumed. A date-only value includes that whole day.",
                        format: .dateTime
                    ),
                    "query": .string(
                        description: "Search term to filter messages by content"
                    ),
                    "isRead": .boolean(
                        description: "If true, fetch read messages; if false, unread incoming; if omitted, fetch all"
                    ),
                    "limit": .integer(
                        description: "Maximum messages to return",
                        default: .int(defaultLimit)
                    ),
                    "attachments": .boolean(
                        description:
                            "List each message's attachments (attachment: name, encodingFormat, contentSize, @id for messages_attachment_read) and include messages that carry attachments but no text",
                        default: false
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Messages",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            log.debug("Starting message fetch with arguments: \(arguments)")
            try await self.activate(offeringUpgrade: false)

            let participants =
                arguments["participants"]?.arrayValue?.compactMap({
                    $0.stringValue
                }) ?? []

            var requestedChatID: Chat.ID?
            if let value = arguments["chatId"], !value.isNull {
                guard let string = value.stringValue else {
                    throw ArgumentError.invalid("chatId has the wrong type")
                }
                requestedChatID = Chat.ID(rawValue: string)
            }

            // Either bound may be given alone; the other stays open.
            // chat.db stores dates as Int64 nanoseconds since 2001, so the open ends
            // use dates that fit, rather than Date.distantPast and Date.distantFuture.
            let calendar = Calendar.current
            func parsedDate(_ name: String) throws -> (date: Date, isDateOnly: Bool)? {
                guard let value = arguments[name], !value.isNull else { return nil }
                guard let string = value.stringValue else {
                    throw ArgumentError.invalid("\(name) has the wrong type")
                }
                guard let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: string)
                else {
                    throw ArgumentError.invalid("\(name) must be an ISO 8601 date")
                }
                return parsed
            }
            let start = try parsedDate("start")
                .map { calendar.normalizedStartDate(from: $0.date, isDateOnly: $0.isDateOnly) }
            let end = try parsedDate("end")
                .map { calendar.normalizedEndDate(from: $0.date, isDateOnly: $0.isDateOnly) }
            var dateRange: Range<Date>?
            if start != nil || end != nil {
                let lowerBound = start ?? Date(timeIntervalSinceReferenceDate: -9_000_000_000)
                let upperBound = end ?? Date(timeIntervalSinceReferenceDate: 9_000_000_000)
                // An end before the start matches nothing.
                dateRange = lowerBound ..< max(lowerBound, upperBound)
            }

            let searchTerm = arguments["query"]?.stringValue
            let isReadFilter = arguments["isRead"]?.boolValue
            let limit = arguments["limit"]?.intValue
            let includeAttachments = arguments["attachments"]?.boolValue ?? false

            // The grant must stay open until the last read: SQLite opens the write-ahead log lazily.
            let access = try self.openDatabase()
            defer { access.stop() }
            let db = access.database
            var messages: [[String: Value]] = []

            log.debug("Fetching handles for participants: \(participants)")
            let handles = try db.fetchParticipant(matching: participants)

            log.debug(
                "Fetching messages with date range: \(String(describing: dateRange)), limit: \(limit ?? -1)"
            )
            // Match the old fetchMessages(with:in:limit:) semantics:
            // no participant filter when no handles matched.
            var predicates: [MessagePredicate] = []
            if !handles.isEmpty {
                predicates.append(.participantHandles(Set(handles)))
            }
            if let requestedChatID {
                predicates.append(.chatID(requestedChatID))
            }
            if let dateRange {
                predicates.append(.dateRange(dateRange))
            }
            let request = FetchRequest<Message>(
                predicate: .and(predicates),
                limit: max(limit ?? defaultLimit, 1024)
            )

            let fetched = try db.fetch(request)
            // Attachments are listed in one query per page (chat.db joins them by message rowid).
            let attachmentsByMessage: [String: [[String: Value]]] =
                includeAttachments
                ? try self.attachments(ofMessages: fetched.map { $0.id.rawValue }, in: access)
                : [:]
            // Include delivery status for the user's messages when available.
            // A failed status query does not prevent fetching messages.
            var deliveryByMessage: [String: [String: Value]] = [:]
            do {
                deliveryByMessage = try self.deliveryStatus(
                    ofMessages: fetched.filter(\.isFromMe).map { $0.id.rawValue },
                    in: access
                )
            } catch {
                log.error("Could not read delivery status: \(error.localizedDescription, privacy: .public)")
            }

            // Each chat is looked up once and shared by all of its messages.
            var conversations: [Chat.ID: [String: Value]] = [:]

            for message in fetched {
                guard messages.count < (limit ?? defaultLimit) else { break }
                let attachments = attachmentsByMessage[message.id.rawValue] ?? []
                // An attachment-only message has no text, or just the U+FFFC placeholder
                // Messages stores where the attachment sits in the body.
                // Madrid also renders an attachment placeholder as its guid (`at_0_<UUID>`) on its
                // own line, alone or after the real text: those lines are dropped too.
                let attachmentIDs = Set(attachments.compactMap { $0["@id"]?.stringValue })
                let text =
                    includeAttachments
                    ? message.text.replacingOccurrences(of: "\u{FFFC}", with: "")
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .map { String($0) }
                        .filter { line in
                            let t = line.trimmingCharacters(in: .whitespaces)
                            return !(attachmentIDs.contains(t) || Self.isAttachmentGUID(t))
                        }
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    : message.text
                guard !text.isEmpty || !attachments.isEmpty else { continue }

                if let isReadFilter {
                    if isReadFilter {
                        guard message.isRead else { continue }
                    } else {
                        guard !message.isFromMe, !message.isRead else { continue }
                    }
                }

                let sender: String
                if message.isFromMe {
                    sender = "me"
                } else if message.sender == nil {
                    sender = "unknown"
                } else {
                    sender = message.sender!.rawValue
                }

                if let searchTerm {
                    guard text.localizedCaseInsensitiveContains(searchTerm) else {
                        continue
                    }
                }

                var object: [String: Value] = [
                    "@id": .string(message.id.description),
                    "sender": [
                        "@id": .string(sender)
                    ],
                    "text": .string(text),
                    "createdAt": .string(message.date.formatted(.iso8601)),
                    "isRead": .bool(message.isRead),
                ]
                if let readAt = message.readAt {
                    object["dateRead"] = .string(readAt.formatted(.iso8601))
                }
                if !attachments.isEmpty {
                    object["attachment"] = .array(attachments.map { .object($0) })
                }
                if let delivery = deliveryByMessage[message.id.rawValue] {
                    object.merge(delivery) { _, new in new }
                }

                if let chatID = message.chatID {
                    if conversations[chatID] == nil {
                        conversations[chatID] = try self.conversation(for: chatID, in: db)
                    }
                    object["isPartOf"] = conversations[chatID].map { .object($0) }
                }

                messages.append(object)
            }

            log.debug("Successfully fetched \(messages.count) messages")
            return [
                "@context": "https://schema.org",
                "@type": "Conversation",
                "hasPart": Value.array(messages.map({ .object($0) })),
            ]
        }

        Tool(
            name: "messages_attachment_read",
            description:
                "Read one attachment of a message, by the @id messages_fetch lists with attachments=true: the file, base64-encoded, with its name, type and size",
            inputSchema: .object(
                properties: [
                    "id": .string(description: "The attachment @id"),
                    "maxBytes": .integer(
                        description: "Refuse files larger than this",
                        default: .int(defaultAttachmentMaxBytes),
                        minimum: 1,
                        maximum: maxAttachmentMaxBytes
                    ),
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read Message Attachment",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate(offeringUpgrade: false)
            guard let id = arguments["id"]?.stringValue, !id.isEmpty else {
                throw AttachmentError.missingID
            }
            // inputSchema is advertised, not enforced: a present maxBytes
            // of the wrong shape is an error, not a silent default.
            let maxBytes: Int
            switch arguments["maxBytes"] {
            case nil:
                maxBytes = defaultAttachmentMaxBytes
            case .int(let value):
                maxBytes = value
            case .double(let value):
                // JSON Schema counts 30.0 as a valid integer.
                guard let asInt = Int(exactly: value), value.rounded() == value else {
                    throw AttachmentError.maxBytesNotAnInteger
                }
                maxBytes = asInt
            default:
                throw AttachmentError.maxBytesNotAnInteger
            }
            guard maxBytes >= 1, maxBytes <= maxAttachmentMaxBytes else {
                throw AttachmentError.invalidMaxBytes(maxBytes, maxAttachmentMaxBytes)
            }
            return try self.readAttachment(id: id, maxBytes: maxBytes)
        }

        Tool(
            name: "messages_send",
            description:
                """
                Send a text message with the Messages app. \
                Give exactly one destination: recipient (phone number or email) with an optional service, \
                or chatId (the conversation @id in messages_fetch's isPartOf) without service. \
                The user must confirm the recipient, service, and full text in iMCP. \
                Canceling or leaving the confirmation unanswered for \(Int(Self.sendConfirmationTimeout.components.seconds)) seconds sends nothing. \
                Success means Messages accepted the message, not that it was delivered. \
                When iMCP finds the sent message in the Messages database, \
                the result's object has its @id, createdAt, and conversation (isPartOf). \
                To check delivery, call messages_fetch with that chatId and start set to createdAt, \
                then read isDelivered and error on the message with that @id. \
                Missing status doesn't confirm delivery.
                """,
            inputSchema: .object(
                properties: [
                    "recipient": .string(
                        description:
                            "Phone number (prefer E.164) or email address. Give either recipient or chatId"
                    ),
                    "chatId": .string(
                        description:
                            "Conversation @id from messages_fetch's isPartOf. Give either recipient or chatId"
                    ),
                    "text": .string(description: "The message text, sent exactly as given"),
                    "service": .string(
                        description:
                            "Service for recipient; defaults to iMessage. SMS and RCS need an iPhone with Text Message Forwarding. Omit with chatId to use the conversation's service",
                        enum: SendService.allCases.map { .string($0.rawValue) }
                    ),
                ],
                required: ["text"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Send Message",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: false,
                openWorldHint: true
            )
        ) { arguments in
            let request = try SendRequest(arguments: arguments)
            let confirmation = try self.confirmation(for: request, clientName: ToolCallContext.clientName)
            try Self.checkAutomationPermission()
            return try await Self.send(
                request,
                confirm: {
                    await Self.askForConfirmation(timeout: Self.sendConfirmationTimeout) { answer in
                        MessageSendConfirmationWindowController.shared.show(confirmation, onAnswer: answer)
                    }
                },
                deliver: { request in
                    try await Self.deliver(request)
                },
                locate: { request, start in
                    await Self.awaitSentMessage(
                        for: request,
                        sentAfter: start,
                        timeout: Self.sentMessageLookupTimeout,
                        interval: .milliseconds(250)
                    ) {
                        try self.outgoingMessages(since: start)
                    }
                }
            )
        }
    }

    /// The attachments of the given messages (by guid), keyed by message guid, in chat.db
    /// order. Hidden attachments (Messages' own plug-in payloads) are left out.
    /// `at_<n>_<UUID>`: the attachment guid Madrid leaves in place of a placeholder.
    private static func isAttachmentGUID(_ s: String) -> Bool {
        s.range(of: #"^at_\d+_[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil
    }

    private func attachments(
        ofMessages guids: [String],
        in access: DatabaseAccess
    ) throws -> [String: [[String: Value]]] {
        var result: [String: [[String: Value]]] = [:]
        guard !guids.isEmpty else { return result }
        let raw = try RawDatabase(access)
        defer { raw.close() }
        let chunks = stride(from: 0, to: guids.count, by: 500)
            .map { Array(guids[$0 ..< min($0 + 500, guids.count)]) }
        for chunk in chunks {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = """
                SELECT m.guid, a.guid, a.filename, a.transfer_name, a.mime_type, a.total_bytes, a.is_sticker
                FROM message m
                JOIN message_attachment_join j ON j.message_id = m.ROWID
                JOIN attachment a ON a.ROWID = j.attachment_id
                WHERE m.guid IN (\(placeholders)) AND a.hide_attachment = 0
                ORDER BY m.ROWID, a.ROWID
                """
            try raw.query(sql, bindings: chunk) { stmt in
                guard let messageGuid = RawDatabase.text(stmt, 0), let id = RawDatabase.text(stmt, 1)
                else { return }
                var part: [String: Value] = ["@type": "MediaObject", "@id": .string(id)]
                let filename = RawDatabase.text(stmt, 2)
                if let name = RawDatabase.text(stmt, 3) ?? filename.map({ ($0 as NSString).lastPathComponent }),
                    !name.isEmpty
                {
                    part["name"] = .string(name)
                }
                if let mime = RawDatabase.text(stmt, 4), !mime.isEmpty {
                    part["encodingFormat"] = .string(mime)
                }
                part["contentSize"] = .int(Int(sqlite3_column_int64(stmt, 5)))
                if sqlite3_column_int(stmt, 6) != 0 {
                    part["sticker"] = .bool(true)
                }
                result[messageGuid, default: []].append(part)
            }
        }
        return result
    }

    /// Delivery status keyed by message guid: isDelivered,
    /// deliveredAt if recorded, and error if nonzero.
    private func deliveryStatus(
        ofMessages guids: [String],
        in access: DatabaseAccess
    ) throws -> [String: [String: Value]] {
        var result: [String: [String: Value]] = [:]
        guard !guids.isEmpty else { return result }
        let raw = try RawDatabase(access)
        defer { raw.close() }
        let chunks = stride(from: 0, to: guids.count, by: 500)
            .map { Array(guids[$0 ..< min($0 + 500, guids.count)]) }
        for chunk in chunks {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = """
                SELECT guid, is_delivered, date_delivered, error
                FROM message
                WHERE guid IN (\(placeholders))
                """
            try raw.query(sql, bindings: chunk) { stmt in
                guard let guid = RawDatabase.text(stmt, 0) else { return }
                var status: [String: Value] = ["isDelivered": .bool(sqlite3_column_int(stmt, 1) != 0)]
                // chat.db stores dates as nanoseconds since 2001.
                let deliveredAt = sqlite3_column_int64(stmt, 2)
                if deliveredAt > 0 {
                    let date = Date(timeIntervalSinceReferenceDate: Double(deliveredAt) / 1_000_000_000)
                    status["deliveredAt"] = .string(date.formatted(.iso8601))
                }
                let error = sqlite3_column_int(stmt, 3)
                if error != 0 {
                    status["error"] = .int(Int(error))
                }
                result[guid] = status
            }
        }
        return result
    }

    /// Reads one attachment file and returns it base64-encoded. The file sits under
    /// `~/Library/Messages/Attachments`, which the sandbox hides from the Messages folder
    /// grant, so the read goes through the Attachments grant's own scope.
    private func readAttachment(id: String, maxBytes: Int) throws -> [String: Value] {
        let access = try openDatabase()
        defer { access.stop() }
        let raw = try RawDatabase(access)
        defer { raw.close() }
        var found: (filename: String?, name: String?, mime: String?)?
        try raw.query(
            "SELECT filename, transfer_name, mime_type FROM attachment WHERE guid = ? LIMIT 1",
            bindings: [id]
        ) { stmt in
            found = (RawDatabase.text(stmt, 0), RawDatabase.text(stmt, 1), RawDatabase.text(stmt, 2))
        }
        guard let found else { throw AttachmentError.notFound(id) }
        guard var path = found.filename, !path.isEmpty else { throw AttachmentError.noFile(id) }
        if path.hasPrefix("~/") {
            path = FileManager.userHomeDirectoryURL.appendingPathComponent(String(path.dropFirst(2))).path
        }
        // Only what sits in the Messages folder is served: that is what the grant covers, and
        // an arbitrary path in chat.db must not turn this tool into a file reader. Symlinks
        // are resolved and checked inside the Attachments scope: before it starts, the
        // sandbox hides that subtree, so resolution cannot see through a planted link and
        // one could pass by its /Messages/Attachments/... spelling alone, with FileHandle
        // following it anywhere readable once the scopes are active.
        let data: Data
        let resolvedName: String
        (data, resolvedName) = try withAttachmentsGrantScope {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard url.path.hasPrefix(messagesDirectoryPath + "/") else {
                throw AttachmentError.outsideMessagesFolder(id)
            }
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw AttachmentError.fileMissing(id)
            }
            // A file whose size cannot be read is not readable either; reporting it
            // as zero bytes would slip past the limit instead of failing honestly.
            guard
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                let size = attributes[.size] as? Int
            else {
                throw AttachmentError.fileMissing(id)
            }
            guard size <= maxBytes else { throw AttachmentError.tooLarge(id, size, maxBytes) }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // The checks above name a path,
            // and the open follows whatever that path is by now:
            // a link swapped in after them would lead out of the Messages folder.
            // Check the file that was actually opened.
            guard let openedPath = Self.openedPath(of: handle) else {
                throw AttachmentError.fileMissing(id)
            }
            guard openedPath.hasPrefix(messagesDirectoryPath + "/") else {
                throw AttachmentError.outsideMessagesFolder(id)
            }
            // Read to EOF or one byte past the limit: read(upToCount:) can
            // return short before EOF, so serving a single chunk could
            // silently truncate, and stopping at the limit alone would let
            // a file that grew past it during the read pass as complete.
            var data = Data()
            while data.count <= maxBytes {
                guard let chunk = try handle.read(upToCount: maxBytes + 1 - data.count) else {
                    break
                }
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            guard data.count <= maxBytes else {
                // The file grew past the limit mid-read; the pre-read size
                // is stale and data.count is capped at the limit, so report
                // the size as of now for a number the caller can act on.
                let grownSize =
                    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
                    ?? data.count
                throw AttachmentError.tooLarge(id, grownSize, maxBytes)
            }
            return (data, url.lastPathComponent)
        }
        var part: [String: Value] = [
            "@type": "MediaObject",
            "@id": .string(id),
            "contentSize": .int(data.count),
            "encoding": "base64",
            "content": .string(data.base64EncodedString()),
        ]
        if let name = found.name ?? Optional(resolvedName), !name.isEmpty {
            part["name"] = .string(name)
        }
        if let mime = found.mime, !mime.isEmpty {
            part["encodingFormat"] = .string(mime)
        }
        return part
    }

    /// The path of the file that an open handle refers to,
    /// as the kernel reports it after following any symbolic links.
    private static func openedPath(of handle: FileHandle) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(handle.fileDescriptor, F_GETPATH, &buffer) != -1 else { return nil }
        return buffer.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } }
    }

    /// `~/Library/Messages/Attachments` is walled off from a grant on the Messages folder:
    /// with that folder's security scope active, everything else is readable (chat.db and its
    /// log, sibling folders like StickerCache) but the Attachments subtree is denied outright,
    /// listing included. A grant on the Attachments folder itself lifts the wall, so
    /// attachment files are read through their own scope.
    private func withAttachmentsGrantScope<T>(_ operation: () throws -> T) throws -> T {
        // Without the sandbox in the way (development builds on the default path),
        // no grant is needed. The Attachments folder itself is the probe: it stays
        // unreadable under the Messages folder grant even while that grant's scope
        // is active (tool calls open one around chat.db), so only a process the
        // sandbox does not confine passes here. A stored grant takes precedence
        // over the probe — another call's scope could make the probe pass, and
        // starting a scope of our own is always safe.
        let storedBookmark = UserDefaults.standard.data(forKey: messagesAttachmentsBookmarkKey)
        if storedBookmark == nil {
            let attachmentsPath = messagesDirectoryPath + "/Attachments"
            if FileManager.default.isReadableFile(atPath: attachmentsPath) {
                return try operation()
            }
            // Under a grant on chat.db alone the Messages folder itself is
            // unreachable: the Attachments folder is walled off, not
            // deleted, and the remediation that fixes it is the folder
            // upgrade the grantMissing error points at.
            guard FileManager.default.isReadableFile(atPath: messagesDirectoryPath) else {
                throw AttachmentError.grantMissing
            }
            // The Messages folder is readable, so the sandbox is either out
            // of the way or held to the folder grant whose wall leaves the
            // Attachments directory entry stat-able while denying the
            // subtree: a folder that does not exist is deleted — let the
            // per-file checks speak — while one that exists is walled.
            if !FileManager.default.fileExists(atPath: attachmentsPath) {
                return try operation()
            }
        }

        guard let bookmarkData = storedBookmark else {
            throw AttachmentError.grantMissing
        }
        // A grant that cannot be used is dropped rather than kept: the
        // re-grant path the errors point at (switch Messages off and on)
        // only offers the picker when no bookmark is stored.
        let url: URL
        do {
            var isStale = false
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            // A stale bookmark can still resolve and start its scope while
            // pointing nowhere useful; re-store it from the resolved URL
            // while it works.
            if isStale {
                storeAttachmentsBookmark(for: url)
            }
        } catch {
            UserDefaults.standard.removeObject(forKey: messagesAttachmentsBookmarkKey)
            throw AttachmentError.grantScopeFailed
        }
        guard url.startAccessingSecurityScopedResource() else {
            UserDefaults.standard.removeObject(forKey: messagesAttachmentsBookmarkKey)
            throw AttachmentError.grantScopeFailed
        }
        // Starting the scope does not prove the bookmark still covers the
        // Attachments folder: a stale bookmark can resolve and start a
        // scope while pointing elsewhere, and the read would then fail
        // against the fixed current path while the unusable grant stays
        // stored, hiding the re-grant the errors point at. Drop the grant
        // unless the folder is readable through it.
        if !FileManager.default.isReadableFile(atPath: messagesDirectoryPath + "/Attachments") {
            url.stopAccessingSecurityScopedResource()
            UserDefaults.standard.removeObject(forKey: messagesAttachmentsBookmarkKey)
            throw AttachmentError.grantScopeFailed
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try operation()
    }

    private enum AttachmentError: LocalizedError {
        case missingID
        case notFound(String)
        case noFile(String)
        case outsideMessagesFolder(String)
        case fileMissing(String)
        case tooLarge(String, Int, Int)
        case invalidMaxBytes(Int, Int)
        case maxBytesNotAnInteger
        case grantMissing
        case grantScopeFailed
        case wrongFolderSelected

        var errorDescription: String? {
            switch self {
            case .missingID: return "attachment id is required"
            case .notFound(let id): return "no attachment \(id) in the Messages database"
            case .noFile(let id): return "attachment \(id) has no file (not downloaded on this Mac)"
            case .outsideMessagesFolder(let id): return "attachment \(id) is not stored in the Messages folder"
            case .fileMissing(let id): return "the file of attachment \(id) is missing or unreadable"
            case .tooLarge(let id, let size, let max):
                return "attachment \(id) is \(size) bytes, more than the \(max) allowed"
            case .invalidMaxBytes(let maxBytes, let ceiling):
                return "maxBytes \(maxBytes) is out of range; pass between 1 and \(ceiling)"
            case .maxBytesNotAnInteger:
                return "maxBytes must be an integer"
            case .grantMissing:
                return
                    "the Attachments folder (~/Library/Messages/Attachments) has not been granted; switch Messages off and on in the iMCP menu and select it when asked"
            case .grantScopeFailed:
                return
                    "could not start reading through the Attachments grant; switch Messages off and on in the iMCP menu to grant the Attachments folder again"
            case .wrongFolderSelected:
                return
                    "the selected folder is not the Attachments folder (~/Library/Messages/Attachments)"
            }
        }
    }

    /// A second, read-only SQLite connection on the same grant, for the data the iMessage
    /// package does not model (attachments and delivery status).
    /// It uses `immutable=1` whenever the package does:
    /// a `.file` grant, or a default path whose write-ahead log is unreadable.
    private final class RawDatabase {
        private var handle: OpaquePointer?
        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        init(_ access: DatabaseAccess) throws {
            let options = access.immutable ? "immutable=1" : "mode=ro"
            let uri = "file:\(access.path)?\(options)"
            var h: OpaquePointer?
            let rc = sqlite3_open_v2(uri, &h, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
            guard rc == SQLITE_OK, let h else {
                let message = h.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error \(rc)"
                if let h { sqlite3_close(h) }
                throw DatabaseAccessError.queryFailed(message)
            }
            sqlite3_busy_timeout(h, 1000)
            handle = h
        }

        func close() {
            if let handle { sqlite3_close(handle) }
            handle = nil
        }

        func query(_ sql: String, bindings: [String], _ row: (OpaquePointer) throws -> Void) throws {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw DatabaseAccessError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            defer { sqlite3_finalize(stmt) }
            for (i, value) in bindings.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), value, -1, RawDatabase.transient)
            }
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    try row(stmt)
                } else if rc == SQLITE_DONE {
                    return
                } else {
                    throw DatabaseAccessError.queryFailed(String(cString: sqlite3_errmsg(handle)))
                }
            }
        }

        static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
            sqlite3_column_text(stmt, column).map { String(cString: $0) }
        }
    }

    /// Describes the chat a message belongs to:
    /// its identifier, its display name (group chats) and its participants.
    private func conversation(
        for chatID: Chat.ID,
        in db: iMessage.Database
    ) throws -> [String: Value] {
        var conversation: [String: Value] = [
            "@type": "Conversation",
            "@id": .string(chatID.rawValue),
        ]

        let request = FetchRequest<Chat>(predicate: .id(chatID), limit: 1)
        if let chat = try db.fetch(request).first {
            if let name = chat.displayName, !name.isEmpty {
                conversation["name"] = .string(name)
            }
            conversation["participant"] = .array(
                chat.participants.map { .object(["@id": .string($0.rawValue)]) }
            )
        }

        return conversation
    }

    private var canAccessDatabaseAtDefaultPath: Bool {
        return FileManager.default.isReadableFile(atPath: messagesDatabasePath)
    }

    private enum ArgumentError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let message):
                return "Invalid argument: \(message)"
            }
        }
    }

    private enum DatabaseAccessError: LocalizedError {
        case noBookmarkFound
        case securityScopeAccessFailed
        case invalidParticipants
        case userDeclinedAccess
        case invalidFileSelected
        case fileNotReadable
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .noBookmarkFound:
                return "No stored bookmark found for database access"
            case .securityScopeAccessFailed:
                return "Failed to access security-scoped resource"
            case .invalidParticipants:
                return "Invalid participants provided"
            case .userDeclinedAccess:
                return "User declined to grant access to the messages database"
            case .invalidFileSelected:
                return "Messages database access denied or the selection is not the Messages folder"
            case .fileNotReadable:
                return "The selected folder has no readable chat.db"
            case .queryFailed(let message):
                return "Reading the Messages database failed: \(message)"
            }
        }
    }

    private func withSecurityScopedAccess<T>(_ url: URL, _ operation: (URL) throws -> T) throws -> T {
        guard url.startAccessingSecurityScopedResource() else {
            log.error("Failed to start accessing security-scoped resource")
            throw DatabaseAccessError.securityScopeAccessFailed
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try operation(url)
    }

    private func resolveBookmarkURL() throws -> URL {
        guard let bookmarkData = UserDefaults.standard.data(forKey: messagesDatabaseBookmarkKey)
        else {
            throw DatabaseAccessError.noBookmarkFound
        }

        var isStale = false
        return try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    /// What the stored bookmark grants access to.
    private enum BookmarkedGrant {
        /// The Messages folder: `chat.db` together with its write-ahead log.
        case directory(URL)
        /// `chat.db` alone, as stored by earlier versions: the log next to it is unreadable,
        /// so SQLite has to ignore it and messages since the last checkpoint are missing.
        case file(URL)

        var url: URL {
            switch self {
            case .directory(let url), .file(let url):
                return url
            }
        }

        var databaseURL: URL {
            switch self {
            case .directory(let url):
                return url.appendingPathComponent("chat.db")
            case .file(let url):
                return url
            }
        }
    }

    private func databaseURL(in directory: URL) -> URL {
        return directory.appendingPathComponent("chat.db")
    }

    private func resolveBookmarkedGrant() throws -> BookmarkedGrant {
        let url = try resolveBookmarkURL()
        let isDirectory = try withSecurityScopedAccess(url) { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath
        }
        return isDirectory ? .directory(url) : .file(url)
    }

    /// An open connection and the security scope it reads through.
    private struct DatabaseAccess {
        let database: iMessage.Database
        /// Where `database` was opened.
        let path: String
        fileprivate let scopedURL: URL?

        /// Whether `database` was opened without its write-ahead log.
        /// Other connections on the same file must open it the same way,
        /// or the sandbox and privacy checks that made Madrid fall back refuse them.
        var immutable: Bool {
            database.accessMode == .immutable
        }

        /// Ends the security scope. Call it after the last read on `database`.
        func stop() {
            scopedURL?.stopAccessingSecurityScopedResource()
        }
    }

    private func openDatabase() throws -> DatabaseAccess {
        if canAccessDatabaseAtDefaultPath {
            return DatabaseAccess(
                database: try iMessage.Database(path: messagesDatabasePath),
                path: messagesDatabasePath,
                scopedURL: nil
            )
        }

        let grant = try resolveBookmarkedGrant()
        guard grant.url.startAccessingSecurityScopedResource() else {
            log.error("Failed to start accessing security-scoped resource")
            throw DatabaseAccessError.securityScopeAccessFailed
        }

        do {
            let database: iMessage.Database
            switch grant {
            case .directory:
                database = try iMessage.Database(path: grant.databaseURL.path, mode: .live)
            case .file:
                // Warned about once, in activate(offeringUpgrade:).
                database = try iMessage.Database(path: grant.databaseURL.path, mode: .immutable)
            }
            return DatabaseAccess(
                database: database,
                path: grant.databaseURL.path,
                scopedURL: grant.url
            )
        } catch {
            grant.url.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    private var canAccessDatabaseUsingBookmark: Bool {
        do {
            let grant = try resolveBookmarkedGrant()
            return try withSecurityScopedAccess(grant.url) { _ in
                FileManager.default.isReadableFile(atPath: grant.databaseURL.path)
            }
        } catch {
            log.error("Error accessing database with bookmark: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    private func showDatabaseAccessAlert(upgrading: Bool) async throws -> Bool {
        let alert = NSAlert()
        alert.messageText = "Messages Database Access Required"
        if upgrading {
            alert.informativeText = """
                iMCP can currently read `chat.db` alone. Messages writes new messages to a log \
                next to it first, so the latest ones stay invisible for hours.

                In the next screen, please select the `Messages` folder and click "Grant Access".
                """
        } else {
            alert.informativeText = """
                To read your Messages history, we need access to your Messages folder: the \
                database and the log Messages writes new messages to.

                In the next screen, please select the `Messages` folder and click "Grant Access".
                """
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Returns the selected folder, or nil when the user dismisses the panel.
    @MainActor
    private func showFolderPicker() async throws -> URL? {
        let openPanel = NSOpenPanel()
        openPanel.delegate = self
        openPanel.message = "Please select your Messages folder (~/Library/Messages)"
        openPanel.prompt = "Grant Access"
        openPanel.directoryURL = URL(fileURLWithPath: messagesDirectoryPath)
            .deletingLastPathComponent()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.showsHiddenFiles = true

        guard openPanel.runModal() == .OK, let url = openPanel.url else {
            return nil
        }
        guard isMessagesDirectory(url) else {
            throw DatabaseAccessError.invalidFileSelected
        }

        return url
    }

    /// Returns the selected Attachments folder, or nil when the user dismisses
    /// the panel. Selecting any other folder is an error, not a silent no-op.
    @MainActor
    private func showAttachmentsFolderPicker() async throws -> URL? {
        let openPanel = NSOpenPanel()
        openPanel.delegate = self
        openPanel.message =
            "Attachments are stored in a folder the Messages grant cannot reach. Please select the Attachments folder (~/Library/Messages/Attachments) to let iMCP read them"
        openPanel.prompt = "Grant Access"
        openPanel.directoryURL = URL(fileURLWithPath: messagesDirectoryPath)
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.showsHiddenFiles = true
        activePanelAcceptsAttachments = true
        defer { activePanelAcceptsAttachments = false }

        guard openPanel.runModal() == .OK, let url = openPanel.url else {
            return nil
        }
        guard url.standardizedFileURL.path == messagesDirectoryPath + "/Attachments" else {
            throw AttachmentError.wrongFolderSelected
        }

        return url
    }

    /// Asks for the Attachments folder and stores the grant when it is
    /// granted. Dismissing or selecting the wrong folder keeps the service
    /// running — only attachment reads stay limited — but a wrong selection
    /// is logged rather than passed off as granted.
    private func offerAttachmentsGrant() async {
        do {
            if let attachmentsURL = try await showAttachmentsFolderPicker() {
                storeAttachmentsBookmark(for: attachmentsURL)
            } else {
                log.info("Attachments folder not granted; attachment reads stay unavailable")
            }
        } catch {
            log.error(
                "Attachments folder not granted: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func storeAttachmentsBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: messagesAttachmentsBookmarkKey)
            log.debug("Successfully created and stored Attachments bookmark")
        } catch {
            log.error("Failed to create Attachments bookmark: \(error.localizedDescription)")
        }
    }

    private func storeBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: messagesDatabaseBookmarkKey)
            log.debug("Successfully created and stored bookmark")
        } catch {
            log.error("Failed to create bookmark: \(error.localizedDescription)")
        }
    }

    private func isMessagesDirectory(_ url: URL) -> Bool {
        return url.lastPathComponent == "Messages"
    }

    // NSOpenSavePanelDelegate method constraining the selection to the folder
    // the active panel asks for: the Messages folder, or its Attachments
    // subfolder when that is the one being granted.
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let shouldEnable =
            (!activePanelAcceptsAttachments && isMessagesDirectory(url))
            || (activePanelAcceptsAttachments && url.lastPathComponent == "Attachments")
        log.debug(
            "File selection panel: \(shouldEnable ? "enabling" : "disabling") URL: \(url.path)"
        )
        return shouldEnable
    }
}

// MARK: - Sending

private let messagesBundleIdentifier = "com.apple.MobileSMS"

extension MessageService {
    /// Time allowed for the user to confirm a send.
    static let sendConfirmationTimeout: Duration = .seconds(50)

    /// The service for a phone number or email address.
    enum SendService: String, CaseIterable, Sendable {
        case iMessage
        case SMS
        case RCS

        /// The code of the matching `service type` enumerator
        /// in the Messages scripting dictionary.
        var serviceTypeCode: FourCharCode {
            switch self {
            case .iMessage: return fourCharCode("sims")
            case .SMS: return fourCharCode("ssms")
            case .RCS: return fourCharCode("srcs")
            }
        }
    }

    /// A validated `messages_send` call: where the message goes and what it says.
    struct SendRequest: Equatable, Sendable {
        enum Destination: Equatable, Sendable {
            /// A phone number or email address, on the given service.
            case recipient(String, SendService)
            /// An existing conversation, by its chat.db guid.
            /// The conversation keeps the service it already uses.
            case chat(String)
        }

        let destination: Destination
        let text: String

        init(destination: Destination, text: String) {
            self.destination = destination
            self.text = text
        }

        /// Validates supported arguments because the server does not enforce the schema.
        init(arguments: [String: Value]) throws {
            func string(_ name: String) throws -> String? {
                guard let value = arguments[name], !value.isNull else { return nil }
                guard let string = value.stringValue else {
                    throw SendError.invalidArgument("\(name) must be a string")
                }
                return string
            }

            guard let text = try string("text"),
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw SendError.invalidArgument("text is required and must not be blank")
            }

            let recipient = try string("recipient")
            let chatID = try string("chatId")
            let service = try string("service")

            switch (recipient, chatID) {
            case (nil, nil):
                throw SendError.invalidArgument("give either recipient or chatId")
            case (.some, .some):
                throw SendError.invalidArgument("give either recipient or chatId, not both")
            case (let recipient?, nil):
                guard let handle = SendRequest.normalizedRecipient(recipient) else {
                    throw SendError.invalidArgument(
                        "recipient must be a phone number or an email address"
                    )
                }
                var sendService = SendService.iMessage
                if let service {
                    guard
                        let match = SendService.allCases.first(where: {
                            $0.rawValue.caseInsensitiveCompare(service) == .orderedSame
                        })
                    else {
                        let expected = SendService.allCases.map(\.rawValue).joined(separator: ", ")
                        throw SendError.invalidArgument("service must be one of: \(expected)")
                    }
                    sendService = match
                }
                self.init(destination: .recipient(handle, sendService), text: text)
            case (nil, let chatID?):
                guard service == nil else {
                    throw SendError.invalidArgument(
                        "service applies only to recipient; a conversation keeps its own service"
                    )
                }
                let chatID = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
                // chat.db guids look like `iMessage;-;+15551234567` or `any;+;chat123456`.
                guard chatID.range(of: #"^[^;\s]+;[-+];\S+$"#, options: .regularExpression) != nil
                else {
                    throw SendError.invalidArgument(
                        "chatId must be a conversation @id from messages_fetch, such as iMessage;-;+15551234567"
                    )
                }
                self.init(destination: .chat(chatID), text: text)
            }
        }

        /// Returns a Messages handle, or `nil` for an invalid phone number or email.
        /// Trims surrounding whitespace and removes phone number formatting,
        /// keeping a leading plus sign.
        static func normalizedRecipient(_ recipient: String) -> String? {
            let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("@") {
                let isEmail =
                    trimmed.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
                return isEmail ? trimmed : nil
            }
            guard trimmed.range(of: #"^\+?[0-9 ().-]+$"#, options: .regularExpression) != nil else {
                return nil
            }
            let digits = trimmed.filter(\.isASCII).filter(\.isNumber)
            // Short codes have as few as three digits; E.164 allows fifteen.
            guard (3 ... 15).contains(digits.count) else { return nil }
            return (trimmed.hasPrefix("+") ? "+" : "") + digits
        }

        /// The service from the request or conversation ID.
        /// Displays "Chosen by Messages" for unrecognized prefixes, including `any`.
        var serviceDescription: String {
            switch destination {
            case .recipient(_, let service):
                return service.rawValue
            case .chat(let id):
                let prefix = id.prefix(while: { $0 != ";" })
                if let service = SendService.allCases.first(where: { $0.rawValue == prefix }) {
                    return service.rawValue
                }
                return "Chosen by Messages"
            }
        }

        /// The Apple event that calls a handler in ``MessageService/sendScriptSource``.
        /// Passes text and recipient as typed descriptors, never as script source.
        var handlerEvent: NSAppleEventDescriptor {
            switch destination {
            case .recipient(let handle, let service):
                return MessageService.handlerEvent(
                    named: "sendToParticipant",
                    parameters: [
                        NSAppleEventDescriptor(string: text),
                        NSAppleEventDescriptor(string: handle),
                        NSAppleEventDescriptor(enumCode: service.serviceTypeCode),
                    ]
                )
            case .chat(let id):
                return MessageService.handlerEvent(
                    named: "sendToChat",
                    parameters: [
                        NSAppleEventDescriptor(string: text),
                        NSAppleEventDescriptor(string: id),
                    ]
                )
            }
        }

        /// Whether a chat in chat.db is where this request sends:
        /// the requested conversation,
        /// or the one-to-one conversation with the recipient,
        /// whose guid ends with the recipient's handle.
        /// Messages adds a country code to a phone number given without one,
        /// so a phone number also matches the end of a longer one.
        func isDestination(ofChat chatID: String?) -> Bool {
            guard let chatID else { return false }
            switch destination {
            case .chat(let id):
                return chatID == id
            case .recipient(let handle, _):
                let parts = chatID.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, parts[1] == "-" else { return false }
                let chatHandle = String(parts[2])
                if handle.contains("@") {
                    return chatHandle.caseInsensitiveCompare(handle) == .orderedSame
                }
                let digits = handle.filter(\.isNumber)
                let chatDigits = chatHandle.filter(\.isNumber)
                guard !chatHandle.contains("@"), !digits.isEmpty else { return false }
                return chatDigits == digits || (digits.count >= 7 && chatDigits.hasSuffix(digits))
            }
        }

        /// What `messages_send` returns once Messages accepts the message.
        /// The sent message's @id, date, and conversation are included
        /// when it was found in chat.db.
        func result(sentMessage: OutgoingMessage?) -> [String: Value] {
            var object: [String: Value] = [
                "@type": "Message",
                "text": .string(text),
            ]
            if let sentMessage {
                object["@id"] = .string(sentMessage.id)
                object["createdAt"] = .string(sentMessage.date.formatted(.iso8601))
                if let chatID = sentMessage.chatID {
                    object["isPartOf"] = ["@type": "Conversation", "@id": .string(chatID)]
                }
            }
            var result: [String: Value] = [
                "@context": "https://schema.org",
                "@type": "SendAction",
                "actionStatus": "CompletedActionStatus",
                "object": .object(object),
            ]
            if sentMessage == nil {
                let seconds = MessageService.sentMessageLookupTimeout.components.seconds
                result["description"] = .string(
                    "Messages accepted the message, but iMCP couldn't find it in the Messages database within \(seconds) seconds, so it has no @id."
                )
            }
            switch destination {
            case .recipient(let handle, let service):
                result["recipient"] = ["@id": .string(handle)]
                result["instrument"] = ["name": .string(service.rawValue)]
            case .chat(let id):
                result["recipient"] = ["@type": "Conversation", "@id": .string(id)]
            }
            return result
        }
    }

    /// The handlers that send a message.
    /// The source is fixed; ``SendRequest/handlerEvent`` supplies the values.
    /// The service type arrives as an enumerator code rather than a term,
    /// so the script compiles on systems whose dictionary lacks `RCS`.
    static let sendScriptSource = """
        on sendToParticipant(messageText, recipientHandle, serviceType)
            tell application id "\(messagesBundleIdentifier)"
                set targetAccount to first account whose service type is serviceType
                send messageText to participant recipientHandle of targetAccount
            end tell
        end sendToParticipant

        on sendToChat(messageText, chatID)
            tell application id "\(messagesBundleIdentifier)"
                send messageText to chat id chatID
            end tell
        end sendToChat
        """

    /// Builds an Apple event that calls an AppleScript handler with positional parameters.
    /// AppleScript matches handler names without regard to case,
    /// and expects the name in the event in lowercase.
    /// The codes are `kASAppleScriptSuite`, `kASSubroutineEvent`, and `keyASSubroutineName`
    /// from Carbon's `ASRegistry.h`.
    static func handlerEvent(
        named name: String,
        parameters: [NSAppleEventDescriptor]
    ) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: fourCharCode("ascr"),
            eventID: fourCharCode("psbr"),
            targetDescriptor: .currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setDescriptor(
            NSAppleEventDescriptor(string: name.lowercased()),
            forKeyword: fourCharCode("snam")
        )
        let list = NSAppleEventDescriptor.list()
        for (index, parameter) in parameters.enumerated() {
            list.insert(parameter, at: index + 1)
        }
        event.setParam(list, forKeyword: keyDirectObject)
        return event
    }

    /// The user's answer to a send confirmation.
    enum SendConfirmationAnswer: Equatable, Sendable {
        case send
        case cancel
        case timeout
    }

    /// Sends a message only after `confirm` reports that the user chose Send.
    /// Any other answer throws, and `deliver` is never called.
    /// After the send, `locate` looks for the message in chat.db,
    /// given the time just before the send started;
    /// not finding it leaves the result without an @id but doesn't fail the send.
    static func send(
        _ request: SendRequest,
        confirm: () async -> SendConfirmationAnswer,
        deliver: (SendRequest) async throws -> Void,
        locate: (SendRequest, Date) async -> OutgoingMessage?
    ) async throws -> [String: Value] {
        switch await confirm() {
        case .send:
            break
        case .cancel:
            log.notice("The user declined to send a message")
            throw SendError.declined
        case .timeout:
            log.notice("A message was not sent because its confirmation timed out")
            throw SendError.timedOut
        }
        let start = Date()
        try await deliver(request)
        log.notice("Messages accepted a message for sending")
        let sentMessage = await locate(request, start)
        if sentMessage == nil {
            log.notice("The sent message didn't appear in the Messages database in time")
        }
        return request.result(sentMessage: sentMessage)
    }

    // MARK: Finding the sent message

    /// How long `messages_send` waits for the sent message to appear in chat.db.
    /// Messages records it asynchronously, usually within a second.
    static let sentMessageLookupTimeout: Duration = .seconds(5)

    /// A message from chat.db, with what's needed to match it to a send.
    struct OutgoingMessage: Equatable, Sendable {
        /// The message's guid, which messages_fetch reports as its @id.
        let id: String
        let chatID: String?
        let text: String
        let date: Date
        let isFromMe: Bool
    }

    /// Returns the message that a send posted:
    /// the newest message from me, dated at or after `start`,
    /// in the request's conversation, with the request's text.
    /// Text is compared without surrounding whitespace,
    /// which Messages may trim.
    static func sentMessage(
        for request: SendRequest,
        sentAfter start: Date,
        among messages: [OutgoingMessage]
    ) -> OutgoingMessage? {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return
            messages
            .filter { message in
                message.isFromMe
                    && message.date >= start
                    && message.text.trimmingCharacters(in: .whitespacesAndNewlines) == text
                    && request.isDestination(ofChat: message.chatID)
            }
            .max { $0.date < $1.date }
    }

    /// Reads messages with `read` until one matches the send or `timeout` passes.
    /// `read` returns `nil` when chat.db can't be read, which ends the search;
    /// an error from one read is retried with the next.
    static func awaitSentMessage(
        for request: SendRequest,
        sentAfter start: Date,
        timeout: Duration,
        interval: Duration,
        read: () throws -> [OutgoingMessage]?
    ) async -> OutgoingMessage? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            do {
                guard let messages = try read() else { return nil }
                if let message = sentMessage(for: request, sentAfter: start, among: messages) {
                    return message
                }
            } catch {
                log.debug("Reading sent messages failed: \(error.localizedDescription, privacy: .public)")
            }
            guard clock.now < deadline else { return nil }
            try? await Task.sleep(for: min(interval, deadline - clock.now))
        }
    }

    /// The messages dated at or after `start`,
    /// or `nil` when chat.db can't be read without asking the user.
    fileprivate func outgoingMessages(since start: Date) throws -> [OutgoingMessage]? {
        guard let access = try? openDatabase() else { return nil }
        defer { access.stop() }
        // chat.db stores dates as Int64 nanoseconds since 2001, so the open end uses a date that fits.
        let request = FetchRequest<Message>(
            predicate: .dateRange(start ..< Date(timeIntervalSinceReferenceDate: 9_000_000_000)),
            limit: 100
        )
        return try access.database.fetch(request).map { message in
            OutgoingMessage(
                id: message.id.description,
                chatID: message.chatID?.rawValue,
                text: message.text,
                date: message.date,
                isFromMe: message.isFromMe
            )
        }
    }

    /// Waits for the user's send confirmation.
    ///
    /// `present` receives an answer handler (`true` for Send)
    /// and returns a closure to dismiss the window.
    /// A timeout or task cancellation dismisses the window without approval.
    @MainActor
    static func askForConfirmation(
        timeout: Duration,
        present: @MainActor (@escaping @MainActor (Bool) -> Void) -> @MainActor () -> Void
    ) async -> SendConfirmationAnswer {
        let pending = PendingSendConfirmation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                MainActor.assumeIsolated {
                    pending.continuation = continuation
                    let dismiss = present { approved in
                        pending.finish(approved ? .send : .cancel)
                    }
                    guard pending.isWaiting else { return }
                    pending.dismiss = dismiss
                    pending.timeoutTask = Task { @MainActor in
                        try? await Task.sleep(for: timeout)
                        guard !Task.isCancelled else { return }
                        pending.finish(.timeout)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in pending.finish(.cancel) }
        }
    }

    /// Tracks one confirmation and accepts only its first answer.
    @MainActor
    private final class PendingSendConfirmation {
        var continuation: CheckedContinuation<SendConfirmationAnswer, Never>?
        var dismiss: (@MainActor () -> Void)?
        var timeoutTask: Task<Void, Never>?

        var isWaiting: Bool { continuation != nil }

        func finish(_ answer: SendConfirmationAnswer) {
            guard let continuation else { return }
            self.continuation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            dismiss?()
            dismiss = nil
            continuation.resume(returning: answer)
        }
    }

    /// Builds the confirmation, adding conversation details when chat.db is readable.
    /// A readable database must contain the requested conversation.
    fileprivate func confirmation(
        for request: SendRequest,
        clientName: String?
    ) throws -> MessageSendConfirmation {
        switch request.destination {
        case .recipient(let handle, _):
            return MessageSendConfirmation(
                clientName: clientName,
                recipient: handle,
                conversationID: nil,
                service: request.serviceDescription,
                text: request.text
            )
        case .chat(let id):
            var recipient = id
            if let access = try? openDatabase() {
                defer { access.stop() }
                let chatID = Chat.ID(rawValue: id)
                guard
                    let chat = try access.database.fetch(FetchRequest<Chat>(predicate: .id(chatID), limit: 1))
                        .first
                else {
                    throw SendError.unknownChat(id)
                }
                let participants = chat.participants.map(\.rawValue).joined(separator: ", ")
                if let name = chat.displayName, !name.isEmpty {
                    recipient = participants.isEmpty ? name : "\(name) (\(participants))"
                } else if !participants.isEmpty {
                    recipient = participants
                }
            }
            return MessageSendConfirmation(
                clientName: clientName,
                recipient: recipient,
                conversationID: id,
                service: request.serviceDescription,
                text: request.text
            )
        }
    }

    /// Rejects a known Automation denial before confirmation.
    /// Other results allow confirmation to proceed;
    /// macOS can ask for permission when the Apple event is sent.
    fileprivate static func checkAutomationPermission() throws {
        let target = NSAppleEventDescriptor(bundleIdentifier: messagesBundleIdentifier)
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            false
        )
        if status == errAEEventNotPermitted {
            throw SendError.notAuthorized
        }
    }

    /// Hands the message to Messages, off the main thread.
    fileprivate static func deliver(_ request: SendRequest) async throws {
        do {
            _ = try await NSAppleScript.execute(sendScriptSource, calling: request.handlerEvent)
        } catch let error as NSAppleScript.ExecutionError {
            throw SendError(error, request: request)
        }
    }

    enum SendError: LocalizedError, Equatable {
        case invalidArgument(String)
        case declined
        case timedOut
        case notAuthorized
        case unknownChat(String)
        case noAccountOrRecipient(String, SendService)
        case appleScript(number: Int?, message: String)

        /// Describes an error that AppleScript reports for a send.
        init(_ error: NSAppleScript.ExecutionError, request: SendRequest) {
            switch (error.number, request.destination) {
            case (Int(errAEEventNotPermitted), _):
                self = .notAuthorized
            case (Int(errAENoSuchObject), .chat(let id)):
                self = .unknownChat(id)
            case (Int(errAENoSuchObject), .recipient(let handle, let service)),
                (Int(errAEIllegalIndex), .recipient(let handle, let service)):
                self = .noAccountOrRecipient(handle, service)
            default:
                self = .appleScript(number: error.number, message: error.message)
            }
        }

        var errorDescription: String? {
            switch self {
            case .invalidArgument(let message):
                return "Invalid argument: \(message)"
            case .declined:
                return "The user declined to send the message in iMCP. Nothing was sent."
            case .timedOut:
                let seconds = MessageService.sendConfirmationTimeout.components.seconds
                return
                    "The send confirmation timed out after \(seconds) seconds. Nothing was sent."
            case .notAuthorized:
                return
                    "Allow iMCP to control Messages in System Settings > Privacy & Security > Automation. Nothing was sent."
            case .unknownChat(let id):
                return "Conversation \(id) wasn't found. Nothing was sent."
            case .noAccountOrRecipient(let handle, let service):
                return
                    "Messages couldn't find a signed-in \(service.rawValue) account or recipient \(handle). Nothing was sent."
            case .appleScript(let number, let message):
                let code = number.map { " (error \($0))" } ?? ""
                return "Messages reported a send error: \(message)\(code)"
            }
        }
    }
}

/// Packs four ASCII characters into an Apple event code.
private func fourCharCode(_ string: StaticString) -> FourCharCode {
    string.withUTF8Buffer { bytes in
        bytes.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
