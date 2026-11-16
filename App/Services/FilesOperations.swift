import Foundation
import MCP

/// What the Files tools do to the file system, once a path has been resolved.
///
/// None of these checks a setting: the tools that change files check it before they call these.
enum FilesOperations {
    // MARK: - Reading

    private static func attributes(of url: URL) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: url.path)
    }

    private static func kind(of attributes: [FileAttributeKey: Any]) -> String {
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular: return "file"
        case .typeDirectory: return "directory"
        case .typeSymbolicLink: return "symlink"
        default: return "other"
        }
    }

    private static func entry(path: String, url: URL) -> Value {
        guard let attributes = try? attributes(of: url) else {
            return ["path": .string(path), "name": .string(url.lastPathComponent), "type": "unreadable"]
        }
        var value: [String: Value] = [
            "name": .string(url.lastPathComponent),
            "path": .string(path),
            "type": .string(kind(of: attributes)),
        ]
        if kind(of: attributes) == "file", let size = (attributes[.size] as? NSNumber)?.intValue {
            value["size"] = .int(size)
        }
        if let modified = attributes[.modificationDate] as? Date {
            value["modified"] = .string(FilesDate.string(modified))
        }
        return .object(value)
    }

    static func list(
        _ directory: FilesAccess.Resolved,
        glob: String?,
        includeHidden: Bool,
        offset: Int,
        limit: Int
    ) throws -> Value {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.url.path, isDirectory: &isDirectory) else {
            throw FilesError.notFound(directory.displayPath)
        }
        guard isDirectory.boolValue else { throw FilesError.notADirectory(directory.displayPath) }

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
            .filter { includeHidden || !$0.hasPrefix(".") }
            .filter { !FilesAccess.isPhotosLibraryName($0) }
            .filter { name in glob.map { FilesGlob.matches($0, name: name) } ?? true }
            .sorted { lhs, rhs in
                let order = lhs.caseInsensitiveCompare(rhs)
                return order == .orderedSame ? lhs < rhs : order == .orderedAscending
            }
        let page = FilesPaging.page(of: names, offset: offset, limit: limit)
        let entries = page.items.map { name in
            entry(
                path: directory.displayPath + "/" + name,
                url: directory.url.appendingPathComponent(name)
            )
        }
        return [
            "path": .string(directory.displayPath),
            "entries": .array(entries),
            "total": .int(names.count),
            "offset": .int(max(offset, 0)),
            "nextOffset": page.nextOffset.map { .int($0) } ?? .null,
        ]
    }

    static func stat(
        _ item: FilesAccess.Resolved,
        isSymlink: Bool,
        includeHash: Bool
    ) throws -> Value {
        guard FilesAccess.lexists(item.url.path) else { throw FilesError.notFound(item.displayPath) }
        let attributes = try attributes(of: item.url)
        var value: [String: Value] = [
            "name": .string(item.isRoot ? item.root.name : item.url.lastPathComponent),
            "path": .string(item.displayPath),
            "type": .string(kind(of: attributes)),
            "isSymlink": .bool(isSymlink),
            "isHidden": .bool(item.url.lastPathComponent.hasPrefix(".")),
        ]
        if let size = (attributes[.size] as? NSNumber)?.intValue, kind(of: attributes) == "file" {
            value["size"] = .int(size)
        }
        if let created = attributes[.creationDate] as? Date { value["created"] = .string(FilesDate.string(created)) }
        if let modified = attributes[.modificationDate] as? Date {
            value["modified"] = .string(FilesDate.string(modified))
        }
        if let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue {
            value["permissions"] = .string(String(permissions, radix: 8))
        }
        if includeHash {
            guard kind(of: attributes) == "file" else { throw FilesError.notAFile(item.displayPath) }
            value["sha256"] = .string(try FilesHash.sha256(of: item.url))
        }
        return .object(value)
    }

    enum ReadFormat: String, CaseIterable {
        case auto, text, base64
    }

    static func read(
        _ file: FilesAccess.Resolved,
        offset: Int,
        maxBytes: Int,
        format: ReadFormat
    ) throws -> Value {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.url.path, isDirectory: &isDirectory) else {
            throw FilesError.notFound(file.displayPath)
        }
        guard !isDirectory.boolValue else { throw FilesError.notAFile(file.displayPath) }

        let attributes = try attributes(of: file.url)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }

        let sample = try handle.read(upToCount: 8192) ?? Data()
        let detected = FilesText.detect(sample: sample, isWholeFile: size <= sample.count)

        var common: [String: Value] = [
            "path": .string(file.displayPath),
            "size": .int(size),
        ]
        if let modified = attributes[.modificationDate] as? Date {
            common["modified"] = .string(FilesDate.string(modified))
        }

        let asText: Bool
        switch format {
        case .auto: asText = detected != nil
        case .text:
            guard detected != nil else {
                throw FilesError.invalidArgument(
                    "\"\(file.displayPath)\" isn't text. Use format \"base64\" to read its bytes."
                )
            }
            asText = true
        case .base64: asText = false
        }

        if !asText {
            // A binary file that `auto` can't return whole is refused, not silently cut.
            if format == .auto, size > FilesLimits.maximumBinaryBytes {
                throw FilesError.binaryFile(
                    path: file.displayPath,
                    size: size,
                    limit: FilesLimits.maximumBinaryBytes
                )
            }
            let count = min(maxBytes, FilesLimits.maximumBinaryBytes)
            try handle.seek(toOffset: UInt64(min(offset, size)))
            let data = try handle.read(upToCount: count) ?? Data()
            let end = min(offset, size) + data.count
            common["format"] = "base64"
            common["content"] = .string(data.base64EncodedString())
            common["offset"] = .int(min(offset, size))
            common["bytesRead"] = .int(data.count)
            common["truncated"] = .bool(end < size)
            common["nextOffset"] = end < size ? .int(end) : .null
            return .object(common)
        }

        let (encoding, bomLength) = detected ?? (.utf8, 0)
        var start = min(offset, size)
        if offset == 0 { start = bomLength }
        if encoding != .utf8 && encoding != .windows1252 && offset > 0 {
            throw FilesError.invalidArgument(
                "\"\(file.displayPath)\" is \(encoding.rawValue) text, which can only be read from offset 0."
            )
        }
        try handle.seek(toOffset: UInt64(start))
        // A window holds at least one whole character, so that reading always moves forward.
        var data = try handle.read(upToCount: max(maxBytes, 4)) ?? Data()
        var end = start + data.count

        switch encoding {
        case .utf8:
            if start > 0 {
                // A window can start inside a character: skip what is left of it.
                let skip = FilesText.leadingContinuationLength(data)
                data = data.dropFirst(skip)
                start += skip
            }
            if end < size {
                let cut = FilesText.incompleteUTF8SuffixLength(data)
                data = data.dropLast(cut)
                end -= cut
            }
        case .utf16LittleEndian, .utf16BigEndian:
            if data.count % 2 == 1 {
                data = data.dropLast()
                end -= 1
            }
        case .windows1252:
            break
        }

        guard let text = String(data: Data(data), encoding: encoding.stringEncoding) else {
            throw FilesError.invalidArgument(
                "\"\(file.displayPath)\" has content that isn't valid \(encoding.rawValue). Use format \"base64\"."
            )
        }
        common["format"] = "text"
        common["encoding"] = .string(encoding.rawValue)
        common["content"] = .string(text)
        common["offset"] = .int(start)
        common["bytesRead"] = .int(end - start)
        let more = end < size
        common["truncated"] = .bool(more)
        common["nextOffset"] = more && (encoding == .utf8 || encoding == .windows1252) ? .int(end) : .null
        if more && !(encoding == .utf8 || encoding == .windows1252) {
            common["note"] = "Only the first part of this \(encoding.rawValue) file is returned."
        }
        return .object(common)
    }

    // MARK: - Searching

    static func search(
        in roots: [FilesAccess.Resolved],
        name: String?,
        content: String?,
        includeHidden: Bool,
        limit: Int,
        seconds: Double,
        now: () -> Date = Date.init
    ) throws -> Value {
        let deadline = now().addingTimeInterval(seconds)
        var matches: [Value] = []
        var truncated = false
        var timedOut = false
        var scanned = 0
        var skippedLarge = 0

        search: for root in roots {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                    options: includeHidden ? [] : [.skipsHiddenFiles]
                )
            else { continue }

            for case let url as URL in enumerator {
                if now() > deadline || Task.isCancelled {
                    timedOut = true
                    break search
                }
                let itemName = url.lastPathComponent
                if FilesAccess.isPhotosLibraryName(itemName) {
                    enumerator.skipDescendants()
                    continue
                }
                scanned += 1

                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                let isDirectory = values?.isDirectory == true
                let isSymlink = values?.isSymbolicLink == true
                let relative = url.pathComponents.dropFirst(root.root.url.pathComponents.count)
                let displayPath = ([root.root.name] + relative).joined(separator: "/")

                if let name, !FilesGlob.nameMatches(name, name: itemName) { continue }

                if let content {
                    // Content is searched in files only, and never through a symbolic link.
                    guard !isDirectory, !isSymlink else { continue }
                    if (values?.fileSize ?? 0) > FilesLimits.maximumSearchFileBytes {
                        skippedLarge += 1
                        continue
                    }
                    for hit in lines(of: url, containing: content) {
                        if matches.count >= limit {
                            truncated = true
                            break search
                        }
                        matches.append([
                            "path": .string(displayPath),
                            "line": .int(hit.line),
                            "text": .string(hit.text),
                        ])
                    }
                } else {
                    if matches.count >= limit {
                        truncated = true
                        break search
                    }
                    matches.append([
                        "path": .string(displayPath),
                        "type": .string(isSymlink ? "symlink" : isDirectory ? "directory" : "file"),
                    ])
                }
            }
        }

        return [
            "matches": .array(matches),
            "truncated": .bool(truncated),
            "timedOut": .bool(timedOut),
            "scanned": .int(scanned),
            "skippedLargeFiles": .int(skippedLarge),
        ]
    }

    /// The lines of a text file that contain `needle`, ignoring case.
    /// Binary files and files that aren't UTF-8 or Windows text have none.
    static func lines(of url: URL, containing needle: String) -> [(line: Int, text: String)] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            let detected = FilesText.detect(sample: data.prefix(8192), isWholeFile: data.count <= 8192),
            detected.encoding == .utf8 || detected.encoding == .windows1252,
            let text = String(data: data, encoding: detected.encoding.stringEncoding)
        else { return [] }

        var hits: [(Int, String)] = []
        var number = 0
        text.enumerateLines { line, _ in
            number += 1
            guard line.range(of: needle, options: .caseInsensitive) != nil else { return }
            hits.append((number, String(line.prefix(FilesLimits.maximumSnippetCharacters))))
        }
        return hits
    }

    // MARK: - Changing

    /// What a client says the file looked like when it read it.
    struct Precondition: Equatable {
        var modified: Date?
        var sha256: String?

        var isEmpty: Bool { modified == nil && sha256 == nil }
    }

    /// Writes a file that is new, or that is unchanged since the client read it.
    ///
    /// An existing file is replaced only if the client says what it read (`precondition`)
    /// or that it doesn't mind losing the content (`overwrite`).
    /// A file that is replaced doesn't reach the Trash, so the default is to refuse.
    static func write(
        _ file: FilesAccess.Resolved,
        content: String,
        overwrite: Bool,
        precondition: Precondition
    ) throws -> Value {
        guard !file.isRoot else { throw FilesError.notAFile(file.displayPath) }
        let data = Data(content.utf8)
        guard data.count <= FilesLimits.maximumWriteBytes else {
            throw FilesError.tooLarge(
                "The content is \(data.count) bytes, over the \(FilesLimits.maximumWriteBytes) bytes that one write takes. Write the first part, then append the rest."
            )
        }
        try requireParentDirectory(of: file)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: file.url.path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue { throw FilesError.notAFile(file.displayPath) }

        var permissions: Any?
        if exists {
            let attributes = try attributes(of: file.url)
            permissions = attributes[.posixPermissions]
            try check(precondition, against: file, attributes: attributes)
            if precondition.isEmpty && !overwrite {
                throw FilesError.alreadyExists(file.displayPath)
            }
        } else if !precondition.isEmpty {
            throw FilesError.changedSinceRead(
                "\"\(file.displayPath)\" no longer exists, so it can't be replaced as you read it. Write it without expectedModified or expectedSha256 to create it."
            )
        }

        try data.write(to: file.url, options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.url.path)
        }
        return try changeResult(
            file,
            extra: [
                "created": .bool(!exists),
                "bytesWritten": .int(data.count),
                "sha256": .string(FilesHash.sha256(of: data)),
            ]
        )
    }

    /// Throws unless the file is as the precondition says it was.
    static func check(
        _ precondition: Precondition,
        against file: FilesAccess.Resolved,
        attributes: [FileAttributeKey: Any]
    ) throws {
        if let expected = precondition.modified {
            let actual = attributes[.modificationDate] as? Date ?? .distantPast
            guard FilesDate.sameMillisecond(expected, actual) else {
                throw FilesError.changedSinceRead(
                    "\"\(file.displayPath)\" changed since you read it: it was modified \(FilesDate.string(actual)), not \(FilesDate.string(expected)). Read it again before writing."
                )
            }
        }
        if let expected = precondition.sha256 {
            let actual = try FilesHash.sha256(of: file.url)
            guard actual == expected.lowercased() else {
                throw FilesError.changedSinceRead(
                    "\"\(file.displayPath)\" changed since you read it: its content no longer has the SHA-256 that you passed. Read it again before writing."
                )
            }
        }
    }

    static func append(
        _ file: FilesAccess.Resolved,
        content: String,
        createIfMissing: Bool
    ) throws -> Value {
        guard !file.isRoot else { throw FilesError.notAFile(file.displayPath) }
        let data = Data(content.utf8)
        guard data.count <= FilesLimits.maximumWriteBytes else {
            throw FilesError.tooLarge(
                "The content is \(data.count) bytes, over the \(FilesLimits.maximumWriteBytes) bytes that one append takes."
            )
        }
        try requireParentDirectory(of: file)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: file.url.path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue { throw FilesError.notAFile(file.displayPath) }
        if !exists {
            guard createIfMissing else {
                throw FilesError.notFound(file.displayPath + " (pass createIfMissing to create it)")
            }
            guard FileManager.default.createFile(atPath: file.url.path, contents: nil) else {
                throw FilesError.invalidArgument("\"\(file.displayPath)\" couldn't be created.")
            }
        }

        let handle = try FileHandle(forWritingTo: file.url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        return try changeResult(
            file,
            extra: [
                "created": .bool(!exists),
                "bytesAppended": .int(data.count),
            ]
        )
    }

    static func makeDirectory(_ directory: FilesAccess.Resolved) throws -> Value {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw FilesError.alreadyExists(directory.displayPath + " (a file)") }
            return ["path": .string(directory.displayPath), "created": false]
        }
        try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
        return ["path": .string(directory.displayPath), "created": true]
    }

    /// Moves or renames an item, never replacing one that is already there.
    static func move(_ source: FilesAccess.Resolved, to destination: FilesAccess.Resolved) throws -> Value {
        guard !source.isRoot else {
            throw FilesError.invalidPath("a shared folder can't be moved: remove it in iMCP's Files settings")
        }
        guard !destination.isRoot else { throw FilesError.alreadyExists(destination.displayPath) }
        guard FilesAccess.lexists(source.url.path) else { throw FilesError.notFound(source.displayPath) }
        guard !FilesAccess.lexists(destination.url.path) else {
            throw FilesError.alreadyExists(destination.displayPath)
        }
        try requireParentDirectory(of: destination)

        let sourceIsFolder = (try? attributes(of: source.url)).map { kind(of: $0) == "directory" } ?? false
        if sourceIsFolder, destination.url.pathComponents.starts(with: source.url.pathComponents) {
            throw FilesError.invalidPath("\"\(source.displayPath)\" can't be moved into itself")
        }
        try FileManager.default.moveItem(at: source.url, to: destination.url)
        return [
            "from": .string(source.displayPath),
            "to": .string(destination.displayPath),
        ]
    }

    /// Moves an item to the Trash, from which the person can put it back.
    static func trash(_ item: FilesAccess.Resolved) throws -> Value {
        guard !item.isRoot else {
            throw FilesError.invalidPath("a shared folder can't be trashed: remove it in iMCP's Files settings")
        }
        guard FilesAccess.lexists(item.url.path) else { throw FilesError.notFound(item.displayPath) }
        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        return ["path": .string(item.displayPath), "trashed": true]
    }

    // MARK: -

    private static func requireParentDirectory(of item: FilesAccess.Resolved) throws {
        var isDirectory: ObjCBool = false
        let parent = item.url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw FilesError.notFound("the folder that would hold \"\(item.displayPath)\" (use files_mkdir)")
        }
    }

    private static func changeResult(_ file: FilesAccess.Resolved, extra: [String: Value]) throws -> Value {
        let attributes = try attributes(of: file.url)
        var value = extra
        value["path"] = .string(file.displayPath)
        value["size"] = .int((attributes[.size] as? NSNumber)?.intValue ?? 0)
        if let modified = attributes[.modificationDate] as? Date {
            value["modified"] = .string(FilesDate.string(modified))
        }
        return .object(value)
    }
}
