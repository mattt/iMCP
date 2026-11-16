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
        let folder = try FilesDirectory.open(
            directory.root,
            components: directory.canonicalComponents,
            displayPath: directory.displayPath
        )
        // The names are read through the descriptor, so a folder swapped for a link since the check isn't listed.
        let names = try folder.entryNames(displayPath: directory.displayPath)
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
                url: URL(fileURLWithPath: folder.path).appendingPathComponent(name)
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
        guard !file.isRoot, let name = file.canonicalComponents.last else {
            throw FilesError.notAFile(file.displayPath)
        }
        let parent = try FilesDirectory.openParent(of: file)
        let descriptor = try parent.openFile(name, flags: O_RDONLY, displayPath: file.displayPath)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0 else { throw FilesError.posix(errno, file.displayPath) }
        guard info.isRegularFile else { throw FilesError.notAFile(file.displayPath) }
        let size = Int(info.st_size)

        let sample = try handle.read(upToCount: 8192) ?? Data()
        let detected = FilesText.detect(sample: sample, isWholeFile: size <= sample.count)

        var common: [String: Value] = [
            "path": .string(file.displayPath),
            "size": .int(size),
        ]
        common["modified"] = .string(FilesDate.string(info.modified))

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
            // Walk from where the opened folder points, so a folder swapped for a link since the check isn't searched.
            let folder = try FilesDirectory.open(
                root.root,
                components: root.canonicalComponents,
                displayPath: root.displayPath
            )
            guard
                let enumerator = FileManager.default.enumerator(
                    at: URL(fileURLWithPath: folder.path),
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
    ///
    /// The folder that holds the file is opened without following links,
    /// a new file is created exclusively, and an existing one is replaced by renaming a new file over it,
    /// so a link put in the path after it was checked is never written through.
    static func write(
        _ file: FilesAccess.Resolved,
        content: String,
        overwrite: Bool,
        precondition: Precondition
    ) throws -> Value {
        guard !file.isRoot, let name = file.canonicalComponents.last else {
            throw FilesError.notAFile(file.displayPath)
        }
        let data = Data(content.utf8)
        guard data.count <= FilesLimits.maximumWriteBytes else {
            throw FilesError.tooLarge(
                "The content is \(data.count) bytes, over the \(FilesLimits.maximumWriteBytes) bytes that one write takes. Write the first part, then append the rest."
            )
        }
        let parent = try FilesDirectory.openParent(of: file)

        let existing = try parent.status(of: name, displayPath: file.displayPath)
        if let existing {
            if existing.isSymbolicLink { throw FilesError.changedWhileWorking(file.displayPath) }
            guard existing.isRegularFile else { throw FilesError.notAFile(file.displayPath) }

            let reading = try parent.openFile(name, flags: O_RDONLY, displayPath: file.displayPath)
            defer { close(reading) }
            var info = Darwin.stat()
            guard fstat(reading, &info) == 0 else { throw FilesError.posix(errno, file.displayPath) }
            try check(
                precondition,
                displayPath: file.displayPath,
                modified: info.modified,
                hash: { try FilesHash.sha256(descriptor: reading, size: Int(info.st_size)) }
            )
            if precondition.isEmpty && !overwrite {
                throw FilesError.alreadyExists(file.displayPath)
            }

            let temporary = ".imcp-\(UUID().uuidString).tmp"
            let output = try parent.openFile(
                temporary,
                flags: O_WRONLY | O_CREAT | O_EXCL,
                mode: info.st_mode & 0o7777,
                displayPath: file.displayPath
            )
            do {
                try writeAll(data, to: output, displayPath: file.displayPath)
                fchmod(output, info.st_mode & 0o7777)
                fsync(output)
                close(output)
                guard renameat(parent.fd, temporary, parent.fd, name) == 0 else {
                    throw FilesError.posix(errno, file.displayPath)
                }
            } catch {
                unlinkat(parent.fd, temporary, 0)
                throw error
            }
        } else {
            guard precondition.isEmpty else {
                throw FilesError.changedSinceRead(
                    "\"\(file.displayPath)\" no longer exists, so it can't be replaced as you read it. Write it without expectedModified or expectedSha256 to create it."
                )
            }
            let output = try parent.openFile(
                name,
                flags: O_WRONLY | O_CREAT | O_EXCL,
                displayPath: file.displayPath
            )
            do {
                try writeAll(data, to: output, displayPath: file.displayPath)
                fsync(output)
                close(output)
            } catch {
                unlinkat(parent.fd, name, 0)
                throw error
            }
        }
        return try changeResult(
            file,
            in: parent,
            extra: [
                "created": .bool(existing == nil),
                "bytesWritten": .int(data.count),
                "sha256": .string(FilesHash.sha256(of: data)),
            ]
        )
    }

    /// Throws unless the file is as the precondition says it was.
    static func check(
        _ precondition: Precondition,
        displayPath: String,
        modified actual: Date,
        hash: () throws -> String
    ) throws {
        if let expected = precondition.modified {
            guard FilesDate.sameMillisecond(expected, actual) else {
                throw FilesError.changedSinceRead(
                    "\"\(displayPath)\" changed since you read it: it was modified \(FilesDate.string(actual)), not \(FilesDate.string(expected)). Read it again before writing."
                )
            }
        }
        if let expected = precondition.sha256 {
            guard try hash() == expected.lowercased() else {
                throw FilesError.changedSinceRead(
                    "\"\(displayPath)\" changed since you read it: its content no longer has the SHA-256 that you passed. Read it again before writing."
                )
            }
        }
    }

    static func append(
        _ file: FilesAccess.Resolved,
        content: String,
        createIfMissing: Bool
    ) throws -> Value {
        guard !file.isRoot, let name = file.canonicalComponents.last else {
            throw FilesError.notAFile(file.displayPath)
        }
        let data = Data(content.utf8)
        guard data.count <= FilesLimits.maximumWriteBytes else {
            throw FilesError.tooLarge(
                "The content is \(data.count) bytes, over the \(FilesLimits.maximumWriteBytes) bytes that one append takes."
            )
        }
        let parent = try FilesDirectory.openParent(of: file)
        let existing = try parent.status(of: name, displayPath: file.displayPath)
        if existing == nil, !createIfMissing {
            throw FilesError.notFound(file.displayPath + " (pass createIfMissing to create it)")
        }
        let output = try parent.openFile(
            name,
            flags: O_WRONLY | O_APPEND | (createIfMissing ? O_CREAT : 0),
            displayPath: file.displayPath
        )
        defer { close(output) }
        var info = Darwin.stat()
        guard fstat(output, &info) == 0, info.isRegularFile else { throw FilesError.notAFile(file.displayPath) }
        try writeAll(data, to: output, displayPath: file.displayPath)
        fsync(output)
        return try changeResult(
            file,
            in: parent,
            extra: [
                "created": .bool(existing == nil),
                "bytesAppended": .int(data.count),
            ]
        )
    }

    static func makeDirectory(_ directory: FilesAccess.Resolved) throws -> Value {
        func open(create: Bool) throws -> FilesDirectory {
            try FilesDirectory.open(
                directory.root,
                components: directory.canonicalComponents,
                displayPath: directory.displayPath,
                create: create
            )
        }
        do {
            _ = try open(create: false)
            return ["path": .string(directory.displayPath), "created": false]
        } catch FilesError.notFound {
            _ = try open(create: true)
            return ["path": .string(directory.displayPath), "created": true]
        } catch FilesError.notADirectory {
            throw FilesError.alreadyExists(directory.displayPath + " (a file)")
        }
    }

    /// Moves or renames an item, never replacing one that is already there.
    static func move(_ source: FilesAccess.Resolved, to destination: FilesAccess.Resolved) throws -> Value {
        guard !source.isRoot, let sourceName = source.canonicalComponents.last else {
            throw FilesError.invalidPath("a shared folder can't be moved: remove it in iMCP's Files settings")
        }
        guard !destination.isRoot, let destinationName = destination.canonicalComponents.last else {
            throw FilesError.alreadyExists(destination.displayPath)
        }
        let sourceParent = try FilesDirectory.openParent(of: source)
        let destinationParent = try FilesDirectory.openParent(of: destination)
        guard let info = try sourceParent.status(of: sourceName, displayPath: source.displayPath) else {
            throw FilesError.notFound(source.displayPath)
        }
        if info.isDirectory, destination.url.pathComponents.starts(with: source.url.pathComponents) {
            throw FilesError.invalidPath("\"\(source.displayPath)\" can't be moved into itself")
        }
        // RENAME_EXCL fails, atomically, if the destination exists.
        guard
            renameatx_np(
                sourceParent.fd,
                sourceName,
                destinationParent.fd,
                destinationName,
                UInt32(RENAME_EXCL)
            ) == 0
        else { throw FilesError.posix(errno, destination.displayPath) }
        return [
            "from": .string(source.displayPath),
            "to": .string(destination.displayPath),
        ]
    }

    /// Moves an item to the Trash, from which the person can put it back.
    ///
    /// The Trash API takes a path, so the item's folder is opened and checked first,
    /// and the path is built from where that descriptor points.
    static func trash(_ item: FilesAccess.Resolved) throws -> Value {
        guard !item.isRoot, let name = item.canonicalComponents.last else {
            throw FilesError.invalidPath("a shared folder can't be trashed: remove it in iMCP's Files settings")
        }
        let parent = try FilesDirectory.openParent(of: item)
        guard try parent.status(of: name, displayPath: item.displayPath) != nil else {
            throw FilesError.notFound(item.displayPath)
        }
        let url = URL(fileURLWithPath: parent.path).appendingPathComponent(name)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        return ["path": .string(item.displayPath), "trashed": true]
    }

    // MARK: -

    private static func writeAll(_ data: Data, to descriptor: Int32, displayPath: String) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw FilesError.posix(errno, displayPath)
                }
                offset += written
            }
        }
    }

    private static func changeResult(
        _ file: FilesAccess.Resolved,
        in parent: FilesDirectory,
        extra: [String: Value]
    ) throws -> Value {
        var value = extra
        value["path"] = .string(file.displayPath)
        if let name = file.canonicalComponents.last,
            let info = try parent.status(of: name, displayPath: file.displayPath)
        {
            value["size"] = .int(Int(info.st_size))
            value["modified"] = .string(FilesDate.string(info.modified))
        }
        return .object(value)
    }
}
