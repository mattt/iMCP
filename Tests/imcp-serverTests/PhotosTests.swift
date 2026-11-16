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
        let items = (0 ..< 50).map { index in
            Item(id: String(format: "%03d", (index * 37) % 50), date: Double(index / 4))
        }
        .sorted { ($0.date ?? 0) > ($1.date ?? 0) }
        for limit in [1, 3, 7, 30, 60] {
            let ids = allPages(items, limit: limit).flatMap { $0 }
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
        let items = (0 ..< 20).map { Item(id: String(format: "%02d", $0), date: Double(100 - $0)) }
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
        XCTAssertEqual(pages.flatMap { $0 }, stride(from: 0, to: 20, by: 2).map { String(format: "%02d", $0) })
        XCTAssertEqual(pages.count, 4)
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
        let thumbnails: [CGImage?] = (0 ..< 30).map { index in
            index == 7 ? nil : noiseImage(width: 240, height: 180, seed: UInt64(index + 1))
        }
        let sheet = try PhotosService.ContactSheet.render(thumbnails)
        XCTAssertEqual(PhotosService.ContactSheet.columns(for: 30), 6)
        XCTAssertEqual(sheet.width, 6 * (240 + 8) + 8)
        XCTAssertEqual(sheet.height, 5 * (34 + 240 + 8) + 8)
        let data = try PhotosService.ContactSheet.jpegData(sheet)
        XCTAssertLessThanOrEqual(data.count, 700_000)
        XCTAssertLessThan(data.base64EncodedString().utf8.count, 1_000_000)
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
            return compound.subpredicates.reduce(into: Set<String>()) {
                $0.formUnion(keyPaths(in: $1 as! NSPredicate))
            }
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
            return (expression.arguments ?? []).reduce(into: Set<String>()) { $0.formUnion(keyPaths(in: $1)) }
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
