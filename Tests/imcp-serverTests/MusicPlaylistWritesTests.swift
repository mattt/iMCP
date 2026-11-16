import AppKit
import Foundation
import MCP
import XCTest

/// These tests send no Apple events to Music, and use a private `UserDefaults` suite.
final class MusicPlaylistWritesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MusicPlaylistWritesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - The setting

    func testPlaylistChangesStartOffAndOnlyAnExplicitChoiceTurnsThemOn() {
        XCTAssertFalse(MusicPlaylistWrites.isEnabled(defaults: defaults))
        XCTAssertThrowsError(try MusicPlaylistWrites.requireEnabled(defaults: defaults)) { error in
            XCTAssertEqual(error as? MusicPlaylistWriteError, .playlistWritesDisabled)
        }
        defaults.set(true, forKey: MusicPlaylistWrites.settingKey)
        XCTAssertNoThrow(try MusicPlaylistWrites.requireEnabled(defaults: defaults))
    }

    func testEveryPlaylistWriteToolIsAWriteAndThereIsNoDeleteTool() {
        let tools = MusicService.shared.tools
        let names = Set(tools.map(\.name))
        XCTAssertTrue(MusicPlaylistWrites.toolNames.isSubset(of: names))
        XCTAssertTrue(MusicPlaylistWrites.toolNames.isSubset(of: MusicService.shared.writeToolNames))
        XCTAssertFalse(names.contains { $0.contains("delete") })
        // The read tools stay available whatever the settings say.
        for name in ["music_playlists_list", "music_playlist_tracks"] {
            XCTAssertEqual(tools.first { $0.name == name }?.isWrite, false, name)
        }
    }

    // MARK: - Arguments

    func testNamesAreTrimmedAndLimited() throws {
        XCTAssertEqual(try MusicPlaylistWrites.validatedName("  Road trip \n"), "Road trip")
        XCTAssertThrowsError(try MusicPlaylistWrites.validatedName("   "))
        XCTAssertThrowsError(try MusicPlaylistWrites.validatedName("a\u{0}b"))
        XCTAssertThrowsError(try MusicPlaylistWrites.validatedName("a\tb"))
        XCTAssertThrowsError(
            try MusicPlaylistWrites.validatedName(
                String(repeating: "n", count: MusicPlaylistWrites.maximumNameLength + 1)
            )
        )
        XCTAssertNoThrow(
            try MusicPlaylistWrites.validatedName(String(repeating: "n", count: MusicPlaylistWrites.maximumNameLength))
        )
    }

    func testTrackIDsAreUppercasedAndDeduplicated() throws {
        let ids = try MusicPlaylistWrites.validatedTrackIDs(
            from: .array(["0123456789abcdef", "0123456789ABCDEF", "FEDCBA9876543210"])
        )
        XCTAssertEqual(ids, ["0123456789ABCDEF", "FEDCBA9876543210"])
    }

    func testBadTrackIDsAreRefused() {
        let tooMany = Value.array(
            (0 ..< MusicPlaylistWrites.maximumTracks + 1).map { .string(String(format: "%016X", $0)) }
        )
        for value: Value? in [
            nil, .null, .string("0123456789ABCDEF"), .array([]), .array([.int(1)]), .array(["short"]),
            .array(["0123456789ABCDEG"]), .array(["0123456789ABCDEF0"]), .array(["\" & (do shell script \"id\") & \""]),
            tooMany,
        ] {
            XCTAssertThrowsError(try MusicPlaylistWrites.validatedTrackIDs(from: value), "\(String(describing: value))")
        }
        XCTAssertNoThrow(
            try MusicPlaylistWrites.validatedTrackIDs(
                from: .array((0 ..< MusicPlaylistWrites.maximumTracks).map { .string(String(format: "%016X", $0)) })
            )
        )
    }

    // MARK: - Scripts

    /// A playlist name that tries to end its string and run a command stays an argument.
    func testCallerTextReachesTheScriptOnlyAsAnArgument() throws {
        let hostile = "x\" & (do shell script \"id\") & \"\n\\"
        let call = MusicPlaylistScripts.createPlaylist(name: hostile)
        XCTAssertEqual(call.parameters, [.string(hostile)])
        XCTAssertFalse(MusicPlaylistScripts.source.contains("do shell script"))

        let event = call.event()
        let arguments = try XCTUnwrap(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
        XCTAssertEqual(arguments.atIndex(1)?.stringValue, hostile)

        let ids = ["0123456789ABCDEF", "FEDCBA9876543210"]
        let add = MusicPlaylistScripts.addTracks(playlistID: "AAAAAAAAAAAAAAAA", trackIDs: ids)
        XCTAssertEqual(add.name, "addtracks")
        XCTAssertEqual(add.parameters, [.string("AAAAAAAAAAAAAAAA"), .strings(ids)])
        let list = try XCTUnwrap(add.event().paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.atIndex(2))
        XCTAssertEqual(list.numberOfItems, 2)
        XCTAssertEqual(list.atIndex(2)?.stringValue, "FEDCBA9876543210")
    }

    func testTheScriptNeverDeletesAPlaylistOrATrackFromTheLibrary() {
        let source = MusicPlaylistScripts.source
        // The only delete is of tracks of the playlist that was checked, never of a playlist or the library.
        let deletes = source.split(separator: "\n").filter { $0.contains("delete") }
        XCTAssertEqual(deletes.count, 1)
        XCTAssertTrue(deletes[0].contains("every track of thePlaylist whose persistent ID"), "\(deletes[0])")
        // Both editing handlers check that the playlist is a plain user playlist first.
        XCTAssertEqual(source.components(separatedBy: "my requireplain(thePlaylist)").count - 1, 2)
    }

    func testTheScriptCompilesWhereMusicIsInstalled() throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") != nil else {
            throw XCTSkip("Music isn't installed")
        }
        var errorInfo: NSDictionary?
        let script = try XCTUnwrap(NSAppleScript(source: MusicPlaylistScripts.source))
        XCTAssertTrue(script.compileAndReturnError(&errorInfo), String(describing: errorInfo))
    }

    // MARK: - Results

    func testAnswersAreShapedIntoValues() throws {
        func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
            let list = NSAppleEventDescriptor.list()
            for (index, item) in items.enumerated() { list.insert(item, at: index + 1) }
            return list
        }
        func text(_ string: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(string: string) }

        let answer = list([
            text("Road trip"), NSAppleEventDescriptor(int32: 3), NSAppleEventDescriptor(int32: 4),
            list([text("0123456789ABCDEF")]), list([text("FEDCBA9876543210")]),
        ])
        XCTAssertEqual(
            try MusicPlaylistResults.changed(from: answer, playlistID: "AAAAAAAAAAAAAAAA", changedKey: "added"),
            [
                "id": "AAAAAAAAAAAAAAAA", "name": "Road trip", "trackCountBefore": 3, "trackCountAfter": 4,
                "added": ["0123456789ABCDEF"], "notFound": ["FEDCBA9876543210"],
            ]
        )
        XCTAssertThrowsError(try MusicPlaylistResults.changed(from: list([]), playlistID: "A", changedKey: "added"))
        XCTAssertEqual(
            try MusicPlaylistResults.created(from: list([text("ID"), text("Mix")])),
            ["id": "ID", "name": "Mix", "trackCount": 0]
        )
    }
}
