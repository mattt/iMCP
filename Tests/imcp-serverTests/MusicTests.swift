import Foundation
import XCTest

final class MusicTests: XCTestCase {
    private typealias SearchType = MusicService.CatalogSearchType

    // MARK: - Search types

    func testAbsentOrNullTypesSelectTheDefaultSearch() throws {
        XCTAssertNil(try MusicService.requestedSearchTypes(from: nil))
        XCTAssertNil(try MusicService.requestedSearchTypes(from: .null))

        let resolved = MusicService.resolveSearchTypes(from: nil)
        XCTAssertEqual(resolved.types, [.songs, .albums, .artists, .playlists])
        XCTAssertFalse(resolved.includeTopResults)
    }

    func testEmptyTypesArrayIsAnError() {
        XCTAssertThrowsError(try MusicService.requestedSearchTypes(from: .array([]))) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("must not be empty"),
                error.localizedDescription
            )
        }
    }

    func testUnknownOrMistypedTypesAreErrors() {
        XCTAssertThrowsError(try MusicService.requestedSearchTypes(from: .array(["podcasts"])))
        XCTAssertThrowsError(try MusicService.requestedSearchTypes(from: .array([.int(1)])))
        XCTAssertThrowsError(try MusicService.requestedSearchTypes(from: .string("songs")))
    }

    func testRequestedTypesKeepTheirOrder() throws {
        let requested = try MusicService.requestedSearchTypes(
            from: .array(["stations", "songs", "songs"])
        )
        XCTAssertEqual(requested, [.stations, .songs, .songs])

        let resolved = MusicService.resolveSearchTypes(from: requested)
        XCTAssertEqual(resolved.types, [.stations, .songs])
        XCTAssertFalse(resolved.includeTopResults)
    }

    func testTopResultsIsAnOptionRatherThanAType() throws {
        let mixed = MusicService.resolveSearchTypes(from: [.albums, .topResults])
        XCTAssertEqual(mixed.types, [.albums])
        XCTAssertTrue(mixed.includeTopResults)

        let onlyTopResults = MusicService.resolveSearchTypes(from: [.topResults])
        XCTAssertEqual(onlyTopResults.types, SearchType.defaultTypes)
        XCTAssertTrue(onlyTopResults.includeTopResults)
        XCTAssertNil(SearchType.topResults.searchableType)
        XCTAssertTrue(
            SearchType.allCases.filter { $0 != .topResults }.allSatisfy { $0.searchableType != nil }
        )
    }

    // MARK: - Seek

    func testSeekRejectsNonFinitePositions() {
        for position in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try MusicService.seekPosition(position, duration: 200))
            XCTAssertThrowsError(try MusicService.seekPosition(position, duration: nil))
        }
    }

    func testSeekClampsToTheTrackDuration() throws {
        XCTAssertEqual(try MusicService.seekPosition(-5, duration: 200), 0)
        XCTAssertEqual(try MusicService.seekPosition(42.5, duration: 200), 42.5)
        XCTAssertEqual(try MusicService.seekPosition(500, duration: 200), 200)
        XCTAssertEqual(try MusicService.seekPosition(.greatestFiniteMagnitude, duration: 200), 200)
    }

    /// Compiling reads the Music dictionary but runs nothing.
    func testSeekReadsTheDurationAndSeeksInOneScript() throws {
        let script = try MusicService.seekScript(position: 90)
        XCTAssertTrue(script.contains("set targetPosition to 90.000"), script)
        XCTAssertTrue(script.contains("set trackDuration to duration of current track"), script)
        XCTAssertTrue(script.contains("set player position to targetPosition"), script)
        XCTAssertEqual(script.components(separatedBy: "tell application").count - 1, 1, script)

        XCTAssertTrue(try MusicService.seekScript(position: -5).contains("set targetPosition to 0.000"))
        XCTAssertTrue(
            try MusicService.seekScript(position: 1e12).contains(
                "set targetPosition to \(MusicService.appleScriptNumber(MusicService.maximumSeekPosition))"
            )
        )
        XCTAssertThrowsError(try MusicService.seekScript(position: .nan))

        var errorInfo: NSDictionary?
        XCTAssertTrue(
            try XCTUnwrap(NSAppleScript(source: script)).compileAndReturnError(&errorInfo),
            String(describing: errorInfo)
        )
    }

    func testSeekClampsToTheMaximumWithoutAUsableDuration() throws {
        let maximum = MusicService.maximumSeekPosition
        XCTAssertEqual(try MusicService.seekPosition(1e300, duration: nil), maximum)
        XCTAssertEqual(try MusicService.seekPosition(1e300, duration: 0), maximum)
        XCTAssertEqual(try MusicService.seekPosition(1e300, duration: .infinity), maximum)
        XCTAssertEqual(try MusicService.seekPosition(1e300, duration: .nan), maximum)
        XCTAssertEqual(try MusicService.seekPosition(1e300, duration: maximum * 2), maximum)
        XCTAssertEqual(try MusicService.seekPosition(60, duration: nil), 60)
    }

    func testAppleScriptNumbersUsePlainDecimalNotation() throws {
        XCTAssertEqual(MusicService.appleScriptNumber(0), "0.000")
        XCTAssertEqual(MusicService.appleScriptNumber(-0.0), "0.000")
        XCTAssertEqual(MusicService.appleScriptNumber(90), "90.000")
        XCTAssertEqual(MusicService.appleScriptNumber(12.3456), "12.346")
        XCTAssertEqual(MusicService.appleScriptNumber(1e-7), "0.000")
        XCTAssertEqual(
            MusicService.appleScriptNumber(MusicService.maximumSeekPosition),
            "86400.000"
        )

        let clamped = try MusicService.seekPosition(1e300, duration: nil)
        let text = MusicService.appleScriptNumber(clamped)
        XCTAssertFalse(text.contains("e"), text)
        XCTAssertFalse(text.contains(","), text)
    }

    // MARK: - Integer arguments

    func testExactIntAcceptsIntegersAndWholeDoubles() {
        XCTAssertEqual(MusicService.exactInt(from: .int(25)), 25)
        XCTAssertEqual(MusicService.exactInt(from: .double(25)), 25)
        XCTAssertEqual(MusicService.exactInt(from: .double(-3)), -3)
    }

    func testExactIntRejectsFractionsOutOfRangeValuesAndOtherTypes() {
        XCTAssertNil(MusicService.exactInt(from: .double(2.5)))
        XCTAssertNil(MusicService.exactInt(from: .double(1e300)))
        XCTAssertNil(MusicService.exactInt(from: .double(.nan)))
        XCTAssertNil(MusicService.exactInt(from: .double(.infinity)))
        XCTAssertNil(MusicService.exactInt(from: .string("10")))
        XCTAssertNil(MusicService.exactInt(from: .bool(true)))
        XCTAssertNil(MusicService.exactInt(from: .null))
    }

    // MARK: - Playlists

    func testPlaylistIDsMustBePersistentIDs() throws {
        XCTAssertEqual(
            try MusicService.playlistID(from: .string("A0B8C1E7B52DD217")),
            "A0B8C1E7B52DD217"
        )
        XCTAssertEqual(
            try MusicService.playlistID(from: .string("a0b8c1e7b52dd217")),
            "A0B8C1E7B52DD217"
        )

        for value: Value? in [
            nil, .null, .string(""), .string("A0B8C1E7B52DD21"), .string("A0B8C1E7B52DD2170"),
            .string("G0B8C1E7B52DD217"), .string("\" & quit & \""), .int(1),
        ] {
            XCTAssertThrowsError(try MusicService.playlistID(from: value), String(describing: value))
        }
    }

    func testPlaylistTrackPageDefaultsAndBounds() throws {
        let defaults = try MusicService.playlistTrackPage(from: [:])
        XCTAssertEqual(defaults.offset, 0)
        XCTAssertEqual(defaults.limit, 100)

        let page = try MusicService.playlistTrackPage(from: ["offset": .int(200), "limit": .double(500)])
        XCTAssertEqual(page.offset, 200)
        XCTAssertEqual(page.limit, 500)

        XCTAssertThrowsError(try MusicService.playlistTrackPage(from: ["limit": .int(0)]))
        XCTAssertThrowsError(try MusicService.playlistTrackPage(from: ["limit": .int(501)]))
        XCTAssertThrowsError(try MusicService.playlistTrackPage(from: ["limit": .string("10")]))
        XCTAssertThrowsError(try MusicService.playlistTrackPage(from: ["offset": .int(-1)]))
        XCTAssertThrowsError(try MusicService.playlistTrackPage(from: ["offset": .double(1.5)]))
    }

    func testPlaylistTrackPageRejectsOffsetsThatWouldOverflow() throws {
        XCTAssertThrowsError(try MusicService.playlistTrackPage(from: ["offset": .int(Int.max)]))
        for limit in [1, 100, 500] {
            XCTAssertThrowsError(
                try MusicService.playlistTrackPage(from: [
                    "offset": .int(Int.max - limit + 1), "limit": .int(limit),
                ])
            )
            let page = try MusicService.playlistTrackPage(from: [
                "offset": .int(Int.max - limit), "limit": .int(limit),
            ])
            XCTAssertNil(
                MusicService.nextPlaylistTrackOffset(
                    offset: page.offset,
                    limit: page.limit,
                    total: Int.max
                )
            )
            XCTAssertTrue(
                MusicService.playlistTracksScript(
                    id: "A0B8C1E7B52DD217",
                    offset: page.offset,
                    limit: page.limit
                ).contains("set lastIndex to \(Int.max)")
            )
        }
    }

    func testNextPlaylistTrackOffsetStopsAtTheEnd() {
        XCTAssertEqual(MusicService.nextPlaylistTrackOffset(offset: 0, limit: 100, total: 607), 100)
        XCTAssertEqual(MusicService.nextPlaylistTrackOffset(offset: 500, limit: 100, total: 607), 600)
        XCTAssertNil(MusicService.nextPlaylistTrackOffset(offset: 600, limit: 100, total: 607))
        XCTAssertNil(MusicService.nextPlaylistTrackOffset(offset: 0, limit: 100, total: 100))
        XCTAssertNil(MusicService.nextPlaylistTrackOffset(offset: 700, limit: 100, total: 607))
        XCTAssertNil(MusicService.nextPlaylistTrackOffset(offset: 0, limit: 100, total: 0))
    }

    func testPlaylistTracksEncodeNextOffset() throws {
        for (offset, total) in [(600, 607), (0, 0), (700, 607), (0, 607)] {
            let nextOffset = MusicService.nextPlaylistTrackOffset(
                offset: offset,
                limit: 100,
                total: total
            )
            let response = MusicPlaylistTracks(
                id: "A0B8C1E7B52DD217",
                name: "Library",
                total: total,
                offset: offset,
                nextOffset: nextOffset,
                tracks: []
            )
            let data = try JSONEncoder().encode(response)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if let nextOffset {
                XCTAssertEqual(json["nextOffset"] as? Int, nextOffset)
            } else {
                XCTAssertTrue(json["nextOffset"] is NSNull)
            }
        }
    }

    /// Compiling reads the Music dictionary but runs nothing.
    func testPlaylistsScriptCompiles() throws {
        XCTAssertTrue(MusicService.playlistsScript.contains("every library playlist"))
        XCTAssertTrue(MusicService.playlistsScript.contains("every user playlist"))
        var errorInfo: NSDictionary?
        XCTAssertTrue(
            try XCTUnwrap(NSAppleScript(source: MusicService.playlistsScript))
                .compileAndReturnError(&errorInfo),
            String(describing: errorInfo)
        )
    }

    /// Compiling reads the Music dictionary but runs nothing.
    func testPlaylistTracksScriptReadsOnePageAndCompiles() throws {
        let script = MusicService.playlistTracksScript(id: "A0B8C1E7B52DD217", offset: 100, limit: 50)
        XCTAssertTrue(script.contains("persistent ID is \"A0B8C1E7B52DD217\""), script)
        XCTAssertTrue(script.contains("set firstIndex to 101"), script)
        XCTAssertTrue(script.contains("set lastIndex to 150"), script)
        XCTAssertEqual(script.components(separatedBy: "tell application").count - 1, 1, script)

        var errorInfo: NSDictionary?
        XCTAssertTrue(
            try XCTUnwrap(NSAppleScript(source: script)).compileAndReturnError(&errorInfo),
            String(describing: errorInfo)
        )
    }
}
