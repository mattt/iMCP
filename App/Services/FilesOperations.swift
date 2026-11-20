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

    private static func entry(path: String, name: String, info: stat?) -> Value {
        guard let info else {
            return ["path": .string(path), "name": .string(name), "type": "unreadable"]
        }
        var value: [String: Value] = [
            "name": .string(name),
            "path": .string(path),
            "type": .string(
                info.isRegularFile ? "file" : info.isDirectory ? "directory" : info.isSymbolicLink ? "symlink" : "other"
            ),
            "modified": .string(FilesDate.string(info.modified)),
        ]
        if info.isRegularFile { value["size"] = .int(Int(info.st_size)) }
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
                name: name,
                info: try? folder.status(of: name, displayPath: directory.displayPath)
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

    /// Describes an item from its folder's descriptor, without following a link.
    ///
    /// - Parameters:
    ///   - item: The path followed to its target, which is what is described.
    ///   - linkItem: The same path not followed, which says whether the client's path is a link.
    static func stat(
        _ item: FilesAccess.Resolved,
        linkItem: FilesAccess.Resolved,
        includeHash: Bool
    ) throws -> Value {
        var info = Darwin.stat()
        var parent: FilesDirectory?
        // The canonical path is empty both for the shared root itself and for a
        // link that resolves to it (`isRoot` only looks at the path as written).
        if item.canonicalComponents.isEmpty {
            let folder = try FilesDirectory.open(item.root, components: [], displayPath: item.displayPath)
            guard fstat(folder.fd, &info) == 0 else { throw FilesError.posix(errno, item.displayPath) }
        } else {
            let folder = try FilesDirectory.openParent(of: item)
            guard let name = item.canonicalComponents.last,
                let found = try folder.status(of: name, displayPath: item.displayPath)
            else { throw FilesError.notFound(item.displayPath) }
            info = found
            parent = folder
        }
        var isSymlink = false
        if !linkItem.isRoot, let name = linkItem.canonicalComponents.last {
            let folder = try FilesDirectory.openParent(of: linkItem)
            isSymlink = try folder.status(of: name, displayPath: linkItem.displayPath)?.isSymbolicLink ?? false
        }

        let name = item.canonicalComponents.last ?? item.root.name
        var value: [String: Value] = [
            "name": .string(name),
            "path": .string(item.displayPath),
            "type": .string(
                info.isRegularFile ? "file" : info.isDirectory ? "directory" : info.isSymbolicLink ? "symlink" : "other"
            ),
            "isSymlink": .bool(isSymlink),
            "isHidden": .bool(name.hasPrefix(".")),
            "modified": .string(FilesDate.string(info.modified)),
            "created": .string(
                FilesDate.string(
                    Date(
                        timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec)
                            + TimeInterval(info.st_birthtimespec.tv_nsec) / 1e9
                    )
                )
            ),
            "permissions": .string(String(info.st_mode & 0o7777, radix: 8)),
        ]
        if info.isRegularFile { value["size"] = .int(Int(info.st_size)) }
        if includeHash {
            guard info.isRegularFile, let parent else { throw FilesError.notAFile(item.displayPath) }
            let descriptor = try parent.openFile(name, flags: O_RDONLY, displayPath: item.displayPath)
            defer { close(descriptor) }
            var opened = Darwin.stat()
            guard fstat(descriptor, &opened) == 0 else { throw FilesError.posix(errno, item.displayPath) }
            value["sha256"] = .string(try FilesHash.sha256(descriptor: descriptor, size: Int(opened.st_size)))
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

    /// What a search has found so far, and the limits that end it.
    private struct SearchState {
        var matches: [Value] = []
        var truncated = false
        var timedOut = false
        var scanned = 0
        var skippedLarge = 0
        let limit: Int
        let deadline: Date
    }

    /// Searches shared folders without following a link.
    ///
    /// The walk reads each folder through a descriptor and opens each subfolder and file relative to its folder
    /// with `O_NOFOLLOW`, so an item swapped for a link while the search runs is skipped, never followed.
    /// - Parameter beforeOpening: Called with an item's name just before it is opened. Tests use it to swap items.
    static func search(
        in roots: [FilesAccess.Resolved],
        name: String?,
        content: String?,
        includeHidden: Bool,
        limit: Int,
        seconds: Double,
        now: () -> Date = Date.init,
        beforeOpening: (String) -> Void = { _ in }
    ) throws -> Value {
        var state = SearchState(limit: limit, deadline: now().addingTimeInterval(seconds))
        for root in roots {
            let folder = try FilesDirectory.open(
                root.root,
                components: root.canonicalComponents,
                displayPath: root.displayPath
            )
            walk(
                folder,
                displayPath: root.displayPath,
                name: name,
                content: content,
                includeHidden: includeHidden,
                now: now,
                beforeOpening: beforeOpening,
                state: &state
            )
            if state.truncated || state.timedOut { break }
        }
        return [
            "matches": .array(state.matches),
            "truncated": .bool(state.truncated),
            "timedOut": .bool(state.timedOut),
            "scanned": .int(state.scanned),
            "skippedLargeFiles": .int(state.skippedLarge),
        ]
    }

    private static func walk(
        _ folder: FilesDirectory,
        displayPath: String,
        name query: String?,
        content: String?,
        includeHidden: Bool,
        now: () -> Date,
        beforeOpening: (String) -> Void,
        state: inout SearchState
    ) {
        guard let names = try? folder.entryNames(displayPath: displayPath) else { return }
        for name in names.sorted() {
            if state.truncated || state.timedOut { return }
            if now() > state.deadline || Task.isCancelled {
                state.timedOut = true
                return
            }
            if !includeHidden, name.hasPrefix(".") { continue }
            if FilesAccess.isPhotosLibraryName(name) { continue }
            guard let info = try? folder.status(of: name, displayPath: displayPath) else { continue }
            state.scanned += 1
            let itemPath = displayPath + "/" + name
            let isDirectory = info.isDirectory
            let isSymlink = info.isSymbolicLink

            if query.map({ FilesGlob.nameMatches($0, name: name) }) ?? true {
                if let content {
                    // Content is searched in files only, and never through a symbolic link.
                    if info.isRegularFile {
                        if Int(info.st_size) > FilesLimits.maximumSearchFileBytes {
                            state.skippedLarge += 1
                        } else {
                            beforeOpening(name)
                            for hit in lines(in: folder, named: name, containing: content) {
                                if state.matches.count >= state.limit {
                                    state.truncated = true
                                    return
                                }
                                state.matches.append([
                                    "path": .string(itemPath),
                                    "line": .int(hit.line),
                                    "text": .string(hit.text),
                                ])
                            }
                        }
                    }
                } else {
                    if state.matches.count >= state.limit {
                        state.truncated = true
                        return
                    }
                    state.matches.append([
                        "path": .string(itemPath),
                        "type": .string(isSymlink ? "symlink" : isDirectory ? "directory" : "file"),
                    ])
                }
            }

            if isDirectory {
                beforeOpening(name)
                // A folder that became a link, or can't be opened, is skipped.
                guard let child = try? folder.child(name, displayPath: itemPath) else { continue }
                walk(
                    child,
                    displayPath: itemPath,
                    name: query,
                    content: content,
                    includeHidden: includeHidden,
                    now: now,
                    beforeOpening: beforeOpening,
                    state: &state
                )
            }
        }
    }

    /// The lines of a text file that contain `needle`, ignoring case, read from a descriptor opened without
    /// following links. Binary files and files that aren't UTF-8 or Windows text have none.
    static func lines(
        in folder: FilesDirectory,
        named name: String,
        containing needle: String
    ) -> [(line: Int, text: String)] {
        guard let descriptor = try? folder.openFile(name, flags: O_RDONLY | O_NONBLOCK, displayPath: name) else {
            return []
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0, info.isRegularFile,
            Int(info.st_size) <= FilesLimits.maximumSearchFileBytes,
            let data = try? handle.read(upToCount: FilesLimits.maximumSearchFileBytes + 1)
        else { return [] }
        return lines(in: data, containing: needle)
    }

    static func lines(in data: Data, containing needle: String) -> [(line: Int, text: String)] {
        guard let detected = FilesText.detect(sample: data.prefix(8192), isWholeFile: data.count <= 8192),
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
            // Close the descriptor on every path out, including a write that
            // throws halfway through.
            var outputIsOpen = true
            defer {
                if outputIsOpen { close(output) }
            }
            do {
                try writeAll(data, to: output, displayPath: file.displayPath)
                fchmod(output, info.st_mode & 0o7777)
                fsync(output)
                close(output)
                outputIsOpen = false
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
            var outputIsOpen = true
            defer {
                if outputIsOpen { close(output) }
            }
            do {
                try writeAll(data, to: output, displayPath: file.displayPath)
                fsync(output)
                close(output)
                outputIsOpen = false
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
        guard info.st_nlink <= 1 else { throw FilesError.hardLinked(file.displayPath) }
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
    /// The Trash API takes a path, and a sandboxed app can't rename into the real Trash by descriptor:
    /// `~/.Trash` is outside the app's container and outside every folder that the person shared.
    /// So the item is pinned instead. A descriptor to the item is opened from its folder's descriptor,
    /// the path is built from where that folder points, and the item at the path must be the pinned one
    /// just before the move. After the move the pinned descriptor says where the item went (`F_GETPATH`
    /// follows the file), and if that isn't the Trash, something else was swapped in and trashed:
    /// iMCP puts it back where it was and reports it.
    /// - Parameters:
    ///   - beforeMove: Called before the second pin check. Tests use it to swap the item before trashing.
    ///   - afterCheck: Called after the pin check and just before `trashItem`. Tests use it to exercise post-trash recovery.
    static func trash(
        _ item: FilesAccess.Resolved,
        beforeMove: () -> Void = {},
        afterCheck: () -> Void = {}
    ) throws -> Value {
        guard !item.isRoot, let name = item.canonicalComponents.last else {
            throw FilesError.invalidPath("a shared folder can't be trashed: remove it in iMCP's Files settings")
        }
        let parent = try FilesDirectory.openParent(of: item)
        guard let found = try parent.status(of: name, displayPath: item.displayPath) else {
            throw FilesError.notFound(item.displayPath)
        }
        // O_EVTONLY needs no read permission, and O_SYMLINK pins a link itself and not what it points to.
        let pin = openat(parent.fd, name, O_EVTONLY | O_SYMLINK | O_CLOEXEC)
        guard pin >= 0 else { throw FilesError.posix(errno, item.displayPath) }
        defer { close(pin) }
        func isPinned(_ other: stat) -> Bool {
            var pinned = Darwin.stat()
            return fstat(pin, &pinned) == 0 && pinned.st_dev == other.st_dev && pinned.st_ino == other.st_ino
        }
        guard isPinned(found) else { throw FilesError.changedWhileWorking(item.displayPath) }

        beforeMove()
        guard let current = try parent.status(of: name, displayPath: item.displayPath), isPinned(current) else {
            throw FilesError.changedWhileWorking(item.displayPath)
        }
        afterCheck()
        let url = URL(fileURLWithPath: parent.path).appendingPathComponent(name)
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)

        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(pin, F_GETPATH, &buffer) == 0 else {
            // The item was moved, but iMCP can't tell where it went. Don't
            // report success: the pinned item may or may not be in the Trash.
            throw FilesError.trashUnverified(item.displayPath)
        }
        let components = URL(fileURLWithPath: String(cString: buffer)).pathComponents
        if !components.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) {
            // Another item was trashed in its place. Put it back, and leave the pinned one where it is.
            if let trashed = trashed as URL?, !FilesAccess.lexists(url.path) {
                do {
                    try FileManager.default.moveItem(at: trashed, to: url)
                } catch {
                    throw FilesError.trashRestoreFailed(
                        path: item.displayPath,
                        reason: error.localizedDescription
                    )
                }
            }
            throw FilesError.changedWhileWorking(item.displayPath)
        }
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
