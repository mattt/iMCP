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
}
