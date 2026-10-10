import AppKit
import OSLog

private let log = Logger.service("voicemail")
private let dataStoreDirectoryPath =
    "/Users/\(NSUserName())/Library/Group Containers/group.com.apple.FaceTime/com.apple.facetimemessagestored/Data Store"
private let dataStoreBookmarkKey: String = "me.mattt.iMCP.voicemailDataStoreBookmark"
private let defaultLimit = 30

/// Reads voicemails synced to the Mac by the Phone app on macOS 26 and later,
/// including FaceTime audio and video messages.
final class VoicemailService: NSObject, Service, NSOpenSavePanelDelegate {
    static let shared = VoicemailService()

    /// Whether this Mac can run the Phone app that creates the voicemail store
    /// (macOS 26 and later). The app sandbox hides the store until access is granted,
    /// so registration cannot rely on the store being present at the default path;
    /// activation requests the grant instead.
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private static var defaultDatabasePath: String {
        dataStoreDirectoryPath + "/" + VoicemailStore.databaseFileName
    }

    func activate() async throws {
        log.debug("Starting voicemail service activation")
        try await requestDataStoreAccess()
        log.debug("Successfully activated voicemail service")
    }

    var isActivated: Bool {
        get async {
            var isActivated = canAccessStoreAtDefaultPath
            // Only probe the bookmark when one exists, so polling a Mac that has
            // not granted access yet does not log an error every time.
            if UserDefaults.standard.data(forKey: dataStoreBookmarkKey) != nil {
                isActivated = isActivated || canAccessStoreUsingBookmark
            }
            log.debug("Voicemail service activation status: \(isActivated)")
            return isActivated
        }
    }

    var tools: [Tool] {
        Tool(
            name: "voicemails_fetch",
            description:
                "Fetch voicemails from the Mac (synced from iPhone, including FaceTime audio messages)",
            inputSchema: .object(
                properties: [
                    "sender": .string(
                        description:
                            "Phone number or address to filter by (partial match supported)"
                    ),
                    "start": .string(
                        description:
                            "Start of the date range (inclusive). ISO 8601 format. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End of the date range (exclusive). ISO 8601 format. If timezone is omitted, local time is assumed. A date-only value includes that whole day.",
                        format: .dateTime
                    ),
                    "type": .string(
                        description: "Filter by message type, or omit for all",
                        enum: ["carrierVoicemail", "faceTimeAudio", "faceTimeVideo"]
                    ),
                    "limit": .integer(
                        description: "Maximum voicemails to return",
                        default: .int(defaultLimit),
                        minimum: 1
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Voicemails",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let limit = try self.argument("limit", in: arguments, as: \.intValue) ?? defaultLimit
            guard limit >= 1 else {
                throw ArgumentError.invalid("limit must be a positive integer")
            }
            var request = VoicemailMessage.FetchRequest(limit: limit)
            request.sender = try self.argument("sender", in: arguments, as: \.stringValue)
            if let type = try self.argument("type", in: arguments, as: \.stringValue) {
                guard let kind = VoicemailMessage.Kind(rawValue: type) else {
                    throw ArgumentError.invalid(
                        "type must be one of: carrierVoicemail, faceTimeAudio, faceTimeVideo"
                    )
                }
                request.kind = kind
            }
            if let start = try self.argument("start", in: arguments, as: \.stringValue) {
                guard
                    let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: start
                    )
                else {
                    throw ArgumentError.invalid("start must be an ISO 8601 date")
                }
                request.startDate = Calendar.current.normalizedStartDate(
                    from: parsed.date,
                    isDateOnly: parsed.isDateOnly
                )
            }
            if let end = try self.argument("end", in: arguments, as: \.stringValue) {
                guard
                    let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: end
                    )
                else {
                    throw ArgumentError.invalid("end must be an ISO 8601 date")
                }
                request.endDate = Calendar.current.normalizedEndDate(
                    from: parsed.date,
                    isDateOnly: parsed.isDateOnly
                )
            }

            try await self.requestDataStoreAccess()
            let voicemails = try self.withStore { try $0.fetch(request) }

            return [
                "@context": "https://schema.org",
                "@type": "ItemList",
                "name": "Voicemails",
                "numberOfItems": .int(voicemails.count),
                "itemListElement": Value.array(voicemails.map(\.value)),
            ]
        }

        Tool(
            name: "voicemail_transcript_fetch",
            description: "Fetch the transcript of a voicemail",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Identifier of the voicemail, as returned by voicemails_fetch"
                    )
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Voicemail Transcript",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let id = try self.messageIdentifier(from: arguments)
            try await self.requestDataStoreAccess()

            let transcript = try self.withStore { store -> VoicemailTranscript? in
                guard try store.message(id: id) != nil else {
                    throw TranscriptError.notFound(id)
                }
                return try store.transcript(id: id)
            }
            guard let transcript else {
                throw TranscriptError.notTranscribed(id)
            }

            var object: [String: Value] = [
                "@id": .string(String(id)),
                "text": .string(transcript.text),
            ]
            if let confidence = transcript.confidence {
                object["confidence"] = .double(confidence)
            }
            if !transcript.segments.isEmpty {
                object["segment"] = Value.array(transcript.segments.map(\.value))
            }
            return Value.object(object)
        }

        Tool(
            name: "voicemail_audio_fetch",
            description:
                "Fetch the audio of a voicemail (carrier voicemails and FaceTime audio messages)",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Identifier of the voicemail, as returned by voicemails_fetch"
                    )
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Voicemail Audio",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let id = try self.messageIdentifier(from: arguments)
            try await self.requestDataStoreAccess()

            let audio = try self.withStore { store -> (mimeType: String, data: Data)? in
                guard let message = try store.message(id: id) else {
                    return nil
                }
                guard let mimeType = store.audioMimeType(for: message) else {
                    throw AudioError.unsupportedFileType(id)
                }
                guard let data = try store.audioData(for: message) else {
                    throw AudioError.audioMissing(id)
                }
                return (mimeType, data)
            }
            guard let audio else {
                throw AudioError.notFound(id)
            }
            return Value.data(mimeType: audio.mimeType, audio.data)
        }
    }

    // MARK: - Data Store Access

    /// Ensures the voicemail store is readable, asking the user to grant access if needed.
    ///
    /// The grant has to cover the `Data Store` folder, not just the database file.
    /// The store is a WAL-mode SQLite database, so SQLite also opens the `-wal` and
    /// `-shm` files next to it, and the message audio lives in the `Assets` tree
    /// beside the database. A bookmark on the file alone would leave both unreadable.
    private func requestDataStoreAccess() async throws {
        if canAccessStoreAtDefaultPath {
            log.debug("Using voicemail store at default path")
            return
        }

        if canAccessStoreUsingBookmark {
            log.debug("Using voicemail store from stored bookmark")
            return
        }

        log.debug("Opening folder picker for manual voicemail store selection")
        guard try await showDataStoreAccessAlert() else {
            throw DataStoreAccessError.userDeclinedAccess
        }

        guard let selectedURL = try await showFolderPicker() else {
            // Dismissing the picker is the same answer as Cancel on the alert.
            throw DataStoreAccessError.userDeclinedAccess
        }

        guard FileManager.default.isReadableFile(atPath: databaseURL(in: selectedURL).path) else {
            throw DataStoreAccessError.fileNotReadable
        }

        try storeBookmark(for: selectedURL)
        log.debug("Granted access to voicemail store")
    }

    /// Returns an optional argument, or throws if it is present with the wrong type.
    private func argument<T>(
        _ name: String,
        in arguments: [String: Value],
        as transform: (Value) -> T?
    ) throws -> T? {
        guard let value = arguments[name], !value.isNull else { return nil }
        guard let result = transform(value) else {
            throw ArgumentError.invalid("\(name) has the wrong type")
        }
        return result
    }

    /// The numeric record identifier passed as the `id` argument.
    private func messageIdentifier(from arguments: [String: Value]) throws -> Int {
        guard let identifier = arguments["id"]?.stringValue, let id = Int(identifier) else {
            throw ArgumentError.invalid("id must be the identifier of a voicemail")
        }
        return id
    }

    private var canAccessStoreAtDefaultPath: Bool {
        return FileManager.default.isReadableFile(atPath: VoicemailService.defaultDatabasePath)
    }

    private var canAccessStoreUsingBookmark: Bool {
        do {
            let url = try resolveBookmarkedStoreDirectory()
            return try withSecurityScopedAccess(url) { _ in
                FileManager.default.isReadableFile(atPath: databaseURL(in: url).path)
            }
        } catch {
            log.error(
                "Error accessing voicemail store with bookmark: \(error.localizedDescription)"
            )
            return false
        }
    }

    private func databaseURL(in directory: URL) -> URL {
        return directory.appendingPathComponent(VoicemailStore.databaseFileName)
    }

    private func resolveBookmarkedStoreDirectory() throws -> URL {
        guard
            let bookmarkData = UserDefaults.standard.data(forKey: dataStoreBookmarkKey)
        else {
            throw DataStoreAccessError.noBookmarkFound
        }

        var isStale = false
        return try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private func withSecurityScopedAccess<T>(_ url: URL, _ operation: (URL) throws -> T) throws -> T {
        guard url.startAccessingSecurityScopedResource() else {
            log.error("Failed to start accessing security-scoped resource")
            throw DataStoreAccessError.securityScopeAccessFailed
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try operation(url)
    }

    private func withStore<T>(_ operation: (VoicemailStore) throws -> T) throws -> T {
        if canAccessStoreAtDefaultPath {
            return try operation(VoicemailStore(directoryPath: dataStoreDirectoryPath))
        }

        let directory = try resolveBookmarkedStoreDirectory()

        // The grant must stay open until the last read:
        // SQLite opens the write-ahead log lazily on the first statement.
        return try withSecurityScopedAccess(directory) { url in
            try operation(VoicemailStore(directoryPath: url.path))
        }
    }

    // MARK: - Errors

    private enum DataStoreAccessError: LocalizedError {
        case noBookmarkFound
        case securityScopeAccessFailed
        case userDeclinedAccess
        case invalidFolderSelected
        case fileNotReadable

        var errorDescription: String? {
            switch self {
            case .noBookmarkFound:
                return "No stored bookmark found for voicemail store access"
            case .securityScopeAccessFailed:
                return "Failed to access security-scoped resource"
            case .userDeclinedAccess:
                return "User declined to grant access to the voicemail store"
            case .invalidFolderSelected:
                return
                    "Voicemail store access denied or the selection is not the Data Store folder"
            case .fileNotReadable:
                return "The selected folder has no readable \(VoicemailStore.databaseFileName)"
            }
        }
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

    private enum TranscriptError: LocalizedError {
        case notFound(Int)
        case notTranscribed(Int)

        var errorDescription: String? {
            switch self {
            case .notFound(let id):
                return "No voicemail found with identifier \(id)"
            case .notTranscribed(let id):
                return
                    "The voicemail with identifier \(id) has no transcript; its audio is available from voicemail_audio_fetch"
            }
        }
    }

    private enum AudioError: LocalizedError {
        case notFound(Int)
        case unsupportedFileType(Int)
        case audioMissing(Int)

        var errorDescription: String? {
            switch self {
            case .notFound(let id):
                return "No voicemail found with identifier \(id)"
            case .unsupportedFileType(let id):
                return
                    "The message with identifier \(id) is a video message, which this tool does not return; only carrier voicemails and FaceTime audio messages do"
            case .audioMissing(let id):
                return
                    "The audio file of the voicemail with identifier \(id) is missing from the store"
            }
        }
    }

    // MARK: - UI

    @MainActor
    private func showDataStoreAccessAlert() async throws -> Bool {
        let alert = NSAlert()
        alert.messageText = "Voicemail Store Access Required"
        alert.informativeText = """
            To read your voicemails, we need access to their Data Store folder: \
            the database, its write-ahead log, and the audio files next to it.

            In the next screen, please select the `Data Store` folder and click "Grant Access".
            """
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
        openPanel.message =
            "Please select your voicemail folder (~/Library/Group Containers/group.com.apple.FaceTime/com.apple.facetimemessagestored/Data Store)"
        openPanel.prompt = "Grant Access"
        openPanel.directoryURL = URL(fileURLWithPath: dataStoreDirectoryPath)
            .deletingLastPathComponent()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.showsHiddenFiles = true

        guard openPanel.runModal() == .OK, let url = openPanel.url else {
            return nil
        }
        guard isDataStoreDirectory(url) else {
            throw DataStoreAccessError.invalidFolderSelected
        }

        return url
    }

    private func storeBookmark(for url: URL) throws {
        let bookmarkData = try url.bookmarkData(
            options: .securityScopeAllowOnlyReadAccess,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmarkData, forKey: dataStoreBookmarkKey)
        log.debug("Successfully created and stored bookmark")
    }

    private func isDataStoreDirectory(_ url: URL) -> Bool {
        return url.lastPathComponent == "Data Store"
    }

    // NSOpenSavePanelDelegate method to constrain the selection to the Data Store folder
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let shouldEnable = isDataStoreDirectory(url)
        log.debug(
            "File selection panel: \(shouldEnable ? "enabling" : "disabling") URL: \(url.path)"
        )
        return shouldEnable
    }
}

// MARK: -

extension VoicemailMessage {
    /// The record as a JSON object for tool output.
    var value: Value {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        var object: [String: Value] = [
            "@id": .string(String(id)),
            "sender": .string(sender ?? "Unknown"),
            "date": .string(date.formatted(.iso8601)),
            "duration": .string(minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"),
            "durationSeconds": .double(duration),
            "isRead": .bool(isRead),
            "transcribed": .bool(hasTranscript),
            "hasAudio": .bool(hasAudio),
        ]
        if let kind {
            object["type"] = .string(kind.rawValue)
        }
        return .object(object)
    }
}

extension VoicemailTranscript.Segment {
    /// The segment as a JSON object for tool output.
    var value: Value {
        var object: [String: Value] = [
            "text": .string(text)
        ]
        if let confidence {
            object["confidence"] = .double(confidence)
        }
        return .object(object)
    }
}
