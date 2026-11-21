import CryptoKit
import Foundation

/// A folder that the person granted to clients, as it resolved on this launch.
struct FilesRoot: Sendable, Equatable {
    /// The name that clients write first in a path, such as `Documents` in `Documents/notes.txt`.
    var name: String
    /// The folder's canonical location, with its symbolic links resolved.
    var url: URL
}

/// Why a Files tool refused or couldn't finish, in words that a client can act on.
enum FilesError: Error, LocalizedError, Equatable {
    case noFolders
    case unknownFolder(String, available: [String])
    case invalidPath(String)
    case escapesFolder(String)
    case photosLibrary(String)
    case danglingSymlink(String)
    case folderUnavailable(String)
    case notFound(String)
    case notAFile(String)
    case notADirectory(String)
    case alreadyExists(String)
    case hardLinked(String)
    case tooLarge(String)
    case binaryFile(path: String, size: Int, limit: Int)
    case changedSinceRead(String)
    case changedWhileWorking(String)
    case trashUnverified(String)
    case trashRestoreFailed(path: String, reason: String)
    case invalidArgument(String)

    /// The error for a failed system call on `path`.
    static func posix(_ code: Int32, _ path: String) -> FilesError {
        switch code {
        case ELOOP, EMLINK: return .changedWhileWorking(path)
        case ENOENT: return .notFound(path)
        case ENOTDIR: return .notADirectory(path)
        case EEXIST, ENOTEMPTY: return .alreadyExists(path)
        case EISDIR, ENXIO: return .notAFile(path)
        default: return .invalidArgument("\"\(path)\": \(String(cString: strerror(code)))")
        }
    }

    var errorDescription: String? {
        switch self {
        case .noFolders:
            return "No folders are shared. Add a folder in iMCP's Files settings first."
        case .unknownFolder(let name, let available):
            let names = available.isEmpty ? "none" : available.joined(separator: ", ")
            return
                "\"\(name)\" is not a shared folder. A path starts with the name of a shared folder (see files_roots). Shared folders: \(names)."
        case .invalidPath(let reason):
            return "Invalid path: \(reason)"
        case .escapesFolder(let path):
            return "\"\(path)\" resolves to a place outside the shared folders, so iMCP won't touch it."
        case .photosLibrary(let path):
            return "\"\(path)\" is in a Photos library. iMCP never reads or changes Photos libraries."
        case .danglingSymlink(let path):
            return "\"\(path)\" is a symbolic link whose target doesn't exist."
        case .folderUnavailable(let name):
            return
                "The shared folder \"\(name)\" is unavailable: it moved, was replaced, or needs to be added again in iMCP's Files settings."
        case .notFound(let path):
            return "\"\(path)\" doesn't exist."
        case .notAFile(let path):
            return "\"\(path)\" is not a file."
        case .notADirectory(let path):
            return "\"\(path)\" is not a folder."
        case .alreadyExists(let path):
            return "\"\(path)\" already exists."
        case .hardLinked(let path):
            return "\"\(path)\" has more than one hard link, so iMCP won't append to it in place."
        case .tooLarge(let message):
            return message
        case .binaryFile(let path, let size, let limit):
            return
                "\"\(path)\" is a binary file of \(size) bytes. Binary files are returned only as base64, up to \(limit) bytes per call: pass format \"base64\" with an offset to read it in pieces."
        case .changedSinceRead(let message):
            return message
        case .changedWhileWorking(let path):
            return
                "\"\(path)\" changed while iMCP worked on it: a folder or file in its path is now a link or is somewhere else. Nothing was changed. Try again."
        case .trashUnverified(let path):
            return
                "\"\(path)\" was moved to the Trash, but iMCP could not confirm where it went. Check the Trash before trying again."
        case .trashRestoreFailed(let path, let reason):
            return
                "Another item was moved to the Trash in the place of \"\(path)\", and putting it back failed: \(reason). Check the Trash for the item that was moved."
        case .invalidArgument(let message):
            return message
        }
    }
}

/// Resolves the paths that clients write against the folders that the person shared.
///
/// A path is a shared folder's name followed by a path inside the folder,
/// such as `Documents/Taxes/2025.pdf`.
/// Everything that a tool touches goes through ``resolve(_:followingFinalSymlink:)``,
/// which returns the canonical location that the tool then uses instead of the client's spelling,
/// so a symbolic link that changes between the check and the use can't send the tool somewhere else.
struct FilesAccess: Sendable {
    var roots: [FilesRoot]

    /// A path that was checked against the shared folders.
    struct Resolved: Sendable, Equatable {
        var root: FilesRoot
        /// The canonical location to use.
        var url: URL
        /// The components below the root, as the client wrote them.
        var relativeComponents: [String]

        var isRoot: Bool { relativeComponents.isEmpty }

        /// The components of the canonical location below the root.
        /// A tool that changes something opens these one at a time, never following a link.
        var canonicalComponents: [String] {
            Array(url.pathComponents.dropFirst(root.url.pathComponents.count))
        }

        /// The path as clients write it, starting with the root's name.
        var displayPath: String {
            ([root.name] + relativeComponents).joined(separator: "/")
        }
    }

    /// Whether a name is a Photos library, which iMCP never opens.
    static func isPhotosLibraryName(_ name: String) -> Bool {
        // APFS matches names after case folding, so "photoſlibrary" (long s) names the same directory.
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .hasSuffix(".photoslibrary")
    }

    /// Whether any part of a location is a Photos library.
    static func isInsidePhotosLibrary(_ url: URL) -> Bool {
        url.pathComponents.contains(where: isPhotosLibraryName)
    }

    /// Resolves `path` to a location inside a shared folder, or throws.
    ///
    /// - Parameters:
    ///   - path: The shared folder's name, then the path inside it.
    ///     `..` is refused outright, and an absolute path is refused.
    ///   - followingFinalSymlink: Whether a symbolic link at the end of the path is followed.
    ///     Reading and writing follow it, so the content is the target's,
    ///     and the target must be inside a shared folder.
    ///     Moving and trashing don't, because they act on the link and not on what it points to.
    func resolve(_ path: String, followingFinalSymlink: Bool = true) throws -> Resolved {
        guard !roots.isEmpty else { throw FilesError.noFolders }
        guard !path.isEmpty else { throw FilesError.invalidPath("the path is empty") }
        guard !path.contains("\0") else { throw FilesError.invalidPath("the path contains a NUL character") }
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else {
            throw FilesError.invalidPath(
                "start with the name of a shared folder (see files_roots), not an absolute path or ~"
            )
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
        guard let rootName = components.first else {
            throw FilesError.invalidPath("the path has no folder name")
        }
        let relative = Array(components.dropFirst())
        guard !relative.contains("..") else {
            throw FilesError.invalidPath("\"..\" is not allowed in a path")
        }
        guard let root = roots.first(where: { $0.name == rootName }) else {
            throw FilesError.unknownFolder(rootName, available: roots.map(\.name))
        }
        if components.contains(where: Self.isPhotosLibraryName) {
            throw FilesError.photosLibrary(path)
        }

        // The grant must still point where it did when it was resolved:
        // a folder that was swapped for a symbolic link since then is not what the person chose.
        guard let rootPath = Self.realPath(root.url.path), rootPath == root.url.path else {
            throw FilesError.folderUnavailable(root.name)
        }
        if Self.isInsidePhotosLibrary(root.url) {
            throw FilesError.photosLibrary(root.name)
        }

        var resolvable = relative
        var unresolved: [String] = []
        if !followingFinalSymlink, let last = resolvable.popLast() {
            unresolved.append(last)
        }

        // Resolve the part that exists, and append the rest, which has no links to follow.
        var existing = root.url
        for component in resolvable { existing.appendPathComponent(component) }
        var missing: [String] = []
        while !Self.lexists(existing.path) {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard let resolvedPath = Self.realPath(existing.path) else {
            throw FilesError.danglingSymlink(path)
        }
        var canonical = URL(fileURLWithPath: resolvedPath)
        for component in missing + unresolved { canonical.appendPathComponent(component) }

        guard canonical.pathComponents.starts(with: root.url.pathComponents) else {
            throw FilesError.escapesFolder(path)
        }
        if Self.isInsidePhotosLibrary(canonical) {
            throw FilesError.photosLibrary(path)
        }
        return Resolved(root: root, url: canonical, relativeComponents: relative)
    }

    // MARK: -

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether anything is at `path`, counting a symbolic link whose target is missing.
    static func lexists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}

// MARK: - Descriptors

/// A directory inside a shared folder, opened one component at a time without following links.
///
/// Checking a path and then using it leaves a gap in which a folder can be swapped for a link
/// that points out of the shared folder.
/// The tools that change or read files close the gap by opening the folder that holds the file
/// from the root down with `O_NOFOLLOW`, and doing the final step relative to that descriptor.
/// A component that has become a link makes the open fail, so nothing outside is touched.
final class FilesDirectory {
    let fd: Int32
    /// Where the descriptor points, checked to be inside the shared folder.
    let path: String

    private init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    deinit { close(fd) }

    private static let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// Opens `components` below a shared folder, making the folders that are missing if `create` is true.
    static func open(
        _ root: FilesRoot,
        components: [String],
        displayPath: String,
        create: Bool = false
    ) throws -> FilesDirectory {
        var current = Darwin.open(root.url.path, flags)
        guard current >= 0 else { throw FilesError.folderUnavailable(root.name) }
        for component in components {
            var next = openat(current, component, flags)
            if next < 0, errno == ENOENT, create {
                if mkdirat(current, component, 0o755) != 0, errno != EEXIST {
                    let code = errno
                    close(current)
                    throw FilesError.posix(code, displayPath)
                }
                next = openat(current, component, flags)
            }
            var code = errno
            if next < 0, code == ENOTDIR {
                // O_DIRECTORY with O_NOFOLLOW reports a link as "not a directory": tell the two apart.
                var info = stat()
                if fstatat(current, component, &info, AT_SYMLINK_NOFOLLOW) == 0, info.isSymbolicLink { code = ELOOP }
            }
            close(current)
            guard next >= 0 else { throw FilesError.posix(code, displayPath) }
            current = next
        }

        // The descriptor must still be inside the shared folder, whatever happened on the way.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(current, F_GETPATH, &buffer) == 0 else {
            close(current)
            throw FilesError.changedWhileWorking(displayPath)
        }
        let actual = String(cString: buffer)
        let actualComponents = URL(fileURLWithPath: actual).pathComponents
        let rootComponents = root.url.pathComponents
        let isInside =
            actualComponents.count >= rootComponents.count
            && zip(actualComponents, rootComponents).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
        guard isInside else {
            close(current)
            throw FilesError.escapesFolder(displayPath)
        }
        guard !FilesAccess.isInsidePhotosLibrary(URL(fileURLWithPath: actual)) else {
            close(current)
            throw FilesError.photosLibrary(displayPath)
        }
        return FilesDirectory(fd: current, path: actual)
    }

    /// Opens the folder that holds an item, or the folder itself if `item` is a folder to open.
    static func openParent(of item: FilesAccess.Resolved, create: Bool = false) throws -> FilesDirectory {
        try open(
            item.root,
            components: Array(item.canonicalComponents.dropLast()),
            displayPath: item.displayPath,
            create: create
        )
    }

    /// Opens a subfolder, which fails if it is a link.
    func child(_ name: String, displayPath: String) throws -> FilesDirectory {
        let next = openat(fd, name, Self.flags)
        guard next >= 0 else {
            var code = errno
            if code == ENOTDIR, let info = try? status(of: name, displayPath: displayPath), info.isSymbolicLink {
                code = ELOOP
            }
            throw FilesError.posix(code, displayPath)
        }
        return FilesDirectory(fd: next, path: path + "/" + name)
    }

    /// The names of the entries of the folder, read through the descriptor.
    func entryNames(displayPath: String) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0, let directory = fdopendir(copy) else {
            let code = errno
            if copy >= 0 { close(copy) }
            throw FilesError.posix(code, displayPath)
        }
        defer { closedir(directory) }
        var names: [String] = []
        while var entry = readdir(directory)?.pointee {
            let name = withUnsafePointer(to: &entry.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    /// Where the item `name` is on disk, as the file system spells it, without following a link.
    ///
    /// The spelling in a client's path can differ from the name on disk (case, long s, normalization),
    /// so checks on the final component use this instead of the client's text.
    func onDiskPath(of name: String, displayPath: String) throws -> String {
        let pin = openat(fd, name, O_EVTONLY | O_SYMLINK | O_CLOEXEC)
        guard pin >= 0 else { throw FilesError.posix(errno, displayPath) }
        defer { close(pin) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(pin, F_GETPATH, &buffer) == 0 else { throw FilesError.changedWhileWorking(displayPath) }
        return String(cString: buffer)
    }

    /// What is at `name` in the folder, without following a link, or nil if nothing is.
    func status(of name: String, displayPath: String) throws -> stat? {
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return info }
        guard errno == ENOENT else { throw FilesError.posix(errno, displayPath) }
        return nil
    }

    /// Opens a regular file in the folder, which fails if it is a link or anything else.
    ///
    /// Opening a pipe or a device can block, so the open doesn't wait, the type is checked on the descriptor,
    /// and only then does the descriptor go back to blocking.
    func openFile(_ name: String, flags: Int32, mode: mode_t = 0o644, displayPath: String) throws -> Int32 {
        let file = openat(fd, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode)
        guard file >= 0 else { throw FilesError.posix(errno, displayPath) }
        var info = stat()
        guard fstat(file, &info) == 0, info.isRegularFile else {
            close(file)
            throw FilesError.notAFile(displayPath)
        }
        _ = fcntl(file, F_SETFL, fcntl(file, F_GETFL) & ~O_NONBLOCK)
        return file
    }
}

extension stat {
    var isRegularFile: Bool { st_mode & S_IFMT == S_IFREG }
    var isDirectory: Bool { st_mode & S_IFMT == S_IFDIR }
    var isSymbolicLink: Bool { st_mode & S_IFMT == S_IFLNK }

    var modified: Date {
        Date(timeIntervalSince1970: TimeInterval(st_mtimespec.tv_sec) + TimeInterval(st_mtimespec.tv_nsec) / 1e9)
    }
}

// MARK: - Limits

enum FilesLimits {
    /// The most that one read returns unless the client asks for less.
    static let defaultReadBytes = 262_144
    static let maximumReadBytes = 1_048_576
    /// The most bytes of a binary file that one read returns, as base64.
    static let maximumBinaryBytes = 262_144
    /// The most that one write or append takes.
    static let maximumWriteBytes = 1_048_576
    /// The largest file that iMCP computes a hash of.
    static let maximumHashBytes = 67_108_864
    /// The largest file that a content search reads.
    static let maximumSearchFileBytes = 2_097_152
    static let defaultListLimit = 100
    static let maximumListLimit = 500
    static let defaultSearchLimit = 50
    static let maximumSearchLimit = 200
    static let defaultSearchSeconds = 10.0
    static let maximumSearchSeconds = 30.0
    /// The characters of a matching line that a content search returns.
    static let maximumSnippetCharacters = 200
}

// MARK: - Paging and matching

enum FilesPaging {
    /// One page of `items`, and the offset of the next page, or nil after the last one.
    static func page<T>(of items: [T], offset: Int, limit: Int) -> (items: [T], nextOffset: Int?) {
        let start = min(max(offset, 0), items.count)
        let end = min(start + max(limit, 0), items.count)
        return (Array(items[start ..< end]), end < items.count ? end : nil)
    }
}

enum FilesGlob {
    /// Whether `pattern` has wildcard characters, so that it is a glob and not text to find.
    static func isGlob(_ pattern: String) -> Bool {
        pattern.contains { "*?[".contains($0) }
    }

    /// Whether a file name matches a glob, ignoring case.
    static func matches(_ pattern: String, name: String) -> Bool {
        fnmatch(pattern, name, FNM_CASEFOLD) == 0
    }

    /// Whether a name matches a query: a glob if it has wildcards, otherwise a part of the name.
    static func nameMatches(_ query: String, name: String) -> Bool {
        isGlob(query) ? matches(query, name: name) : name.range(of: query, options: .caseInsensitive) != nil
    }
}

// MARK: - Text

/// How much of a file's bytes make a window, and how its text is decoded.
enum FilesText {
    enum Encoding: String, Sendable {
        case utf8
        case utf16LittleEndian = "utf-16le"
        case utf16BigEndian = "utf-16be"
        case windows1252

        var stringEncoding: String.Encoding {
            switch self {
            case .utf8: return .utf8
            case .utf16LittleEndian: return .utf16LittleEndian
            case .utf16BigEndian: return .utf16BigEndian
            case .windows1252: return .windowsCP1252
            }
        }
    }

    /// How many bytes of `data` are the start of a UTF-8 character that the data cuts off.
    static func incompleteUTF8SuffixLength(_ data: Data) -> Int {
        let bytes = [UInt8](data)
        for back in 1 ... min(3, bytes.count) {
            let byte = bytes[bytes.count - back]
            if byte & 0xC0 == 0x80 { continue }
            guard byte >= 0xC0 else { return 0 }
            let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
            return back < needed ? back : 0
        }
        return 0
    }

    /// How many bytes at the start of `data` continue a character that began before it.
    static func leadingContinuationLength(_ data: Data) -> Int {
        var count = 0
        for byte in data.prefix(3) {
            guard byte & 0xC0 == 0x80 else { break }
            count += 1
        }
        return count
    }

    /// The encoding of a file from its first bytes, and the length of its byte order mark,
    /// or nil if the bytes aren't text.
    ///
    /// - Parameter isWholeFile: Whether `sample` is the whole file.
    ///   A sample that is cut may end inside a character, and a whole file may not.
    static func detect(sample: Data, isWholeFile: Bool) -> (encoding: Encoding, bomLength: Int)? {
        let bytes = [UInt8](sample)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if bytes.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if bytes.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        if bytes.contains(0) { return nil }
        let complete = isWholeFile ? sample : sample.dropLast(incompleteUTF8SuffixLength(sample))
        if String(data: Data(complete), encoding: .utf8) != nil { return (.utf8, 0) }
        // Not UTF-8 and without NULs: text in a legacy encoding.
        if String(data: sample, encoding: .windowsCP1252) != nil { return (.windows1252, 0) }
        return nil
    }
}

// MARK: - Hashes and dates

enum FilesHash {
    /// The SHA-256 of a file's content, as lowercase hex, read in pieces.
    static func sha256(of url: URL, maximumBytes: Int = FilesLimits.maximumHashBytes) throws -> String {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maximumBytes else {
            throw FilesError.tooLarge("The file is \(size) bytes, over the \(maximumBytes) bytes that iMCP hashes.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().hex
    }

    /// The SHA-256 of what is left to read from a file descriptor, which is not closed.
    static func sha256(descriptor: Int32, size: Int, maximumBytes: Int = FilesLimits.maximumHashBytes) throws -> String
    {
        guard size <= maximumBytes else {
            throw FilesError.tooLarge("The file is \(size) bytes, over the \(maximumBytes) bytes that iMCP hashes.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().hex
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).hex
    }
}

extension Digest {
    fileprivate var hex: String { map { String(format: "%02x", $0) }.joined() }
}

enum FilesDate {
    /// A date as clients see it, with milliseconds so that it can be passed back as a precondition.
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parse(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    /// Whether two modification dates are the same to the millisecond, which is what clients are told.
    static func sameMillisecond(_ a: Date, _ b: Date) -> Bool {
        (a.timeIntervalSince1970 * 1000).rounded() == (b.timeIntervalSince1970 * 1000).rounded()
    }
}
