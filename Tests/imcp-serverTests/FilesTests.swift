import Foundation
import MCP
import XCTest

/// These tests use temporary folders only.
final class FilesTests: XCTestCase {
    private var temporary: URL!
    /// The shared folder, `<temporary>/Shared`.
    private var shared: URL!
    /// A folder next to the shared one, whose name starts with the shared folder's name.
    private var sibling: URL!
    private var access: FilesAccess!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("imcp-files-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve /var to /private/var, as the app does for a shared folder.
        temporary = URL(fileURLWithPath: try XCTUnwrap(FilesAccess.realPath(base.path)))
        shared = temporary.appendingPathComponent("Shared")
        sibling = temporary.appendingPathComponent("Shared-private")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        access = FilesAccess(roots: [FilesRoot(name: "Shared", url: shared)])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private func write(_ text: String, to name: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? shared).appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func text(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func link(_ name: String, to target: URL) throws {
        try FileManager.default.createSymbolicLink(
            at: shared.appendingPathComponent(name),
            withDestinationURL: target
        )
    }

    private func assertRefused(
        _ path: String,
        _ expected: (FilesError) -> Bool,
        followingFinalSymlink: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try access.resolve(path, followingFinalSymlink: followingFinalSymlink),
            file: file,
            line: line
        ) {
            guard let error = $0 as? FilesError else { return XCTFail("\($0)", file: file, line: line) }
            XCTAssertTrue(expected(error), "\(error)", file: file, line: line)
        }
    }

    // MARK: - Confinement

    func testResolvesPathsInsideTheSharedFolder() throws {
        _ = try write("a", to: "a.txt")
        let file = try access.resolve("Shared/a.txt")
        XCTAssertEqual(file.url, shared.appendingPathComponent("a.txt"))
        XCTAssertEqual(file.displayPath, "Shared/a.txt")
        XCTAssertTrue(try access.resolve("Shared").isRoot)
        XCTAssertEqual(try access.resolve("Shared/./a.txt").displayPath, "Shared/a.txt")
        // A file that doesn't exist yet resolves, so that it can be created.
        XCTAssertEqual(try access.resolve("Shared/new/deeper.txt").url, shared.appendingPathComponent("new/deeper.txt"))
    }

    func testRefusesParentComponentsAndAbsolutePaths() {
        assertRefused("Shared/../Shared-private/x") { if case .invalidPath = $0 { true } else { false } }
        assertRefused("Shared/a/../../x") { if case .invalidPath = $0 { true } else { false } }
        assertRefused("/etc/passwd") { if case .invalidPath = $0 { true } else { false } }
        assertRefused("~/Documents") { if case .invalidPath = $0 { true } else { false } }
        assertRefused("") { if case .invalidPath = $0 { true } else { false } }
        assertRefused("Shared/a\0b") { if case .invalidPath = $0 { true } else { false } }
    }

    func testRefusesAFolderThatIsNotShared() {
        assertRefused("Shared-private/x") { if case .unknownFolder = $0 { true } else { false } }
        assertRefused("shared/x") { if case .unknownFolder = $0 { true } else { false } }
        XCTAssertThrowsError(try FilesAccess(roots: []).resolve("Shared/x")) {
            XCTAssertEqual($0 as? FilesError, .noFolders)
        }
    }

    func testRefusesASymlinkToAPlaceOutsideTheSharedFolder() throws {
        let outside = try write("secret", to: "secret.txt", in: sibling)
        try link("to-file", to: outside)
        try link("to-folder", to: sibling)
        try link("to-etc", to: URL(fileURLWithPath: "/etc"))
        assertRefused("Shared/to-file") { if case .escapesFolder = $0 { true } else { false } }
        assertRefused("Shared/to-folder/secret.txt") { if case .escapesFolder = $0 { true } else { false } }
        // Creating a file through a link to an outside folder is refused as well.
        assertRefused("Shared/to-folder/new.txt") { if case .escapesFolder = $0 { true } else { false } }
        assertRefused("Shared/to-etc/hosts") { if case .escapesFolder = $0 { true } else { false } }
        // Nothing was created outside.
        XCTAssertFalse(FileManager.default.fileExists(atPath: sibling.appendingPathComponent("new.txt").path))
    }

    func testAllowsASymlinkThatStaysInside() throws {
        _ = try write("a", to: "a.txt")
        try link("inside", to: shared.appendingPathComponent("a.txt"))
        XCTAssertEqual(try access.resolve("Shared/inside").url, shared.appendingPathComponent("a.txt"))
    }

    func testRefusesADanglingSymlink() throws {
        try link("dangling", to: shared.appendingPathComponent("missing.txt"))
        assertRefused("Shared/dangling") { if case .danglingSymlink = $0 { true } else { false } }
        // Moving or trashing acts on the link, which is inside the folder.
        let item = try access.resolve("Shared/dangling", followingFinalSymlink: false)
        XCTAssertEqual(item.url, shared.appendingPathComponent("dangling"))
    }

    func testActingOnALinkDoesNotFollowItOutside() throws {
        let outside = try write("secret", to: "secret.txt", in: sibling)
        try link("to-file", to: outside)
        let item = try access.resolve("Shared/to-file", followingFinalSymlink: false)
        XCTAssertEqual(item.url, shared.appendingPathComponent("to-file"))
        // Trashing it removes the link and leaves what it points to.
        XCTAssertThrowsError(try access.resolve("Shared/to-file/../x"))
    }

    func testRefusesARootThatMovedOrBecameALink() throws {
        let moved = FilesAccess(roots: [FilesRoot(name: "Gone", url: temporary.appendingPathComponent("Gone"))])
        XCTAssertThrowsError(try moved.resolve("Gone/x")) {
            XCTAssertEqual($0 as? FilesError, .folderUnavailable("Gone"))
        }
        let alias = temporary.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: shared)
        let linked = FilesAccess(roots: [FilesRoot(name: "Alias", url: alias)])
        XCTAssertThrowsError(try linked.resolve("Alias/x")) {
            XCTAssertEqual($0 as? FilesError, .folderUnavailable("Alias"))
        }
    }

    // MARK: - Photos libraries

    func testRefusesAPhotosLibraryAndWhatIsInsideIt() throws {
        let library = shared.appendingPathComponent("Photos Library.photoslibrary")
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("database"),
            withIntermediateDirectories: true
        )
        _ = try write("db", to: "Photos.sqlite", in: library.appendingPathComponent("database"))
        for path in [
            "Shared/Photos Library.photoslibrary",
            "Shared/Photos Library.photoslibrary/database/Photos.sqlite",
            "Shared/Other.PhotosLibrary/x",
            "Shared/Photos Library.photoslibrary/new.txt",
        ] {
            assertRefused(path) { if case .photosLibrary = $0 { true } else { false } }
        }
        // A link inside the folder to a library inside the folder is refused after resolution.
        try link("shortcut", to: library)
        assertRefused("Shared/shortcut/database") { if case .photosLibrary = $0 { true } else { false } }
        assertRefused("Shared/shortcut") { if case .photosLibrary = $0 { true } else { false } }
    }

    func testListingAndSearchSkipPhotosLibraries() throws {
        let library = shared.appendingPathComponent("Photos Library.photoslibrary")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        _ = try write("needle", to: "inside.txt", in: library)
        _ = try write("needle", to: "outside.txt")

        let listing = try FilesOperations.list(
            try access.resolve("Shared"),
            glob: nil,
            includeHidden: false,
            offset: 0,
            limit: 100
        )
        XCTAssertEqual(
            listing.objectValue?["entries"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue },
            ["outside.txt"]
        )

        let result = try FilesOperations.search(
            in: [try access.resolve("Shared")],
            name: nil,
            content: "needle",
            includeHidden: false,
            limit: 10,
            seconds: 5
        )
        XCTAssertEqual(result.objectValue?["matches"]?.arrayValue?.count, 1)
    }

    func testTheStoreRefusesToShareAPhotosLibrary() throws {
        let suite = "imcp-files-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FilesRootStore(defaults: defaults)

        let library = shared.appendingPathComponent("Photos Library.photoslibrary")
        let inside = library.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        for url in [library, inside] {
            XCTAssertThrowsError(try store.add(url)) {
                guard case FilesRootStore.AddError.photosLibrary = $0 else { return XCTFail("\($0)") }
            }
        }
        // A link to a library is refused after it is resolved.
        try link("shortcut", to: library)
        XCTAssertThrowsError(try store.add(shared.appendingPathComponent("shortcut")))
        XCTAssertThrowsError(try store.add(URL(fileURLWithPath: "/"))) {
            guard case FilesRootStore.AddError.wholeDisk = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(store.grants().isEmpty)
    }

    func testUniqueNamesForFoldersWithTheSameName() {
        XCTAssertEqual(FilesRootStore.uniqueName("Docs", among: []), "Docs")
        XCTAssertEqual(FilesRootStore.uniqueName("Docs", among: ["Docs"]), "Docs 2")
        XCTAssertEqual(FilesRootStore.uniqueName("Docs", among: ["Docs", "Docs 2"]), "Docs 3")
    }

    // MARK: - Listing and paging

    func testPagingCoversEveryItemOnce() {
        let items = Array(1 ... 7)
        var seen: [Int] = []
        var offset = 0
        while true {
            let page = FilesPaging.page(of: items, offset: offset, limit: 3)
            seen += page.items
            guard let next = page.nextOffset else { break }
            offset = next
        }
        XCTAssertEqual(seen, items)
        XCTAssertNil(FilesPaging.page(of: items, offset: 4, limit: 3).nextOffset)
        XCTAssertEqual(FilesPaging.page(of: items, offset: 99, limit: 3).items, [])
    }

    func testListingPagesSortsAndFilters() throws {
        for name in ["b.md", "a.md", "C.txt", ".hidden.md", "d.md"] { _ = try write("x", to: name) }
        try FileManager.default.createDirectory(
            at: shared.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )
        let directory = try access.resolve("Shared")

        func names(_ value: Value) -> [String] {
            value.objectValue?["entries"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? []
        }
        let first = try FilesOperations.list(directory, glob: nil, includeHidden: false, offset: 0, limit: 3)
        XCTAssertEqual(names(first), ["a.md", "b.md", "C.txt"])
        XCTAssertEqual(first.objectValue?["total"], .int(5))
        XCTAssertEqual(first.objectValue?["nextOffset"], .int(3))
        let second = try FilesOperations.list(directory, glob: nil, includeHidden: false, offset: 3, limit: 3)
        XCTAssertEqual(names(second), ["d.md", "sub"])
        XCTAssertEqual(second.objectValue?["nextOffset"], .null)

        let markdown = try FilesOperations.list(directory, glob: "*.MD", includeHidden: false, offset: 0, limit: 10)
        XCTAssertEqual(names(markdown), ["a.md", "b.md", "d.md"])
        let hidden = try FilesOperations.list(directory, glob: "*.md", includeHidden: true, offset: 0, limit: 10)
        XCTAssertEqual(names(hidden), [".hidden.md", "a.md", "b.md", "d.md"])
    }

    func testListingAFileIsAnError() throws {
        _ = try write("x", to: "a.txt")
        XCTAssertThrowsError(
            try FilesOperations.list(
                try access.resolve("Shared/a.txt"),
                glob: nil,
                includeHidden: false,
                offset: 0,
                limit: 5
            )
        ) { XCTAssertEqual($0 as? FilesError, .notADirectory("Shared/a.txt")) }
    }

    // MARK: - Reading

    private func read(
        _ path: String,
        offset: Int = 0,
        maxBytes: Int = FilesLimits.defaultReadBytes,
        format: FilesOperations.ReadFormat = .auto
    ) throws -> [String: Value] {
        try FilesOperations.read(try access.resolve(path), offset: offset, maxBytes: maxBytes, format: format)
            .objectValue ?? [:]
    }

    func testReadsTextAndFlagsTruncation() throws {
        _ = try write("hello world", to: "a.txt")
        let whole = try read("Shared/a.txt")
        XCTAssertEqual(whole["content"], "hello world")
        XCTAssertEqual(whole["truncated"], false)
        XCTAssertEqual(whole["nextOffset"], .null)

        let part = try read("Shared/a.txt", maxBytes: 5)
        XCTAssertEqual(part["content"], "hello")
        XCTAssertEqual(part["truncated"], true)
        XCTAssertEqual(part["nextOffset"], .int(5))
        let rest = try read("Shared/a.txt", offset: 5, maxBytes: 100)
        XCTAssertEqual(rest["content"], " world")
        XCTAssertEqual(rest["truncated"], false)
    }

    func testAWindowNeverSplitsACharacter() throws {
        // Each "é" is two bytes, and each "😀" four.
        let text = "aé😀bé😀c"
        _ = try write(text, to: "u.txt")
        var collected = ""
        var offset = 0
        for _ in 0 ..< 20 {
            let result = try read("Shared/u.txt", offset: offset, maxBytes: 3)
            collected += result["content"]?.stringValue ?? ""
            guard case .int(let next) = result["nextOffset"] ?? .null else { break }
            XCTAssertGreaterThan(next, offset)
            offset = next
        }
        XCTAssertEqual(collected, text)
    }

    func testDecodesTextWithAByteOrderMarkAndLegacyText() throws {
        let utf16 = Data([0xFF, 0xFE]) + (try XCTUnwrap("hi é".data(using: .utf16LittleEndian)))
        try utf16.write(to: shared.appendingPathComponent("u16.txt"))
        let decoded = try read("Shared/u16.txt")
        XCTAssertEqual(decoded["content"], "hi é")
        XCTAssertEqual(decoded["encoding"], "utf-16le")

        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: shared.appendingPathComponent("legacy.txt"))
        let legacy = try read("Shared/legacy.txt")
        XCTAssertEqual(legacy["content"], "café")
        XCTAssertEqual(legacy["encoding"], "windows1252")
    }

    func testBinaryFilesAreReturnedAsBase64WithinTheCapAndRefusedBeyondIt() throws {
        let small = Data([0, 1, 2, 255, 0])
        try small.write(to: shared.appendingPathComponent("small.bin"))
        let result = try read("Shared/small.bin")
        XCTAssertEqual(result["format"], "base64")
        XCTAssertEqual(result["content"], .string(small.base64EncodedString()))

        try Data(count: FilesLimits.maximumBinaryBytes + 1).write(to: shared.appendingPathComponent("big.bin"))
        XCTAssertThrowsError(try read("Shared/big.bin")) {
            guard case FilesError.binaryFile(_, let size, let limit) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(size, FilesLimits.maximumBinaryBytes + 1)
            XCTAssertEqual(limit, FilesLimits.maximumBinaryBytes)
            XCTAssertTrue(($0 as? FilesError)?.errorDescription?.contains("base64") ?? false)
        }
        let piece = try read("Shared/big.bin", offset: FilesLimits.maximumBinaryBytes - 2, format: .base64)
        XCTAssertEqual(piece["bytesRead"], .int(3))
        XCTAssertEqual(piece["truncated"], false)
        XCTAssertThrowsError(try read("Shared/small.bin", format: .text))
    }

    // MARK: - Writing

    private func writeFile(
        _ path: String,
        _ content: String,
        overwrite: Bool = false,
        precondition: FilesOperations.Precondition = .init()
    ) throws -> [String: Value] {
        try FilesOperations.write(
            try access.resolve(path),
            content: content,
            overwrite: overwrite,
            precondition: precondition
        ).objectValue ?? [:]
    }

    func testWriteCreatesAFileAndRefusesToReplaceOneByDefault() throws {
        let created = try writeFile("Shared/new.txt", "one")
        XCTAssertEqual(created["created"], true)
        XCTAssertEqual(created["sha256"], .string(FilesHash.sha256(of: Data("one".utf8))))
        XCTAssertThrowsError(try writeFile("Shared/new.txt", "two")) {
            XCTAssertEqual($0 as? FilesError, .alreadyExists("Shared/new.txt"))
        }
        XCTAssertEqual(try text(at: shared.appendingPathComponent("new.txt")), "one")

        let replaced = try writeFile("Shared/new.txt", "two", overwrite: true)
        XCTAssertEqual(replaced["created"], false)
        XCTAssertEqual(try text(at: shared.appendingPathComponent("new.txt")), "two")
    }

    func testWriteChecksTheModifiedDate() throws {
        let url = try write("v1", to: "doc.txt")
        let stat = try FilesOperations.stat(try access.resolve("Shared/doc.txt"), isSymlink: false, includeHash: false)
        let modified = try XCTUnwrap(FilesDate.parse(try XCTUnwrap(stat.objectValue?["modified"]?.stringValue)))

        // Someone else edits the file after it was read.
        let later = modified.addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
        XCTAssertThrowsError(try writeFile("Shared/doc.txt", "mine", precondition: .init(modified: modified))) {
            guard case FilesError.changedSinceRead = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try text(at: url), "v1")

        // With the date as it is now, the write goes through, and a date passed back from stat matches.
        _ = try writeFile("Shared/doc.txt", "mine", precondition: .init(modified: later))
        XCTAssertEqual(try text(at: url), "mine")
    }

    func testWriteChecksTheHash() throws {
        let url = try write("v1", to: "doc.txt")
        let stale = FilesHash.sha256(of: Data("v0".utf8))
        XCTAssertThrowsError(try writeFile("Shared/doc.txt", "mine", precondition: .init(sha256: stale)))
        XCTAssertEqual(try text(at: url), "v1")

        let current = try FilesHash.sha256(of: url)
        XCTAssertEqual(current, FilesHash.sha256(of: Data("v1".utf8)))
        _ = try writeFile("Shared/doc.txt", "mine", precondition: .init(sha256: current.uppercased().lowercased()))
        XCTAssertEqual(try text(at: url), "mine")
    }

    func testAPreconditionOnAMissingFileIsRefused() throws {
        XCTAssertThrowsError(
            try writeFile("Shared/gone.txt", "x", precondition: .init(sha256: FilesHash.sha256(of: Data())))
        ) {
            guard case FilesError.changedSinceRead = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("gone.txt").path))
    }

    func testWriteRefusesTooMuchAndMissingFolders() throws {
        let large = String(repeating: "x", count: FilesLimits.maximumWriteBytes + 1)
        XCTAssertThrowsError(try writeFile("Shared/large.txt", large)) {
            guard case FilesError.tooLarge = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try writeFile("Shared/missing/new.txt", "x")) {
            guard case FilesError.notFound = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try writeFile("Shared", "x", overwrite: true))
    }

    func testAppendAndMakeDirectory() throws {
        _ = try write("a", to: "log.txt")
        let result = try FilesOperations.append(
            try access.resolve("Shared/log.txt"),
            content: "b",
            createIfMissing: false
        )
        XCTAssertEqual(result.objectValue?["size"], .int(2))
        XCTAssertEqual(try text(at: shared.appendingPathComponent("log.txt")), "ab")
        XCTAssertThrowsError(
            try FilesOperations.append(try access.resolve("Shared/none.txt"), content: "b", createIfMissing: false)
        )
        _ = try FilesOperations.append(try access.resolve("Shared/none.txt"), content: "b", createIfMissing: true)

        let made = try FilesOperations.makeDirectory(try access.resolve("Shared/a/b/c"))
        XCTAssertEqual(made.objectValue?["created"], true)
        let again = try FilesOperations.makeDirectory(try access.resolve("Shared/a/b/c"))
        XCTAssertEqual(again.objectValue?["created"], false)
        XCTAssertThrowsError(try FilesOperations.makeDirectory(try access.resolve("Shared/log.txt")))
    }

    // MARK: - Moving and trashing

    func testMoveStaysInsideTheSharedFoldersAndNeverReplaces() throws {
        let other = temporary.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let both = FilesAccess(roots: access.roots + [FilesRoot(name: "Other", url: other)])

        _ = try write("a", to: "a.txt")
        _ = try write("b", to: "b.txt")
        func move(_ from: String, _ to: String) throws -> Value {
            try FilesOperations.move(
                try both.resolve(from, followingFinalSymlink: false),
                to: try both.resolve(to, followingFinalSymlink: false)
            )
        }
        XCTAssertThrowsError(try move("Shared/a.txt", "Shared/b.txt")) {
            XCTAssertEqual($0 as? FilesError, .alreadyExists("Shared/b.txt"))
        }
        XCTAssertThrowsError(try move("Shared/a.txt", "Shared/../x.txt"))
        XCTAssertThrowsError(try move("Shared/a.txt", "Shared-private/a.txt"))
        XCTAssertThrowsError(try move("Shared", "Other/Shared"))
        XCTAssertThrowsError(try move("Shared/a.txt", "Shared/missing/a.txt"))

        _ = try move("Shared/a.txt", "Other/moved.txt")
        XCTAssertEqual(try text(at: other.appendingPathComponent("moved.txt")), "a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("a.txt").path))

        try FileManager.default.createDirectory(
            at: shared.appendingPathComponent("dir"),
            withIntermediateDirectories: true
        )
        XCTAssertThrowsError(try move("Shared/dir", "Shared/dir/inner"))
    }

    func testMovingALinkMovesTheLinkNotItsTarget() throws {
        let outside = try write("secret", to: "secret.txt", in: sibling)
        try link("to-file", to: outside)
        _ = try FilesOperations.move(
            try access.resolve("Shared/to-file", followingFinalSymlink: false),
            to: try access.resolve("Shared/renamed", followingFinalSymlink: false)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertNotNil(
            try? FileManager.default.destinationOfSymbolicLink(atPath: shared.appendingPathComponent("renamed").path)
        )
    }

    func testTrashRefusesASharedFolderAndAMissingItem() throws {
        XCTAssertThrowsError(try FilesOperations.trash(try access.resolve("Shared"))) {
            guard case FilesError.invalidPath = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try FilesOperations.trash(try access.resolve("Shared/none.txt"))) {
            XCTAssertEqual($0 as? FilesError, .notFound("Shared/none.txt"))
        }
    }

    // MARK: - Searching

    func testSearchFindsNamesAndContentWithLimits() throws {
        try FileManager.default.createDirectory(
            at: shared.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )
        _ = try write("alpha\nNeedle one\n", to: "a.txt")
        _ = try write("Needle two\nNeedle three", to: "b.txt", in: shared.appendingPathComponent("sub"))
        try Data([0, 1, 2]).write(to: shared.appendingPathComponent("blob.bin"))
        _ = try write("needle hidden", to: ".secret.txt")

        func search(name: String? = nil, content: String? = nil, limit: Int = 10, hidden: Bool = false) throws
            -> [String: Value]
        {
            try FilesOperations.search(
                in: [try access.resolve("Shared")],
                name: name,
                content: content,
                includeHidden: hidden,
                limit: limit,
                seconds: 5
            ).objectValue ?? [:]
        }
        func paths(_ result: [String: Value]) -> [String] {
            (result["matches"]?.arrayValue ?? []).compactMap { $0.objectValue?["path"]?.stringValue }.sorted()
        }

        XCTAssertEqual(paths(try search(name: "b")), ["Shared/blob.bin", "Shared/sub", "Shared/sub/b.txt"])
        XCTAssertEqual(paths(try search(name: "*.TXT")), ["Shared/a.txt", "Shared/sub/b.txt"])
        let content = try search(content: "needle")
        XCTAssertEqual(paths(content), ["Shared/a.txt", "Shared/sub/b.txt", "Shared/sub/b.txt"])
        XCTAssertEqual(content["truncated"], false)
        XCTAssertEqual(try search(content: "needle", hidden: true)["matches"]?.arrayValue?.count, 4)

        // truncated reports a match that was left out, not just that the limit was reached.
        XCTAssertEqual(try search(content: "needle", limit: 2)["truncated"], true)
        XCTAssertEqual(try search(content: "needle", limit: 3)["truncated"], false)
    }

    func testSearchStopsWhenItsTimeBudgetEnds() throws {
        for index in 0 ..< 5 { _ = try write("x", to: "f\(index).txt") }
        var ticks = 0
        let result = try FilesOperations.search(
            in: [try access.resolve("Shared")],
            name: "f",
            content: nil,
            includeHidden: false,
            limit: 100,
            seconds: 1,
            now: {
                ticks += 1
                return Date(timeIntervalSince1970: ticks <= 2 ? 0 : 100)
            }
        )
        XCTAssertEqual(result.objectValue?["timedOut"], true)
        XCTAssertLessThan(result.objectValue?["matches"]?.arrayValue?.count ?? 99, 5)
    }

    func testSearchDoesNotFollowLinksOutOfTheSharedFolder() throws {
        _ = try write("needle", to: "secret.txt", in: sibling)
        try link("out", to: sibling)
        let result = try FilesOperations.search(
            in: [try access.resolve("Shared")],
            name: nil,
            content: "needle",
            includeHidden: false,
            limit: 10,
            seconds: 5
        )
        XCTAssertEqual(result.objectValue?["matches"]?.arrayValue?.count, 0)
    }

    // MARK: - The setting

    private struct FixedFolders: FilesRootProviding {
        var access: FilesAccess
        func statuses() -> [FilesRootStatus] {
            access.roots.map { FilesRootStatus(name: $0.name, path: $0.url.path, state: .available) }
        }
        func withAccess<T>(_ body: (FilesAccess) throws -> T) throws -> T { try body(access) }
    }

    func testToolsThatChangeFilesAreListedOnlyWhileTheSettingIsOn() {
        for name in FilesTools.readToolNames {
            XCTAssertTrue(FilesTools.isListed(name, writesEnabled: false), name)
        }
        for name in FilesTools.writeToolNames {
            XCTAssertFalse(FilesTools.isListed(name, writesEnabled: false), name)
            XCTAssertTrue(FilesTools.isListed(name, writesEnabled: true), name)
        }
        let tools = FilesTools.tools(provider: FixedFolders(access: access), isEnabled: { false })
        XCTAssertEqual(Set(tools.map(\.name)), FilesTools.readToolNames.union(FilesTools.writeToolNames))
        for tool in tools {
            let isRead = FilesTools.readToolNames.contains(tool.name)
            XCTAssertEqual(tool.annotations.readOnlyHint ?? false, isRead, tool.name)
        }
        XCTAssertEqual(tools.first { $0.name == "files_trash" }?.annotations.destructiveHint, true)
    }

    func testAToolThatChangesFilesDoesNothingWhileTheSettingIsOff() async throws {
        let off = FilesTools.tools(provider: FixedFolders(access: access), isEnabled: { false })
        let write = try XCTUnwrap(off.first { $0.name == "files_write" })
        do {
            _ = try await write(["path": "Shared/new.txt", "content": "x"])
            XCTFail("The write should be refused")
        } catch {
            XCTAssertEqual(error as? FilesError, .writesDisabled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("new.txt").path))

        let on = FilesTools.tools(provider: FixedFolders(access: access), isEnabled: { true })
        let enabled = try XCTUnwrap(on.first { $0.name == "files_write" })
        let result = try await enabled(["path": "Shared/new.txt", "content": "x"])
        XCTAssertEqual(result.objectValue?["created"], true)
        XCTAssertEqual(try text(at: shared.appendingPathComponent("new.txt")), "x")

        // Reading works either way.
        let list = try XCTUnwrap(off.first { $0.name == "files_list" })
        let listing = try await list(["path": "Shared"])
        XCTAssertEqual(listing.objectValue?["total"], .int(1))
    }
}
