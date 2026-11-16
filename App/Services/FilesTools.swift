import Foundation
import MCP

/// One shared folder, as the roots tool reports it.
struct FilesRootStatus: Sendable, Equatable {
    enum State: String, Sendable {
        /// The folder resolved and can be used.
        case available
        /// The grant no longer resolves, so the person has to add the folder again.
        case needsReAdd = "needs-re-add"
    }

    var name: String
    var path: String?
    var state: State
}

/// Where the Files tools get the folders that the person shared.
///
/// The app reads them from the bookmarks that it stores; tests use fixed folders.
protocol FilesRootProviding: Sendable {
    func statuses() -> [FilesRootStatus]
    /// Runs `body` while the folders are open for access, and closes them afterwards.
    func withAccess<T>(_ body: (FilesAccess) throws -> T) throws -> T
}

/// The tools that read, search, and change the folders that the person shared.
///
/// The tools that change files are the service's write tools:
/// `ServiceWrites` lists them only while \"Allow writes\" is on, and each checks the setting again when it runs.
enum FilesTools {
    static let readToolNames: Set<String> = ["files_roots", "files_list", "files_stat", "files_read", "files_search"]
    static let writeToolNames: Set<String> = [
        "files_write", "files_append", "files_mkdir", "files_move", "files_trash",
    ]

    /// Throws unless `isEnabled`, so that a tool changes nothing while "Allow writes" is off.
    /// `ServiceWrites` refuses the call first; this keeps the tools safe where they are called directly.
    static func requireEnabled(_ isEnabled: Bool, tool: String) throws {
        guard isEnabled else { throw WritesDisabledError(tool: tool) }
    }

    // MARK: - Arguments

    static func requiredString(_ name: String, in arguments: [String: Value]) throws -> String {
        guard let value = try string(name, in: arguments), !value.isEmpty else {
            throw FilesError.invalidArgument("\(name) is required")
        }
        return value
    }

    static func string(_ name: String, in arguments: [String: Value]) throws -> String? {
        guard let value = arguments[name], !value.isNull else { return nil }
        guard let string = value.stringValue else { throw FilesError.invalidArgument("\(name) must be a string") }
        return string
    }

    static func bool(_ name: String, in arguments: [String: Value]) throws -> Bool? {
        guard let value = arguments[name], !value.isNull else { return nil }
        guard let bool = value.boolValue else { throw FilesError.invalidArgument("\(name) must be true or false") }
        return bool
    }

    static func int(_ name: String, in arguments: [String: Value], default fallback: Int, range: ClosedRange<Int>)
        throws -> Int
    {
        guard let value = arguments[name], !value.isNull else { return fallback }
        guard let int = value.intValue else { throw FilesError.invalidArgument("\(name) must be an integer") }
        guard range.contains(int) else {
            throw FilesError.invalidArgument("\(name) must be \(range.lowerBound) through \(range.upperBound)")
        }
        return int
    }

    /// How long a search may run, in seconds, kept within its limits.
    static func timeBudget(in arguments: [String: Value]) throws -> Double {
        guard let value = arguments["timeBudgetSeconds"], !value.isNull else { return FilesLimits.defaultSearchSeconds }
        guard let number = value.doubleValue ?? value.intValue.map(Double.init) else {
            throw FilesError.invalidArgument("timeBudgetSeconds must be a number")
        }
        return min(max(number, 1), FilesLimits.maximumSearchSeconds)
    }

    /// The precondition that a write passes, from its two optional arguments.
    static func precondition(in arguments: [String: Value]) throws -> FilesOperations.Precondition {
        var precondition = FilesOperations.Precondition()
        if let text = try string("expectedModified", in: arguments) {
            guard let date = FilesDate.parse(text) else {
                throw FilesError.invalidArgument(
                    "expectedModified must be a date like \"2026-11-16T09:30:00.250Z\", as files_stat returns it"
                )
            }
            precondition.modified = date
        }
        if let hash = try string("expectedSha256", in: arguments) {
            precondition.sha256 = hash.lowercased()
        }
        return precondition
    }

    /// Runs file system work off the cooperative threads, since a search can take a while.
    private static func run<T: Sendable>(
        _ provider: any FilesRootProviding,
        _ body: @escaping @Sendable (FilesAccess) throws -> T
    ) async throws -> T {
        try await Task.detached { try provider.withAccess(body) }.value
    }

    // MARK: - Tools

    static func tools(
        provider: any FilesRootProviding,
        isEnabled: @escaping @Sendable () -> Bool
    ) -> [Tool] {
        readTools(provider: provider, isEnabled: isEnabled) + writeTools(provider: provider, isEnabled: isEnabled)
    }

    private static let pathDescription =
        "The shared folder's name, then the path inside it, such as \"Documents/Taxes/2025.pdf\". Shared folders are listed by files_roots"

    static func readTools(provider: any FilesRootProviding, isEnabled: @escaping @Sendable () -> Bool) -> [Tool] {
        [
            Tool(
                name: "files_roots",
                description:
                    "List the folders that the person shared with iMCP, and whether each can be used. Every other Files tool takes a path that starts with one of these names. Also says whether changing files is allowed (\"Allow writes\" in Files settings).",
                inputSchema: .object(properties: [:], additionalProperties: false),
                annotations: .init(title: "List Shared Folders", readOnlyHint: true, openWorldHint: false)
            ) { _ in
                let statuses = provider.statuses()
                var folders: [Value] = []
                for status in statuses {
                    var folder: [String: Value] = [
                        "name": .string(status.name),
                        "status": .string(status.state.rawValue),
                    ]
                    if let path = status.path { folder["path"] = .string(path) }
                    folders.append(.object(folder))
                }
                return [
                    "folders": .array(folders),
                    "changesAllowed": .bool(isEnabled()),
                ] as Value
            },

            Tool(
                name: "files_list",
                description:
                    "List the files and folders directly inside a folder, sorted by name, a page at a time. Hidden files (names that start with a dot) are left out unless includeHidden is true. The result has nextOffset when there are more entries: pass it as offset to get them.",
                inputSchema: .object(
                    properties: [
                        "path": .string(description: pathDescription),
                        "glob": .string(
                            description: "Only names that match this pattern, ignoring case, such as \"*.md\""
                        ),
                        "includeHidden": .boolean(description: "Include hidden files", default: false),
                        "limit": .integer(
                            description: "Entries per page",
                            default: .int(FilesLimits.defaultListLimit),
                            minimum: 1,
                            maximum: FilesLimits.maximumListLimit
                        ),
                        "offset": .integer(description: "Entries to skip, from nextOffset", default: 0, minimum: 0),
                    ],
                    required: ["path"],
                    additionalProperties: false
                ),
                annotations: .init(title: "List Files", readOnlyHint: true, openWorldHint: false)
            ) { arguments in
                let path = try requiredString("path", in: arguments)
                let glob = try string("glob", in: arguments)
                let includeHidden = try bool("includeHidden", in: arguments) ?? false
                let limit = try int(
                    "limit",
                    in: arguments,
                    default: FilesLimits.defaultListLimit,
                    range: 1 ... FilesLimits.maximumListLimit
                )
                let offset = try int("offset", in: arguments, default: 0, range: 0 ... Int.max)
                return try await run(provider) { access in
                    try FilesOperations.list(
                        try access.resolve(path),
                        glob: glob,
                        includeHidden: includeHidden,
                        offset: offset,
                        limit: limit
                    )
                }
            },

            Tool(
                name: "files_stat",
                description:
                    "Describe a file or folder: its type, size, and dates. The modified date is what files_write takes as expectedModified; includeHash adds the SHA-256 that it takes as expectedSha256.",
                inputSchema: .object(
                    properties: [
                        "path": .string(description: pathDescription),
                        "includeHash": .boolean(
                            description:
                                "Include the SHA-256 of a file's content, for files up to \(FilesLimits.maximumHashBytes) bytes",
                            default: false
                        ),
                    ],
                    required: ["path"],
                    additionalProperties: false
                ),
                annotations: .init(title: "Describe File", readOnlyHint: true, openWorldHint: false)
            ) { arguments in
                let path = try requiredString("path", in: arguments)
                let includeHash = try bool("includeHash", in: arguments) ?? false
                return try await run(provider) { access in
                    let item = try access.resolve(path)
                    let link = try access.resolve(path, followingFinalSymlink: false)
                    let isSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.url.path)) != nil
                    return try FilesOperations.stat(item, isSymlink: isSymlink, includeHash: includeHash)
                }
            },

            Tool(
                name: "files_read",
                description:
                    "Read a file. Text comes back as text, decoded from UTF-8, UTF-16, or Windows text, up to maxBytes at a time: when truncated is true, pass nextOffset as offset for the next part. A binary file comes back as base64 if it is no larger than \(FilesLimits.maximumBinaryBytes) bytes, and is refused otherwise unless format is \"base64\", which returns it in pieces of up to \(FilesLimits.maximumBinaryBytes) bytes.",
                inputSchema: .object(
                    properties: [
                        "path": .string(description: pathDescription),
                        "format": .string(
                            description:
                                "auto reads text as text and binary as base64; text refuses a binary file; base64 returns the raw bytes",
                            default: .string(FilesOperations.ReadFormat.auto.rawValue),
                            enum: FilesOperations.ReadFormat.allCases.map { .string($0.rawValue) }
                        ),
                        "maxBytes": .integer(
                            description: "The most bytes to read in this call",
                            default: .int(FilesLimits.defaultReadBytes),
                            minimum: 1,
                            maximum: FilesLimits.maximumReadBytes
                        ),
                        "offset": .integer(
                            description: "The byte to start at, from nextOffset of a truncated read",
                            default: 0,
                            minimum: 0
                        ),
                    ],
                    required: ["path"],
                    additionalProperties: false
                ),
                annotations: .init(title: "Read File", readOnlyHint: true, openWorldHint: false)
            ) { arguments in
                let path = try requiredString("path", in: arguments)
                let formatName = try string("format", in: arguments) ?? FilesOperations.ReadFormat.auto.rawValue
                guard let format = FilesOperations.ReadFormat(rawValue: formatName) else {
                    throw FilesError.invalidArgument("format must be auto, text, or base64")
                }
                let maxBytes = try int(
                    "maxBytes",
                    in: arguments,
                    default: FilesLimits.defaultReadBytes,
                    range: 1 ... FilesLimits.maximumReadBytes
                )
                let offset = try int("offset", in: arguments, default: 0, range: 0 ... Int.max)
                return try await run(provider) { access in
                    try FilesOperations.read(
                        try access.resolve(path),
                        offset: offset,
                        maxBytes: maxBytes,
                        format: format
                    )
                }
            },

            Tool(
                name: "files_search",
                description:
                    "Search the shared folders for files by name, and optionally for text inside them. A name with * ? or [ is a glob; any other name matches a part of the file name. Content is searched in text files up to \(FilesLimits.maximumSearchFileBytes) bytes, ignoring case, and each match is a line. The search stops at limit matches or when its time budget ends, and the result says if either happened. Hidden files are left out unless includeHidden is true.",
                inputSchema: .object(
                    properties: [
                        "path": .string(
                            description:
                                "Where to search: a shared folder or a folder inside one. Leave it out to search every shared folder"
                        ),
                        "name": .string(
                            description: "A glob, or part of a file name, such as \"*.swift\" or \"invoice\""
                        ),
                        "content": .string(description: "Text to find inside files"),
                        "includeHidden": .boolean(description: "Include hidden files and folders", default: false),
                        "limit": .integer(
                            description: "The most matches to return",
                            default: .int(FilesLimits.defaultSearchLimit),
                            minimum: 1,
                            maximum: FilesLimits.maximumSearchLimit
                        ),
                        "timeBudgetSeconds": .number(
                            description: "How long to search before stopping",
                            default: .double(FilesLimits.defaultSearchSeconds),
                            minimum: 1,
                            maximum: FilesLimits.maximumSearchSeconds
                        ),
                    ],
                    additionalProperties: false
                ),
                annotations: .init(title: "Search Files", readOnlyHint: true, openWorldHint: false)
            ) { arguments in
                let path = try string("path", in: arguments)
                let name = try string("name", in: arguments)
                let content = try string("content", in: arguments)
                guard name?.isEmpty == false || content?.isEmpty == false else {
                    throw FilesError.invalidArgument("Pass name, content, or both")
                }
                let includeHidden = try bool("includeHidden", in: arguments) ?? false
                let limit = try int(
                    "limit",
                    in: arguments,
                    default: FilesLimits.defaultSearchLimit,
                    range: 1 ... FilesLimits.maximumSearchLimit
                )
                let seconds = try timeBudget(in: arguments)
                return try await run(provider) { access in
                    let scopes: [FilesAccess.Resolved]
                    if let path {
                        scopes = [try access.resolve(path)]
                    } else {
                        guard !access.roots.isEmpty else { throw FilesError.noFolders }
                        scopes = try access.roots.map { try access.resolve($0.name) }
                    }
                    return try FilesOperations.search(
                        in: scopes,
                        name: name?.isEmpty == false ? name : nil,
                        content: content?.isEmpty == false ? content : nil,
                        includeHidden: includeHidden,
                        limit: limit,
                        seconds: seconds
                    )
                }
            },
        ]
    }

    private static let settingName = "\"Allow writes\" in iMCP's Files settings"

    static func writeTools(
        provider: any FilesRootProviding,
        isEnabled: @escaping @Sendable () -> Bool
    ) -> [Tool] {
        [
            Tool(
                name: "files_write",
                description:
                    "Write a text file, up to \(FilesLimits.maximumWriteBytes) bytes, in UTF-8. A new file is created in a folder that exists. A file that already exists is replaced only if you pass expectedModified or expectedSha256 from files_stat or files_read and the file still matches, or pass overwrite true; a replaced file doesn't go to the Trash. Allowed only while \(settingName) is on.",
                inputSchema: .object(
                    properties: [
                        "path": .string(description: pathDescription),
                        "content": .string(description: "The text to write"),
                        "overwrite": .boolean(
                            description: "Replace the file if it exists, whatever it contains now",
                            default: false
                        ),
                        "expectedModified": .string(
                            description:
                                "The file's modified date as you read it. The write is refused if the file has changed since"
                        ),
                        "expectedSha256": .string(
                            description:
                                "The SHA-256 of the file's content as you read it. The write is refused if the file has changed since"
                        ),
                    ],
                    required: ["path", "content"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Write File",
                    readOnlyHint: false,
                    destructiveHint: true,
                    idempotentHint: true,
                    openWorldHint: false
                )
            ) { arguments in
                try requireEnabled(isEnabled(), tool: "files_write")
                let path = try requiredString("path", in: arguments)
                guard let content = try string("content", in: arguments) else {
                    throw FilesError.invalidArgument("content is required")
                }
                let overwrite = try bool("overwrite", in: arguments) ?? false
                let precondition = try precondition(in: arguments)
                return try await run(provider) { access in
                    try FilesOperations.write(
                        try access.resolve(path),
                        content: content,
                        overwrite: overwrite,
                        precondition: precondition
                    )
                }
            },

            Tool(
                name: "files_append",
                description:
                    "Add text to the end of a file, up to \(FilesLimits.maximumWriteBytes) bytes per call. It never changes what is already in the file. Allowed only while \(settingName) is on.",
                inputSchema: .object(
                    properties: [
                        "path": .string(description: pathDescription),
                        "content": .string(description: "The text to add"),
                        "createIfMissing": .boolean(description: "Create the file if it doesn't exist", default: false),
                    ],
                    required: ["path", "content"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Append to File",
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: false,
                    openWorldHint: false
                )
            ) { arguments in
                try requireEnabled(isEnabled(), tool: "files_append")
                let path = try requiredString("path", in: arguments)
                guard let content = try string("content", in: arguments) else {
                    throw FilesError.invalidArgument("content is required")
                }
                let create = try bool("createIfMissing", in: arguments) ?? false
                return try await run(provider) { access in
                    try FilesOperations.append(try access.resolve(path), content: content, createIfMissing: create)
                }
            },

            Tool(
                name: "files_mkdir",
                description:
                    "Create a folder, and the folders above it that don't exist yet. It does nothing if the folder already exists. Allowed only while \(settingName) is on.",
                inputSchema: .object(
                    properties: ["path": .string(description: pathDescription)],
                    required: ["path"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Create Folder",
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: true,
                    openWorldHint: false
                )
            ) { arguments in
                try requireEnabled(isEnabled(), tool: "files_mkdir")
                let path = try requiredString("path", in: arguments)
                return try await run(provider) { access in
                    try FilesOperations.makeDirectory(try access.resolve(path))
                }
            },

            Tool(
                name: "files_move",
                description:
                    "Move or rename a file or folder. Both paths must be in shared folders, the folder that holds the destination must exist, and the destination must not. A symbolic link is moved itself. Allowed only while \(settingName) is on.",
                inputSchema: .object(
                    properties: [
                        "from": .string(description: pathDescription),
                        "to": .string(description: "The new path, written the same way"),
                    ],
                    required: ["from", "to"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Move File",
                    readOnlyHint: false,
                    destructiveHint: false,
                    idempotentHint: false,
                    openWorldHint: false
                )
            ) { arguments in
                try requireEnabled(isEnabled(), tool: "files_move")
                let from = try requiredString("from", in: arguments)
                let to = try requiredString("to", in: arguments)
                return try await run(provider) { access in
                    try FilesOperations.move(
                        try access.resolve(from, followingFinalSymlink: false),
                        to: try access.resolve(to, followingFinalSymlink: false)
                    )
                }
            },

            Tool(
                name: "files_trash",
                description:
                    "Move a file or folder to the Trash, where the person can put it back. iMCP never deletes anything for good. A symbolic link is trashed itself. Allowed only while \(settingName) is on.",
                inputSchema: .object(
                    properties: ["path": .string(description: pathDescription)],
                    required: ["path"],
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "Move to Trash",
                    readOnlyHint: false,
                    destructiveHint: true,
                    idempotentHint: false,
                    openWorldHint: false
                )
            ) { arguments in
                try requireEnabled(isEnabled(), tool: "files_trash")
                let path = try requiredString("path", in: arguments)
                return try await run(provider) { access in
                    try FilesOperations.trash(try access.resolve(path, followingFinalSymlink: false))
                }
            },
        ]
    }
}
