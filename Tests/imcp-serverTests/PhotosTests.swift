import CoreLocation
import Foundation
import ImageIO
import Photos
import XCTest

final class PhotosTests: XCTestCase {
    private typealias Cursor = PhotosService.Cursor

    // MARK: - Fetch arguments

    func testFetchDefaults() throws {
        let request = try PhotosService.fetchRequest(from: [:])
        XCTAssertEqual(request, PhotosService.FetchRequest())
        XCTAssertEqual(request.limit, 30)
        XCTAssertFalse(request.filtersFetchedAssets)
    }

    func testFetchArguments() throws {
        let request = try PhotosService.fetchRequest(from: [
            "album": "Trips",
            "start": "2026-01-01",
            "end": "2026-01-31",
            "mediaType": "photo",
            "subtypes": ["screenshot", "livePhoto"],
            "favorite": true,
            "query": "  beach  ",
            "near": ["latitude": 45.5, "longitude": .int(-122), "radius": 500],
            "limit": .double(5),
        ])
        XCTAssertEqual(request.album, "Trips")
        let calendar = Calendar.current
        XCTAssertEqual(request.startDate, calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        XCTAssertEqual(request.endDate, calendar.date(from: DateComponents(year: 2026, month: 2, day: 1)))
        XCTAssertEqual(request.mediaType, .photo)
        XCTAssertEqual(request.subtypes, [.screenshot, .livePhoto])
        XCTAssertTrue(request.favoritesOnly)
        XCTAssertEqual(request.query, "beach")
        XCTAssertEqual(request.near, PhotosService.Region(latitude: 45.5, longitude: -122, radius: 500))
        XCTAssertEqual(request.limit, 5)
        XCTAssertTrue(request.filtersFetchedAssets)
    }

    func testInvalidFetchArgumentsAreErrors() {
        let invalid: [[String: Value]] = [
            ["limit": 0],
            ["limit": .double(1.5)],
            ["limit": "10"],
            ["mediaType": "audio"],
            ["subtypes": []],
            ["subtypes": ["selfie"]],
            ["subtypes": "screenshot"],
            ["favorite": "yes"],
            ["query": "   "],
            ["start": "yesterday"],
            ["cursor": "not a cursor"],
            ["near": ["latitude": 91, "longitude": 0, "radius": 10]],
            ["near": ["latitude": 0, "longitude": 181, "radius": 10]],
            ["near": ["latitude": 0, "longitude": 0, "radius": 0]],
            ["near": ["latitude": 0, "longitude": 0]],
            ["near": ["latitude": 0, "longitude": 0, "radius": 10, "unit": "km"]],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try PhotosService.fetchRequest(from: arguments), "\(arguments)") { error in
                XCTAssertTrue(
                    error.localizedDescription.hasPrefix("Invalid argument: "),
                    error.localizedDescription
                )
            }
        }
    }

    func testQueryErrorNamesMacOS27() {
        let message = PhotosService.PhotosError.queryNeedsMacOS27.localizedDescription
        XCTAssertTrue(message.contains("macOS 27"), message)
    }

    // MARK: - Predicate

    func testPredicateWithoutArgumentsMatchesPhotosAndVideos() {
        let predicate = PhotosService.FetchRequest().predicate
        XCTAssertTrue(predicate.evaluate(with: asset(mediaType: .image)))
        XCTAssertTrue(predicate.evaluate(with: asset(mediaType: .video)))
        XCTAssertFalse(predicate.evaluate(with: asset(mediaType: .audio)))
    }

    func testPredicateUsesOnlyKeysThatPhotoKitAccepts() {
        var request = PhotosService.FetchRequest()
        request.startDate = Date(timeIntervalSinceReferenceDate: 0)
        request.endDate = Date(timeIntervalSinceReferenceDate: 100)
        request.mediaType = .video
        request.subtypes = [.slomo]
        request.favoritesOnly = true
        request.cursor = Cursor(creationDate: Date(timeIntervalSinceReferenceDate: 50), localIdentifier: "A")
        let accepted: Set<String> = [
            "localIdentifier", "creationDate", "modificationDate", "mediaType", "mediaSubtypes",
            "duration", "pixelWidth", "pixelHeight", "isFavorite", "isHidden", "burstIdentifier",
        ]
        XCTAssertTrue(keyPaths(in: request.predicate).isSubset(of: accepted), "\(request.predicate)")
    }

    func testPredicateFiltersMediaTypeSubtypesAndFavorites() {
        var request = PhotosService.FetchRequest()
        request.mediaType = .photo
        request.subtypes = [.screenshot, .hdr]
        request.favoritesOnly = true
        let predicate = request.predicate

        XCTAssertTrue(predicate.evaluate(with: asset(subtypes: .photoScreenshot, favorite: true)))
        XCTAssertTrue(predicate.evaluate(with: asset(subtypes: [.photoHDR, .photoLive], favorite: true)))
        XCTAssertFalse(predicate.evaluate(with: asset(subtypes: .photoLive, favorite: true)))
        XCTAssertFalse(predicate.evaluate(with: asset(subtypes: .photoScreenshot, favorite: false)))
        XCTAssertFalse(
            predicate.evaluate(with: asset(mediaType: .video, subtypes: .photoScreenshot, favorite: true))
        )
    }

    func testPredicateFiltersDatesAndCursor() {
        var request = PhotosService.FetchRequest()
        request.startDate = Date(timeIntervalSinceReferenceDate: 10)
        request.endDate = Date(timeIntervalSinceReferenceDate: 20)
        XCTAssertTrue(request.predicate.evaluate(with: asset(date: 10)))
        XCTAssertTrue(request.predicate.evaluate(with: asset(date: 19.5)))
        XCTAssertFalse(request.predicate.evaluate(with: asset(date: 9.9)))
        XCTAssertFalse(request.predicate.evaluate(with: asset(date: 20)))

        request.cursor = Cursor(creationDate: Date(timeIntervalSinceReferenceDate: 15), localIdentifier: "M")
        XCTAssertTrue(request.predicate.evaluate(with: asset(date: 15)))
        XCTAssertFalse(request.predicate.evaluate(with: asset(date: 15.5)))
    }

    // MARK: - Cursor

    func testCursorRoundTripsExactly() throws {
        let date = Date(timeIntervalSinceReferenceDate: 816_542_831.716_135_1)
        let cursor = Cursor(creationDate: date, localIdentifier: "6F1E3C2A-0000-4000-8000-000000000001/L0/001")
        let decoded = try XCTUnwrap(Cursor(cursor.description))
        XCTAssertEqual(decoded, cursor)
        XCTAssertEqual(decoded.creationDate.timeIntervalSinceReferenceDate, date.timeIntervalSinceReferenceDate)
        XCTAssertFalse(cursor.description.contains("/"))
        XCTAssertFalse(cursor.description.contains("="))
    }

    func testMalformedCursorsAreRejected() {
        XCTAssertNil(Cursor(""))
        XCTAssertNil(Cursor("%%%"))
        XCTAssertNil(Cursor(Data("12.5".utf8).base64EncodedString()))
        XCTAssertNil(Cursor(Data("12.5\n".utf8).base64EncodedString()))
        XCTAssertNil(Cursor(Data("soon\nA/L0/001".utf8).base64EncodedString()))
        XCTAssertNil(Cursor(Data("inf\nA/L0/001".utf8).base64EncodedString()))
    }

    // MARK: - Paging

    private struct Item: Equatable {
        var id: String
        var date: Double?
    }

    /// Pages through items until the end, applying the cursor predicate as PhotoKit would.
    private func allPages(
        _ items: [Item],
        limit: Int,
        scanLimit: Int? = nil,
        matches: (Item) -> Bool = { _ in true }
    ) -> [[String]] {
        var pages: [[String]] = []
        var cursor: Cursor?
        repeat {
            let candidates = items.filter { item in
                guard let cursor, let date = item.date else { return true }
                return date <= cursor.creationDate.timeIntervalSinceReferenceDate
            }
            let page = PhotosService.page(
                count: candidates.count,
                item: { candidates[$0] },
                key: key(of:),
                after: cursor,
                limit: limit,
                scanLimit: scanLimit,
                matches: matches
            )
            pages.append(page.items.map(\.id))
            cursor = page.nextCursor.flatMap { Cursor($0.description) }
        } while cursor != nil && pages.count < 100
        return pages
    }

    /// Items with identifiers from a format and dates that fall by one from the first item to the last.
    private func descendingItems(count: Int, format: String, firstDate: Double) -> [Item] {
        var items: [Item] = []
        for index in 0 ..< count {
            let id: String = String(format: format, index)
            let date: Double = firstDate - Double(index)
            items.append(Item(id: id, date: date))
        }
        return items
    }

    private func key(of item: Item) -> Cursor? {
        item.date.map { Cursor(creationDate: Date(timeIntervalSinceReferenceDate: $0), localIdentifier: item.id) }
    }

    func testPagesOrderItemsWithTheSameDateByIdentifier() {
        // Items with equal dates arrive in no particular order from the fetch.
        let items = [
            Item(id: "E", date: 30),
            Item(id: "B", date: 20), Item(id: "D", date: 20), Item(id: "A", date: 20), Item(id: "C", date: 20),
            Item(id: "F", date: 10),
        ]
        let pages = allPages(items, limit: 2)
        XCTAssertEqual(pages, [["E", "D"], ["C", "B"], ["A", "F"]])
    }

    func testPagesNeitherRepeatNorDropItems() {
        // Runs of four items share a date, newest first, with identifiers in no particular order.
        var items: [Item] = []
        for index in 0 ..< 50 {
            let id: String = String(format: "%03d", (index * 37) % 50)
            let date: Double = Double(12 - index / 4)
            items.append(Item(id: id, date: date))
        }
        for limit in [1, 3, 7, 30, 60] {
            let pages: [[String]] = allPages(items, limit: limit)
            let ids: [String] = pages.flatMap { $0 }
            XCTAssertEqual(ids.count, 50, "limit \(limit)")
            XCTAssertEqual(Set(ids).count, 50, "limit \(limit)")
        }
    }

    func testANewPhotoDoesNotShiftLaterPages() {
        var items = [Item(id: "C", date: 30), Item(id: "B", date: 20), Item(id: "A", date: 10)]
        let first = PhotosService.page(
            count: items.count,
            item: { items[$0] },
            key: key(of:),
            after: nil,
            limit: 2
        )
        XCTAssertEqual(first.items.map(\.id), ["C", "B"])
        let cursor = try? XCTUnwrap(first.nextCursor)

        items.insert(Item(id: "N", date: 40), at: 0)
        let second = PhotosService.page(
            count: items.count,
            item: { items[$0] },
            key: key(of:),
            after: cursor,
            limit: 2
        )
        XCTAssertEqual(second.items.map(\.id), ["A"])
        XCTAssertNil(second.nextCursor)
    }

    func testLastPageHasNoCursor() {
        let items = [Item(id: "B", date: 20), Item(id: "A", date: 10)]
        let page = PhotosService.page(count: items.count, item: { items[$0] }, key: key(of:), after: nil, limit: 2)
        XCTAssertEqual(page.items.map(\.id), ["B", "A"])
        XCTAssertNil(page.nextCursor)
    }

    func testItemsWithoutDatesAreSkipped() {
        let items = [Item(id: "B", date: 20), Item(id: "X", date: nil), Item(id: "A", date: 10)]
        XCTAssertEqual(allPages(items, limit: 5), [["B", "A"]])
    }

    func testFilteredPagingStopsAtTheScanLimitWithACursor() {
        let items: [Item] = descendingItems(count: 20, format: "%02d", firstDate: 100)
        let even: (Item) -> Bool = { Int($0.id)! % 2 == 0 }

        let first = PhotosService.page(
            count: items.count,
            item: { items[$0] },
            key: key(of:),
            after: nil,
            limit: 30,
            scanLimit: 5,
            matches: even
        )
        XCTAssertEqual(first.items.map(\.id), ["00", "02", "04"])
        XCTAssertEqual(first.nextCursor?.localIdentifier, "04")

        let pages = allPages(items, limit: 30, scanLimit: 5, matches: even)
        let ids: [String] = pages.flatMap { $0 }
        let expected: [String] = stride(from: 0, to: 20, by: 2).map { (index: Int) -> String in
            String(format: "%02d", index)
        }
        XCTAssertEqual(ids, expected)
        XCTAssertEqual(pages.count, 4)
    }

    func testFullPageDoesNotReadTheNextRun() {
        let items: [Item] = descendingItems(count: 100, format: "%03d", firstDate: 1000)
        var reads: [Int] = []
        let page = PhotosService.page(
            count: items.count,
            item: { index in
                reads.append(index)
                return items[index]
            },
            key: key(of:),
            after: nil,
            limit: 2
        )
        XCTAssertEqual(page.items.map(\.id), ["000", "001"])
        // The third item ends the second item's run of equal dates.
        XCTAssertEqual(reads, [0, 1, 2])
        XCTAssertEqual(page.nextCursor?.localIdentifier, "001")
    }

    func testScanLimitIsExceededByAtMostOneRunOfEqualDates() {
        // Three items with their own dates, a run of 20 with one date, then 10 more.
        var items: [Item] = descendingItems(count: 3, format: "a%d", firstDate: 1000)
        for index in 0 ..< 20 {
            items.append(Item(id: String(format: "b%02d", index), date: 500))
        }
        items += descendingItems(count: 10, format: "c%d", firstDate: 100)
        var reads = 0
        let page = PhotosService.page(
            count: items.count,
            item: { index in
                reads += 1
                return items[index]
            },
            key: key(of:),
            after: nil,
            limit: 30,
            scanLimit: 5,
            matches: { _ in false }
        )
        XCTAssertEqual(page.items, [])
        // The run is read whole, with the item after it, though only 2 of its items are examined.
        XCTAssertEqual(reads, 3 + 20 + 1)
        XCTAssertEqual(page.nextCursor?.localIdentifier, "b18")

        reads = 0
        let distinct: [Item] = descendingItems(count: 100, format: "%03d", firstDate: 1000)
        _ = PhotosService.page(
            count: distinct.count,
            item: { index in
                reads += 1
                return distinct[index]
            },
            key: key(of:),
            after: nil,
            limit: 30,
            scanLimit: 5,
            matches: { _ in false }
        )
        XCTAssertEqual(reads, 6)
    }

    // MARK: - Filters

    func testRegionContainsNearbyLocationsOnly() {
        let region = PhotosService.Region(latitude: 45.5152, longitude: -122.6784, radius: 1000)
        XCTAssertTrue(region.contains(CLLocation(latitude: 45.5200, longitude: -122.6784)))
        XCTAssertFalse(region.contains(CLLocation(latitude: 45.5300, longitude: -122.6784)))
        XCTAssertFalse(region.contains(nil))
        XCTAssertFalse(region.contains(CLLocation(latitude: 200, longitude: 0)))
    }

    func testQueryMatchesCaptionKeywordsAndFilenameWithoutCaseOrDiacritics() {
        XCTAssertTrue(
            PhotosService.matches(query: "cafe", caption: "Lunch at the Café", keywords: [], filename: nil)
        )
        XCTAssertTrue(
            PhotosService.matches(query: "BEACH", caption: nil, keywords: ["sunset", "beach"], filename: nil)
        )
        XCTAssertTrue(
            PhotosService.matches(query: "img_12", caption: nil, keywords: [], filename: "IMG_1234.HEIC")
        )
        XCTAssertFalse(
            PhotosService.matches(query: "dog", caption: "A cat", keywords: ["pets"], filename: "IMG_1.JPG")
        )
    }

    // MARK: - Albums

    private typealias Album = PhotosService.Album
    private typealias AlbumCursor = PhotosService.AlbumCursor

    private func album(
        _ id: String,
        _ name: String?,
        _ kind: Album.Kind = .album,
        in parentID: String? = nil
    ) -> Album {
        Album(id: id, name: name, kind: kind, parentID: parentID, numberOfItems: kind == .folder ? nil : 1)
    }

    /// A library with a nested folder, every kind at the top level, and an album without a name.
    private var library: [Album] {
        [
            album("trips", "Trips", .folder),
            album("familia", "Família"),
            album("recents", "Recents", .smartAlbum),
            album("shared", "Shared Stuff", .sharedAlbum),
            album("unnamed", nil),
            album("paris", "Paris", in: "trips"),
            album("crawl", "café crawl", in: "trips"),
            album("europe", "Europe", .folder, in: "trips"),
            album("rome", "Rome", in: "europe"),
            album("roma", "Cafe Roma", in: "europe"),
        ]
    }

    private func albumIDs(_ arguments: [String: Value], in albums: [Album]? = nil) throws -> [String] {
        let request = try PhotosService.albumListRequest(from: arguments)
        return try PhotosService.albumPage(of: albums ?? library, for: request).items.map(\.id)
    }

    func testAlbumListDefaults() throws {
        let request = try PhotosService.albumListRequest(from: [:])
        XCTAssertEqual(request, PhotosService.AlbumListRequest())
        XCTAssertEqual(request.limit, 100)
    }

    func testAlbumListWithoutArgumentsHasTheTopLevel() throws {
        XCTAssertEqual(try albumIDs([:]), ["unnamed", "familia", "recents", "shared", "trips"])
    }

    func testAlbumListHasTheChildrenOfAFolderByIDOrName() throws {
        let expected: [String] = ["crawl", "europe", "paris"]
        XCTAssertEqual(try albumIDs(["folder": "trips"]), expected)
        XCTAssertEqual(try albumIDs(["folder": "TRÍPS"]), expected)
        XCTAssertEqual(try albumIDs(["folder": "europe"]), ["roma", "rome"])

        let request = try PhotosService.albumListRequest(from: ["folder": "Trips"])
        let page = try PhotosService.albumPage(of: library, for: request)
        XCTAssertEqual(page.folder?.id, "trips")
        XCTAssertNil(page.nextCursor)
    }

    func testAlbumQueryMatchesEveryLevelWithoutCaseOrDiacritics() throws {
        XCTAssertEqual(Set(try albumIDs(["query": "CAFE"])), ["crawl", "roma"])
        XCTAssertEqual(Set(try albumIDs(["query": "famil"])), ["familia"])
        XCTAssertEqual(try albumIDs(["query": "  ROM  "]), ["roma", "rome"])
    }

    func testAlbumQueryWithAFolderMatchesOnlyItsChildren() throws {
        XCTAssertEqual(try albumIDs(["folder": "trips", "query": "Café"]), ["crawl"])
        XCTAssertEqual(try albumIDs(["folder": "trips", "query": "rome"]), [])
    }

    func testAlbumKindsFilterTheList() throws {
        XCTAssertEqual(try albumIDs(["kind": ["folder"]]), ["trips"])
        XCTAssertEqual(try albumIDs(["kind": ["smartAlbum", "sharedAlbum"]]), ["recents", "shared"])
        XCTAssertEqual(try albumIDs(["query": "e", "kind": ["folder"]]), ["europe"])
    }

    func testAlbumsAreOrderedByNameThenIdentifier() throws {
        let albums = [
            album("b", "Summer"),
            album("c", "Album 10"),
            album("a", "Summer"),
            album("d", "Album 2"),
            album("e", nil),
        ]
        XCTAssertEqual(try albumIDs([:], in: albums), ["e", "d", "c", "a", "b"])
    }

    func testFoldersCountTheirDirectChildren() {
        let counted: [Album] = PhotosService.countingFolderChildren(library + [album("empty", "Empty", .folder)])
        let counts: [String: Int?] = Dictionary(uniqueKeysWithValues: counted.map { ($0.id, $0.numberOfItems) })
        XCTAssertEqual(counts["trips"], 3)
        XCTAssertEqual(counts["europe"], 2)
        XCTAssertEqual(counts["empty"], 0)
        XCTAssertEqual(counts["paris"], 1)
    }

    func testAlbumCursorRoundTrips() throws {
        let cursor = AlbumCursor(name: "Line one\nLine two/ü+", id: "6F1E3C2A-0000-4000-8000-000000000001/L0/040")
        let decoded = try XCTUnwrap(AlbumCursor(cursor.description))
        XCTAssertEqual(decoded, cursor)
        XCTAssertFalse(cursor.description.contains("/"))
        XCTAssertFalse(cursor.description.contains("="))
        XCTAssertEqual(AlbumCursor(AlbumCursor(name: "", id: "A").description), AlbumCursor(name: "", id: "A"))
    }

    func testAlbumPagesCoverEveryItemOnce() throws {
        var albums: [Album] = []
        for index in (1 ... 25).reversed() {
            let id: String = String(format: "%02d", index)
            albums.append(album(id, "Album \(index)"))
        }
        var pages: [[String]] = []
        var cursor: String?
        repeat {
            var arguments: [String: Value] = ["limit": 10]
            if let cursor {
                arguments["cursor"] = .string(cursor)
            }
            let request = try PhotosService.albumListRequest(from: arguments)
            let page = try PhotosService.albumPage(of: albums, for: request)
            pages.append(page.items.map(\.id))
            cursor = page.nextCursor?.description
        } while cursor != nil && pages.count < 10
        XCTAssertEqual(pages.map(\.count), [10, 10, 5])
        let ids: [String] = pages.flatMap { $0 }
        let expected: [String] = (1 ... 25).map { String(format: "%02d", $0) }
        XCTAssertEqual(ids, expected)
    }

    func testANewAlbumDoesNotShiftLaterPages() throws {
        var albums = [album("a", "A"), album("c", "C"), album("e", "E")]
        let first = try PhotosService.albumPage(
            of: albums,
            for: PhotosService.AlbumListRequest(limit: 2)
        )
        XCTAssertEqual(first.items.map(\.id), ["a", "c"])
        let cursor = try XCTUnwrap(first.nextCursor)

        albums += [album("b", "B"), album("d", "D")]
        let request = try PhotosService.albumListRequest(from: ["limit": 2, "cursor": .string(cursor.description)])
        let second = try PhotosService.albumPage(of: albums, for: request)
        XCTAssertEqual(second.items.map(\.id), ["d", "e"])
        XCTAssertNil(second.nextCursor)
    }

    func testInvalidAlbumListArgumentsAreErrors() {
        let invalid: [[String: Value]] = [
            ["limit": 0],
            ["limit": "10"],
            ["query": ""],
            ["query": "   "],
            ["kind": []],
            ["kind": ["playlist"]],
            ["kind": "album"],
            ["cursor": "not a cursor"],
            ["cursor": .string(Data("\nName".utf8).base64EncodedString())],
            ["folder": 3],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try PhotosService.albumListRequest(from: arguments), "\(arguments)") { error in
                XCTAssertTrue(
                    error.localizedDescription.hasPrefix("Invalid argument: "),
                    error.localizedDescription
                )
            }
        }
    }

    func testUnknownFolderIsAnError() {
        XCTAssertThrowsError(try albumIDs(["folder": "Winter"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("photos_albums_list"), error.localizedDescription)
        }
    }

    func testFolderThatNamesAnAlbumIsAnError() {
        for folder in ["paris", "PARIS"] {
            XCTAssertThrowsError(try albumIDs(["folder": .string(folder)])) { error in
                XCTAssertTrue(error.localizedDescription.contains("is an album"), error.localizedDescription)
            }
        }
    }

    func testFolderNameOfSeveralFoldersIsAnError() {
        let albums = library + [album("trips2", "trips", .folder)]
        XCTAssertThrowsError(try albumIDs(["folder": "Trips"], in: albums)) { error in
            XCTAssertTrue(error.localizedDescription.contains("trips2"), error.localizedDescription)
        }
    }

    // MARK: - Values

    func testDurationsUseISO8601() {
        XCTAssertEqual(PhotosService.iso8601Duration(0), "PT0S")
        XCTAssertEqual(PhotosService.iso8601Duration(5.54), "PT5.5S")
        XCTAssertEqual(PhotosService.iso8601Duration(65), "PT1M5S")
        XCTAssertEqual(PhotosService.iso8601Duration(3600), "PT1H")
        XCTAssertEqual(PhotosService.iso8601Duration(3725.25), "PT1H2M5.3S")
        XCTAssertNil(PhotosService.iso8601Duration(.nan))
        XCTAssertNil(PhotosService.iso8601Duration(-1))
    }

    func testSubtypesAreNamed() {
        XCTAssertEqual(
            PhotosService.Subtype.subtypes(in: [.photoLive, .photoHDR, .videoStreamed]),
            [.livePhoto, .hdr]
        )
        XCTAssertEqual(PhotosService.Subtype.subtypes(in: []), [])
    }

    #if compiler(>=6.4)
        func testAnimationSubtypeMatchesTheSDK() {
            // The Xcode 26 SDK does not declare `.photoAnimation`, so the service uses its value.
            XCTAssertEqual(
                PhotosService.Subtype.animation.mediaSubtype.rawValue,
                PHAssetMediaSubtype.photoAnimation.rawValue
            )
        }
    #endif

    func testGeoCoordinatesIncludeKnownElevation() {
        let withElevation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2),
            altitude: 30,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            timestamp: Date()
        )
        let object = PhotosService.geoCoordinates(withElevation)?.objectValue
        XCTAssertEqual(object?["@type"], "GeoCoordinates")
        XCTAssertEqual(object?["latitude"], .double(1))
        XCTAssertEqual(object?["elevation"], .double(30))

        let withoutElevation = CLLocation(latitude: 1, longitude: 2)
        XCTAssertNil(PhotosService.geoCoordinates(withoutElevation)?.objectValue?["elevation"])
    }

    // MARK: - Image arguments

    func testImageArguments() throws {
        let defaults = try PhotosService.imageRequest(from: ["id": "A/L0/001"])
        XCTAssertEqual(defaults, PhotosService.ImageRequest(id: "A/L0/001"))
        XCTAssertEqual(defaults.maxDimension, 1024)

        let reference = try PhotosService.imageRequest(from: [
            "id": "A/L0/001", "maxDimension": 4096, "original": true, "output": "reference", "fullSize": true,
        ])
        XCTAssertEqual(reference.output, .reference)
        XCTAssertTrue(reference.fullSize)
        XCTAssertTrue(reference.original)
    }

    func testInvalidImageArgumentsAreErrors() {
        let invalid: [[String: Value]] = [
            [:],
            ["id": ""],
            ["id": 12],
            ["id": "A", "maxDimension": 0],
            ["id": "A", "maxDimension": 4097],
            ["id": "A", "output": "url"],
            ["id": "A", "fullSize": true],
            ["id": "A", "output": "image", "fullSize": true],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try PhotosService.imageRequest(from: arguments), "\(arguments)")
        }
    }

    func testContactSheetArguments() throws {
        let request = try PhotosService.contactSheetRequest(from: ["ids": ["B", "A"], "output": "reference"])
        XCTAssertEqual(request.ids, ["B", "A"])
        XCTAssertEqual(request.output, .reference)

        let tooMany = Value.array((0 ... 30).map { .string("\($0)") })
        for arguments: [String: Value] in [[:], ["ids": []], ["ids": tooMany], ["ids": ["A", 2]], ["ids": "A"]] {
            XCTAssertThrowsError(try PhotosService.contactSheetRequest(from: arguments), "\(arguments)")
        }
    }

    func testContactSheetErrorNamesThePosition() {
        let message = PhotosService.PhotosError.contactSheetPhotoNotFound("X/L0/001", position: 3)
            .localizedDescription
        XCTAssertTrue(message.contains("X/L0/001"), message)
        XCTAssertTrue(message.contains("position 3"), message)
    }

    func testTargetSizeFitsTheLongestEdgeWithoutEnlarging() {
        XCTAssertEqual(
            PhotosService.targetSize(width: 4032, height: 3024, maxDimension: 1024),
            CGSize(width: 1024, height: 768)
        )
        XCTAssertEqual(
            PhotosService.targetSize(width: 3024, height: 4032, maxDimension: 1024),
            CGSize(width: 768, height: 1024)
        )
        XCTAssertEqual(
            PhotosService.targetSize(width: 640, height: 480, maxDimension: 1024),
            CGSize(width: 640, height: 480)
        )
        XCTAssertEqual(
            PhotosService.targetSize(width: 0, height: 0, maxDimension: 512),
            CGSize(width: 512, height: 512)
        )
    }

    // MARK: - Picker

    func testPickDefaults() throws {
        let request = try PhotosService.pickRequest(from: [:])
        XCTAssertEqual(request, PhotosService.PickRequest(query: nil, limit: 1, mediaType: nil))
    }

    func testPickArguments() throws {
        let request = try PhotosService.pickRequest(from: [
            "query": "  dog on a beach ",
            "limit": .double(3),
            "mediaType": "video",
        ])
        XCTAssertEqual(request, PhotosService.PickRequest(query: "dog on a beach", limit: 3, mediaType: .video))
    }

    func testInvalidPickArgumentsAreErrors() {
        let invalid: [[String: Value]] = [
            ["query": "  "],
            ["query": 1],
            ["limit": 0],
            ["limit": -2],
            ["limit": .double(1.5)],
            ["limit": "2"],
            ["mediaType": "audio"],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try PhotosService.pickRequest(from: arguments), "\(arguments)")
        }
    }

    func testPickerTitleNamesTheClientAndTheRequest() {
        typealias Request = PhotosService.PickRequest
        XCTAssertEqual(
            PhotosService.pickerTitle(for: Request(query: "dog on a beach"), clientName: "Claude"),
            "Claude asks for a photo or video: dog on a beach"
        )
        XCTAssertEqual(
            PhotosService.pickerTitle(for: Request(mediaType: .photo), clientName: "Claude"),
            "Claude asks for a photo"
        )
        XCTAssertEqual(
            PhotosService.pickerTitle(for: Request(limit: 4, mediaType: .video), clientName: " "),
            "A client asks for up to 4 videos"
        )
        XCTAssertEqual(
            PhotosService.pickerTitle(for: Request(query: "receipts", limit: 2), clientName: nil),
            "A client asks for up to 2 photos or videos: receipts"
        )
    }

    func testCancelledPickIsAnEmptyList() {
        let list = PhotosService.pickedList(.cancelled) { _ in
            XCTFail("A cancelled pick looks up no items")
            return [:]
        }
        XCTAssertEqual(list.objectValue?["@type"], "ItemList")
        XCTAssertEqual(list.objectValue?["numberOfItems"], 0)
        let empty: Value = .array([])
        XCTAssertEqual(list.objectValue?["itemListElement"], empty)
        XCTAssertEqual(list.objectValue?["cancelled"], true)
        XCTAssertNil(list.objectValue?["description"])
    }

    func testPickedItemsKeepTheOrderChosen() {
        var requested: [String] = []
        let list = PhotosService.pickedList(.picked(["C", "A", "B"])) { ids in
            requested = ids
            var values: [String: Value] = [:]
            for id in ids {
                let value: Value = .object(["@id": .string(id)])
                values[id] = value
            }
            return values
        }
        XCTAssertEqual(requested, ["C", "A", "B"])
        XCTAssertEqual(list.objectValue?["numberOfItems"], 3)
        let expected: Value = .array([
            .object(["@id": .string("C")]),
            .object(["@id": .string("A")]),
            .object(["@id": .string("B")]),
        ])
        XCTAssertEqual(list.objectValue?["itemListElement"], expected)
        XCTAssertEqual(list.objectValue?["cancelled"], false)
        XCTAssertNil(list.objectValue?["description"])
    }

    func testHiddenMissingAndUnidentifiedPicksAreLeftOut() {
        let list = PhotosService.pickedList(.picked(["A", nil, "Hidden", "B"])) { ids in
            XCTAssertEqual(ids, ["A", "Hidden", "B"])
            let values: [String: Value] = [
                "A": .object(["@id": .string("A")]),
                "B": .object(["@id": .string("B")]),
            ]
            return values
        }
        XCTAssertEqual(list.objectValue?["numberOfItems"], 2)
        let expected: Value = .array([
            .object(["@id": .string("A")]),
            .object(["@id": .string("B")]),
        ])
        XCTAssertEqual(list.objectValue?["itemListElement"], expected)
        XCTAssertEqual(list.objectValue?["cancelled"], false)
        XCTAssertEqual(
            list.objectValue?["description"]?.stringValue,
            "2 chosen items are hidden or no longer in the library, so they are left out."
        )
    }

    func testPickerErrorsSayWhatHappened() {
        let open = PhotosService.PhotosError.pickerOpen.localizedDescription
        XCTAssertTrue(open.contains("already open"), open)
        let timedOut = PhotosService.PhotosError.pickerTimedOut(.seconds(55)).localizedDescription
        XCTAssertTrue(timedOut.contains("did not choose"), timedOut)
        XCTAssertTrue(timedOut.contains("55 seconds"), timedOut)
    }

    // MARK: - Encoding

    func testJPEGHasNoLocation() throws {
        let image = try PhotosService.sRGBImage(noiseImage(width: 64, height: 48, seed: 1))
        let data = try PhotosService.jpegData(image, quality: 0.8)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 64)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 48)
    }

    func testContactSheetFitsTheSizeLimit() throws {
        var thumbnails: [CGImage?] = []
        for index in 0 ..< 30 {
            let seed: UInt64 = UInt64(index + 1)
            thumbnails.append(index == 7 ? nil : noiseImage(width: 240, height: 180, seed: seed))
        }
        let sheet = try PhotosService.ContactSheet.render(thumbnails)
        XCTAssertEqual(PhotosService.ContactSheet.columns(for: 30), 6)
        XCTAssertEqual(sheet.width, 6 * (240 + 8) + 8)
        XCTAssertEqual(sheet.height, 5 * (34 + 240 + 8) + 8)
        let data = try PhotosService.ContactSheet.jpegData(sheet)
        XCTAssertLessThanOrEqual(data.count, 700_000)
        XCTAssertLessThan(data.base64EncodedString().utf8.count, 1_000_000)
    }

    func testRenderedJPEGDropsTheSourcePhotosLocation() throws {
        // A source JPEG with GPS, Exif, and TIFF metadata, as a camera writes.
        let sourceData = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(sourceData as CFMutableData, "public.jpeg" as CFString, 1, nil)
        )
        let metadata: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 45.5152,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.6784,
                kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Test Camera"],
        ]
        CGImageDestinationAddImage(destination, noiseImage(width: 64, height: 48, seed: 2), metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let source = try XCTUnwrap(CGImageSourceCreateWithData(sourceData as CFData, nil))
        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertNotNil(sourceProperties?[kCGImagePropertyGPSDictionary], "The source must have a location")
        let sourceImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        let data = try PhotosService.jpegData(PhotosService.sRGBImage(sourceImage), quality: 0.8)
        let rendered = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(rendered, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal])
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFModel])
    }

    // MARK: - Reference files

    private func makeReferenceFiles() throws -> PhotosService.ReferenceFiles {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotosTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return PhotosService.ReferenceFiles(root: root)
    }

    func testReferenceFileIsWrittenForAnOpenConnection() throws {
        let files = try makeReferenceFiles()
        let connection = UUID()
        let url = try files.write(Data("jpeg".utf8), pathExtension: "jpg", for: connection)
        XCTAssertEqual(try Data(contentsOf: url), Data("jpeg".utf8))
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, connection.uuidString)
        XCTAssertEqual(url.pathExtension, "jpg")

        files.close(connection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.directory(for: connection).path))
    }

    func testWriteForAClosedConnectionIsRefused() throws {
        let files = try makeReferenceFiles()
        let connection = UUID()
        files.close(connection)
        XCTAssertThrowsError(try files.write(Data("jpeg".utf8), pathExtension: "jpg", for: connection))
        XCTAssertThrowsError(try files.create(pathExtension: "heic", for: connection))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.directory(for: connection).path))
    }

    func testStreamedFileFinishedAfterTheCloseIsRemoved() throws {
        let files = try makeReferenceFiles()
        let connection = UUID()
        let other = UUID()
        let url = try files.create(pathExtension: "heic", for: connection)
        let otherURL = try files.create(pathExtension: "heic", for: other)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data("part one".utf8))

        // The connection closes while the data is still arriving.
        files.close(connection)
        try handle.write(contentsOf: Data("part two".utf8))
        try handle.close()

        XCTAssertThrowsError(try files.finish(url, for: connection)) { error in
            XCTAssertTrue(error.localizedDescription.contains("closed"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.directory(for: connection).path))

        XCTAssertNoThrow(try files.finish(otherURL, for: other))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherURL.path))
    }

    func testDiscardAndRemoveAllRemoveFiles() throws {
        let files = try makeReferenceFiles()
        let url = try files.create(pathExtension: "heic", for: nil)
        files.discard(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        _ = try files.write(Data([1]), pathExtension: "jpg", for: nil)
        _ = try files.write(Data([2]), pathExtension: "jpg", for: UUID())
        files.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.root.path))
    }

    // MARK: - PhotoKit requests

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int32] = []

        func record(_ value: Int32) {
            lock.withLock { values.append(value) }
        }

        var recorded: [Int32] {
            lock.withLock { values }
        }
    }

    func testResultBeforeTheContinuationIsDeliveredThenReleased() async throws {
        let pending = PhotosService.PendingRequest<Int>()
        pending.finish(.success(7))
        XCTAssertTrue(pending.holdsResult)
        let value = try await withCheckedThrowingContinuation { pending.setContinuation($0) }
        XCTAssertEqual(value, 7)
        XCTAssertFalse(pending.holdsResult)
    }

    func testSynchronousAndDuplicateCallbacksDeliverTheFirstResult() async throws {
        let cancelled = Recorder()
        let value: Int = try await PhotosService.withPhotoKitRequest(
            id: "A",
            start: { finish in
                finish(.success(1))
                finish(.success(2))
                finish(.failure(CancellationError()))
                return 9
            },
            cancel: { cancelled.record($0) }
        )
        XCTAssertEqual(value, 1)
        XCTAssertEqual(cancelled.recorded, [])
    }

    func testCancellationBeforeTheRequestIDCancelsTheRequestWhenTheIDArrives() {
        let pending = PhotosService.PendingRequest<Int>()
        let cancelled = Recorder()
        pending.finish(.failure(CancellationError()), cancelsRequest: true)
        pending.setRequestID(5, cancel: { cancelled.record($0) })
        XCTAssertEqual(cancelled.recorded, [5])

        let finishedNormally = PhotosService.PendingRequest<Int>()
        finishedNormally.finish(.success(1))
        finishedNormally.setRequestID(6, cancel: { cancelled.record($0) })
        XCTAssertEqual(cancelled.recorded, [5])
    }

    func testFinishCancelsAndReleasesTheTimeoutTask() async {
        let pending = PhotosService.PendingRequest<Int>()
        let timeout = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(60))
        }
        pending.setTimeoutTask(timeout)
        XCTAssertTrue(pending.holdsTimeoutTask)
        pending.finish(.success(1))
        XCTAssertFalse(pending.holdsTimeoutTask)
        XCTAssertTrue(timeout.isCancelled)

        let late = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(60))
        }
        pending.setTimeoutTask(late)
        XCTAssertTrue(late.isCancelled)
        XCTAssertFalse(pending.holdsTimeoutTask)
    }

    func testTimeoutCancelsTheRequest() async {
        let cancelled = Recorder()
        do {
            let _: Int = try await PhotosService.withPhotoKitRequest(
                id: "A/L0/001",
                timeout: .milliseconds(50),
                start: { _ in 3 },
                cancel: { cancelled.record($0) }
            )
            XCTFail("The request should time out")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("in time"), error.localizedDescription)
        }
        XCTAssertEqual(cancelled.recorded, [3])
    }

    func testTaskCancellationCancelsTheRequest() async {
        let cancelled = Recorder()
        let started = expectation(description: "started")
        let task = Task {
            let _: Int = try await PhotosService.withPhotoKitRequest(
                id: "A",
                start: { _ in
                    started.fulfill()
                    return 4
                },
                cancel: { cancelled.record($0) }
            )
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do {
            try await task.value
            XCTFail("The request should be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(cancelled.recorded, [4])
    }

    // MARK: - Helpers

    private func asset(
        mediaType: PHAssetMediaType = .image,
        subtypes: PHAssetMediaSubtype = [],
        favorite: Bool = false,
        date: Double = 0
    ) -> [String: Any] {
        [
            "mediaType": mediaType.rawValue,
            "mediaSubtypes": subtypes.rawValue,
            "isFavorite": favorite,
            "creationDate": Date(timeIntervalSinceReferenceDate: date),
            "localIdentifier": "A/L0/001",
        ]
    }

    private func keyPaths(in predicate: NSPredicate) -> Set<String> {
        switch predicate {
        case let compound as NSCompoundPredicate:
            var keyPaths: Set<String> = []
            for case let subpredicate as NSPredicate in compound.subpredicates {
                keyPaths.formUnion(self.keyPaths(in: subpredicate))
            }
            return keyPaths
        case let comparison as NSComparisonPredicate:
            return keyPaths(in: comparison.leftExpression).union(keyPaths(in: comparison.rightExpression))
        default:
            return []
        }
    }

    private func keyPaths(in expression: NSExpression) -> Set<String> {
        switch expression.expressionType {
        case .keyPath:
            return [expression.keyPath]
        case .function:
            var keyPaths: Set<String> = []
            for argument in expression.arguments ?? [] {
                keyPaths.formUnion(self.keyPaths(in: argument))
            }
            return keyPaths
        default:
            return []
        }
    }

    /// An image of random pixels, which compresses about as poorly as a photo.
    private func noiseImage(width: Int, height: Int, seed: UInt64) -> CGImage {
        var state = seed
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0 ..< width * height * 4 where index % 4 != 3 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}
