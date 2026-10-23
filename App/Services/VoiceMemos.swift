import AppKit
import OSLog
import TSRP
import UniformTypeIdentifiers

private let log = Logger.service("voiceMemos")
private let recordingsBookmarkKey: String = "me.mattt.iMCP.voiceMemosRecordingsBookmark"
private let databaseFileName = "CloudRecordings.db"
private let defaultLimit = 30
private let defaultAudioMaxBytes = 25 * 1024 * 1024
private let maxAudioMaxBytes = 100 * 1024 * 1024

/// Reads recordings from the Voice Memos library on the Mac,
/// including recordings synced from other devices through iCloud.
///
/// [TSRP](https://github.com/mattt/TSRP) reads the library;
/// this service asks for access to it and describes the results.
final class VoiceMemosService: NSObject, Service, NSOpenSavePanelDelegate {
    static let shared = VoiceMemosService()

    func activate() async throws {
        log.debug("Starting voice memos service activation")
        try await requestRecordingsAccess()
        log.debug("Successfully activated voice memos service")
    }

    var isActivated: Bool {
        get async {
            var isActivated = canAccessStoreAtDefaultPath
            // Only probe the bookmark when one exists, so polling a Mac that has
            // not granted access yet does not log an error every time.
            if UserDefaults.standard.data(forKey: recordingsBookmarkKey) != nil {
                isActivated = isActivated || canAccessStoreUsingBookmark
            }
            log.debug("Voice memos service activation status: \(isActivated)")
            return isActivated
        }
    }

    var tools: [Tool] {
        Tool(
            name: "voice_memos_fetch",
            description:
                "Fetch recordings from Voice Memos, newest first, with their titles, folders, and durations",
            inputSchema: .object(
                properties: [
                    "query": .string(
                        description: "Text to match in recording titles, ignoring case and diacritics"
                    ),
                    "folder": .string(
                        description: "Name of a Voice Memos folder to read (case-insensitive)"
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
                    "recentlyDeleted": .boolean(
                        description:
                            "Fetch recordings from Recently Deleted instead of the library",
                        default: false
                    ),
                    "limit": .integer(
                        description: "Maximum recordings to return",
                        default: .int(defaultLimit),
                        minimum: 1
                    ),
                    "cursor": .string(
                        description: "The nextCursor value from a previous voice_memos_fetch, to fetch the next page"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Voice Memos",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            var request = TSRP.Recording.FetchRequest(
                limit: try self.argument("limit", in: arguments, as: \.intValue) ?? defaultLimit
            )
            guard request.limit >= 1 else {
                throw ArgumentError.invalid("limit must be a positive integer")
            }
            request.query = try self.argument("query", in: arguments, as: \.stringValue)
            if try self.argument("recentlyDeleted", in: arguments, as: \.boolValue) == true {
                request.scope = .recentlyDeleted
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
            if let cursor = try self.argument("cursor", in: arguments, as: \.stringValue) {
                guard let parsed = TSRP.Recording.FetchRequest.Cursor(cursor) else {
                    throw ArgumentError.invalid("cursor must be a nextCursor value from voice_memos_fetch")
                }
                request.cursor = parsed
            }
            let folderName = try self.argument("folder", in: arguments, as: \.stringValue)

            try await self.requestRecordingsAccess()
            return try await self.withStore { store in
                if let folderName {
                    request.folder = try await self.folderID(named: folderName, in: store)
                }
                let result = try await store.search(request)
                var items: [Value] = []
                for recording in result.recordings {
                    items.append(recording.value(file: await store.audioFile(for: recording)))
                }

                var list: [String: Value] = [
                    "@context": "https://schema.org",
                    "@type": "ItemList",
                    "name": "Voice Memos",
                    "numberOfItems": .int(items.count),
                    "itemListElement": .array(items),
                ]
                if let nextCursor = result.nextCursor {
                    list["nextCursor"] = .string(nextCursor.description)
                }
                return Value.object(list)
            }
        }

        Tool(
            name: "voice_memo_transcript_fetch",
            description: "Fetch the transcript that Voice Memos made of a recording",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Identifier of the recording, as returned by voice_memos_fetch"
                    ),
                    "timestamps": .boolean(
                        description:
                            "Include each transcribed word with its start and end time in seconds",
                        default: false
                    ),
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Voice Memo Transcript",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let id = try self.recordingIdentifier(from: arguments)
            let includesTimestamps =
                try self.argument("timestamps", in: arguments, as: \.boolValue) ?? false
            try await self.requestRecordingsAccess()

            let transcript = try await self.withStore { store -> TSRP.Transcript in
                let recording = try await store.recording(for: id)
                guard let transcript = try await store.transcript(for: recording) else {
                    throw RecordingError.notTranscribed(id)
                }
                return transcript
            }

            var object: [String: Value] = [
                "@id": .string(id.description),
                "text": .string(transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)),
            ]
            if let locale = transcript.locale {
                object["inLanguage"] = .string(locale.identifier(.bcp47))
            }
            if includesTimestamps {
                object["segment"] = .array(transcript.segments.compactMap(\.value))
            }
            return Value.object(object)
        }

        Tool(
            name: "voice_memo_audio_fetch",
            description: "Fetch the audio of a Voice Memos recording",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Identifier of the recording, as returned by voice_memos_fetch"
                    ),
                    "maxBytes": .integer(
                        description: "Refuse audio files larger than this",
                        default: .int(defaultAudioMaxBytes),
                        minimum: 1,
                        maximum: maxAudioMaxBytes
                    ),
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Voice Memo Audio",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let id = try self.recordingIdentifier(from: arguments)
            let maxBytes =
                try self.argument("maxBytes", in: arguments, as: \.intValue) ?? defaultAudioMaxBytes
            guard maxBytes >= 1, maxBytes <= maxAudioMaxBytes else {
                throw ArgumentError.invalid("maxBytes must be between 1 and \(maxAudioMaxBytes)")
            }
            try await self.requestRecordingsAccess()

            let audio = try await self.withStore { store -> (mimeType: String, data: Data) in
                let recording = try await store.recording(for: id)
                guard let file = await store.audioFile(for: recording) else {
                    throw TSRP.VoiceMemosError.audioFileNotFound(id)
                }
                guard let mimeType = file.playableMIMEType else {
                    throw RecordingError.unsupportedFormat(id, file.url.pathExtension)
                }
                guard file.size <= maxBytes else {
                    throw RecordingError.tooLarge(id, file.size, maxBytes)
                }
                return (mimeType, try Data(contentsOf: file.url))
            }
            return Value.data(mimeType: audio.mimeType, audio.data)
        }
    }

    // MARK: - Recordings Access

    /// The `Recordings` folder at its default location.
    private var defaultRecordingsDirectory: URL {
        TSRP.Store.defaultRoot
    }

    /// Ensures the Voice Memos library is readable, asking the user to grant access if needed.
    ///
    /// The grant has to cover the `Recordings` folder, not just the database file.
    /// The library is a WAL-mode SQLite database, so SQLite also opens the `-wal` and
    /// `-shm` files next to it, and the audio files, which hold the transcripts,
    /// sit beside the database. A bookmark on the file alone would leave them unreadable.
    private func requestRecordingsAccess() async throws {
        if canAccessStoreAtDefaultPath {
            log.debug("Using voice memos library at default path")
            return
        }

        if canAccessStoreUsingBookmark {
            log.debug("Using voice memos library from stored bookmark")
            return
        }

        log.debug("Opening folder picker for manual voice memos library selection")
        guard try await showRecordingsAccessAlert() else {
            throw RecordingsAccessError.userDeclinedAccess
        }

        guard let selectedURL = try await showFolderPicker() else {
            // Dismissing the picker is the same answer as Cancel on the alert.
            throw RecordingsAccessError.userDeclinedAccess
        }

        guard FileManager.default.isReadableFile(atPath: databaseURL(in: selectedURL).path) else {
            throw RecordingsAccessError.fileNotReadable
        }

        try storeBookmark(for: selectedURL)
        log.debug("Granted access to voice memos library")
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

    /// The recording identifier passed as the `id` argument,
    /// as the string that voice_memos_fetch returns or as an integer.
    private func recordingIdentifier(from arguments: [String: Value]) throws -> TSRP.Recording.ID {
        if let identifier = arguments["id"]?.stringValue, let id = TSRP.Recording.ID(identifier) {
            return id
        }
        if let id = arguments["id"]?.intValue {
            return TSRP.Recording.ID(rawValue: Int64(id))
        }
        throw ArgumentError.invalid("id must be the identifier of a recording")
    }

    /// The identifier of the folder with a name, ignoring case and diacritics.
    private func folderID(named name: String, in store: TSRP.Store) async throws -> TSRP.Folder.ID {
        let folders = try await store.folders()
        let match = folders.first {
            $0.name?.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        guard let match else {
            throw RecordingError.folderNotFound(name, folders.compactMap(\.name))
        }
        return match.id
    }

    private var canAccessStoreAtDefaultPath: Bool {
        return FileManager.default.isReadableFile(atPath: databaseURL(in: defaultRecordingsDirectory).path)
    }

    private var canAccessStoreUsingBookmark: Bool {
        do {
            let url = try resolveBookmarkedRecordingsDirectory()
            return try withSecurityScopedAccess(url) { _ in
                FileManager.default.isReadableFile(atPath: databaseURL(in: url).path)
            }
        } catch {
            log.error(
                "Error accessing voice memos library with bookmark: \(error.localizedDescription)"
            )
            return false
        }
    }

    private func databaseURL(in directory: URL) -> URL {
        return directory.appendingPathComponent(databaseFileName)
    }

    private func resolveBookmarkedRecordingsDirectory() throws -> URL {
        guard
            let bookmarkData = UserDefaults.standard.data(forKey: recordingsBookmarkKey)
        else {
            throw RecordingsAccessError.noBookmarkFound
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
            throw RecordingsAccessError.securityScopeAccessFailed
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try operation(url)
    }

    /// Runs an operation on a store for the library at the default path,
    /// or inside the grant for the bookmarked folder.
    ///
    /// Each store call finishes its database and file work before it returns,
    /// so the grant must stay open until the operation returns.
    /// Errors from TSRP are rethrown as `StoreError`, which describes them for the client.
    private func withStore<T>(_ operation: (TSRP.Store) async throws -> T) async throws -> T {
        do {
            if canAccessStoreAtDefaultPath {
                return try await operation(TSRP.Store(root: defaultRecordingsDirectory))
            }

            let directory = try resolveBookmarkedRecordingsDirectory()
            guard directory.startAccessingSecurityScopedResource() else {
                log.error("Failed to start accessing security-scoped resource")
                throw RecordingsAccessError.securityScopeAccessFailed
            }
            defer { directory.stopAccessingSecurityScopedResource() }
            return try await operation(TSRP.Store(root: directory))
        } catch let error as TSRP.VoiceMemosError {
            throw StoreError(underlying: error)
        }
    }

    // MARK: - Errors

    // The server reports a tool's error by interpolating it,
    // so each error type describes itself with its readable message.
    private enum RecordingsAccessError: LocalizedError, CustomStringConvertible {
        case noBookmarkFound
        case securityScopeAccessFailed
        case userDeclinedAccess
        case invalidFolderSelected
        case fileNotReadable

        var description: String { localizedDescription }

        var errorDescription: String? {
            switch self {
            case .noBookmarkFound:
                return "No stored bookmark found for Voice Memos library access"
            case .securityScopeAccessFailed:
                return "Failed to access security-scoped resource"
            case .userDeclinedAccess:
                return "User declined to grant access to the Voice Memos library"
            case .invalidFolderSelected:
                return
                    "Voice Memos library access denied or the selection is not the Recordings folder"
            case .fileNotReadable:
                return "The selected folder has no readable \(databaseFileName)"
            }
        }
    }

    private enum ArgumentError: LocalizedError, CustomStringConvertible {
        case invalid(String)

        var description: String { localizedDescription }

        var errorDescription: String? {
            switch self {
            case .invalid(let message):
                return "Invalid argument: \(message)"
            }
        }
    }

    private enum RecordingError: LocalizedError, CustomStringConvertible {
        case folderNotFound(String, [String])
        case notTranscribed(TSRP.Recording.ID)
        case unsupportedFormat(TSRP.Recording.ID, String)
        case tooLarge(TSRP.Recording.ID, Int, Int)

        var description: String { localizedDescription }

        var errorDescription: String? {
            switch self {
            case .folderNotFound(let name, let names):
                let available =
                    names.isEmpty ? "there are no folders" : "the folders are \(names.joined(separator: ", "))"
                return "No Voice Memos folder is named \(name); \(available)"
            case .notTranscribed(let id):
                return
                    "The recording with identifier \(id) has no transcript; open the recording in Voice Memos and show its transcript to create one"
            case .unsupportedFormat(let id, let fileExtension):
                return
                    "The audio of the recording with identifier \(id) is in a format this tool does not return (\(fileExtension.isEmpty ? "unknown" : fileExtension))"
            case .tooLarge(let id, let size, let maxBytes):
                return
                    "The audio of the recording with identifier \(id) is \(size) bytes, which is more than maxBytes (\(maxBytes))"
            }
        }
    }

    /// An error from TSRP, with a description for the client.
    /// TSRP's errors conform only to `LocalizedError`,
    /// so interpolating one would show its case name instead of its message.
    private struct StoreError: LocalizedError, CustomStringConvertible {
        let underlying: TSRP.VoiceMemosError

        var description: String { localizedDescription }

        var errorDescription: String? {
            switch underlying {
            case .storeNotFound:
                return
                    "The selected folder has no Voice Memos library; switch Voice Memos off and on in the iMCP menu and select the Recordings folder"
            case .storeNotReadable:
                return
                    "The Voice Memos library or its write-ahead log files cannot be read; switch Voice Memos off and on in the iMCP menu to grant the Recordings folder again"
            case .audioFileNotFound(let id):
                return
                    "The audio file of the recording with identifier \(id) is not on this Mac; open the recording in Voice Memos to download it"
            case .invalidLimit:
                return "Invalid argument: \(underlying.localizedDescription)"
            default:
                return underlying.localizedDescription
            }
        }
    }

    // MARK: - UI

    @MainActor
    private func showRecordingsAccessAlert() async throws -> Bool {
        let alert = NSAlert()
        alert.messageText = "Voice Memos Access Required"
        alert.informativeText = """
            To read your voice memos, we need access to their Recordings folder: \
            the database, its write-ahead log, and the audio files next to it.

            In the next screen, please select the `Recordings` folder and click "Grant Access".
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
            "Please select your Voice Memos folder (~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings)"
        openPanel.prompt = "Grant Access"
        openPanel.directoryURL = defaultRecordingsDirectory.deletingLastPathComponent()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.showsHiddenFiles = true

        guard openPanel.runModal() == .OK, let url = openPanel.url else {
            return nil
        }
        guard isRecordingsDirectory(url) else {
            throw RecordingsAccessError.invalidFolderSelected
        }

        return url
    }

    private func storeBookmark(for url: URL) throws {
        let bookmarkData = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmarkData, forKey: recordingsBookmarkKey)
        log.debug("Successfully created and stored bookmark")
    }

    private func isRecordingsDirectory(_ url: URL) -> Bool {
        return url.lastPathComponent == "Recordings"
    }

    // NSOpenSavePanelDelegate method to constrain the selection to the Recordings folder
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let shouldEnable = isRecordingsDirectory(url)
        log.debug(
            "File selection panel: \(shouldEnable ? "enabling" : "disabling") URL: \(url.path)"
        )
        return shouldEnable
    }
}

// MARK: -

extension TSRP.Recording {
    /// The recording as a JSON object for tool output, with what its audio file adds.
    func value(file: TSRP.AudioFile?) -> Value {
        let duration = (self.duration ?? 0) > 0 ? self.duration : file?.duration
        var object: [String: Value] = [
            "@id": .string(id.description),
            "hasAudio": .bool(file?.playableMIMEType != nil),
        ]
        if let title {
            object["title"] = .string(title)
        }
        if let date {
            object["date"] = .string(date.formatted(.iso8601))
        }
        // A damaged file or database can hold a duration too large for an integer.
        if let duration, let totalSeconds = Int(exactly: duration.rounded()) {
            let hours = totalSeconds / 3600
            let minutes = totalSeconds % 3600 / 60
            let seconds = totalSeconds % 60
            if hours > 0 {
                object["duration"] = .string("\(hours)h \(minutes)m \(seconds)s")
            } else if minutes > 0 {
                object["duration"] = .string("\(minutes)m \(seconds)s")
            } else {
                object["duration"] = .string("\(seconds)s")
            }
            object["durationSeconds"] = .double((duration * 10).rounded() / 10)
        }
        if let name = folder?.name {
            object["folder"] = .string(name)
        }
        // Without the audio file, whether a transcript exists is unknown.
        if let file {
            object["transcribed"] = .bool(file.hasTranscript)
        }
        if let deletionDate {
            object["dateDeleted"] = .string(deletionDate.formatted(.iso8601))
        }
        return .object(object)
    }
}

extension TSRP.AudioFile {
    /// The MIME type to send the audio with, when it is a format clients can play.
    ///
    /// MPEG-4 audio uses `audio/mp4`, the registered type, rather than the
    /// `audio/x-m4a` that macOS declares; QuickTime audio has no registered type,
    /// so it uses the one that macOS declares, `audio/x-quicktime`.
    var playableMIMEType: String? {
        if contentType?.conforms(to: .mpeg4Audio) == true {
            return "audio/mp4"
        }
        return mimeType
    }
}

extension TSRP.Transcript.Segment {
    /// The segment as a JSON object for tool output, or nil for a run of spaces.
    var value: Value? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var object: [String: Value] = ["text": .string(text)]
        if let timeRange {
            object["start"] = .double(timeRange.lowerBound)
            object["end"] = .double(timeRange.upperBound)
        }
        return .object(object)
    }
}
