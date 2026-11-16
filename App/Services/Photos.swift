import AppKit
import CoreLocation
import CoreText
import Foundation
import ImageIO
import OSLog
import Photos
import PhotosUI
import UniformTypeIdentifiers
import UserNotifications

private let log = Logger.service("photos")
private let defaultLimit = 30
private let defaultMaxDimension = 1024
private let maxMaxDimension = 4096
private let maxContactSheetCount = 30
/// The most assets that one `photos_fetch` call examines for `query` and `near`,
/// so that a filter that matches few photos in a large library still returns promptly.
private let maxScannedAssets = 5000
private let requestTimeout: Duration = .seconds(60)
/// How long `photos_pick` waits for the user.
/// Many clients end a tool call after 60 seconds,
/// so the call ends first, with an error that says the user did not choose in time.
private let pickTimeout: Duration = .seconds(55)
private let jpegQuality = 0.8
/// The largest contact sheet to return, in bytes.
/// Base64 makes the result about a third larger,
/// and one client limits a tool result to about 1 MB.
private let maxContactSheetBytes = 700_000

/// Reads photos and videos from the Photos library with PhotoKit.
///
/// PhotoKit has no read-only access level, so the service asks for read and write access,
/// but no tool changes the library.
/// Hidden photos are never returned.
final class PhotosService: Service {
    static let shared = PhotosService()

    func activate() async throws {
        log.debug("Requesting Photos library access")
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            throw PhotosError.accessDenied
        }
    }

    var isActivated: Bool {
        get async {
            PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
        }
    }

    var tools: [Tool] {
        Tool(
            name: "photos_albums_list",
            description: """
                List the albums, shared albums, smart albums, and folders in Photos, \
                with their identifiers, kinds, parent folders, and estimated numbers of items
                """,
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Photos Albums",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            try await self.requireAccess()
            let albums = self.albums().map(\.value)
            return Value.object([
                "@context": "https://schema.org",
                "@type": "ItemList",
                "name": "Photos Albums",
                "numberOfItems": .int(albums.count),
                "itemListElement": .array(albums),
            ])
        }

        Tool(
            name: "photos_fetch",
            description: """
                Fetch the metadata of photos and videos in Photos, newest first by creation date. \
                Returns no image data; use photo_image_fetch or photos_contact_sheet to see photos. \
                The filters match only the album, creation date, media type, subtypes, favorite status, location, \
                and (on macOS 27 or later) the caption, keywords, and file name. \
                They do not search what a photo shows, or people, places by name, or text in images.
                """,
            inputSchema: .object(
                properties: [
                    "album": .string(
                        description: """
                            An album's @id or name from photos_albums_list. \
                            A name matches without regard to case or diacritics. \
                            Without album, the fetch covers the whole library.
                            """
                    ),
                    "start": .string(
                        description:
                            "Start of the creation date range (inclusive). ISO 8601 format. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End of the creation date range (exclusive). ISO 8601 format. If timezone is omitted, local time is assumed. A date-only value includes that whole day.",
                        format: .dateTime
                    ),
                    "mediaType": .string(
                        description: "Fetch only photos or only videos; both when absent",
                        enum: MediaType.allCases.map { .string($0.rawValue) }
                    ),
                    "subtypes": .array(
                        description:
                            "Fetch only items with at least one of these subtypes, such as screenshot or livePhoto",
                        items: .string(enum: Subtype.allCases.map { .string($0.rawValue) }),
                        minItems: 1
                    ),
                    "favorite": .boolean(
                        description: "When true, fetch only favorites",
                        default: false
                    ),
                    "query": .string(
                        description: """
                            Text to match in the caption, keywords, and original file name, \
                            without regard to case or diacritics. \
                            It does not match what a photo shows. Needs macOS 27 or later.
                            """
                    ),
                    "near": .object(
                        description:
                            "Fetch only items whose location is within radius meters of a coordinate; items without a location do not match",
                        properties: [
                            "latitude": .number(minimum: -90, maximum: 90),
                            "longitude": .number(minimum: -180, maximum: 180),
                            "radius": .number(description: "Radius in meters", exclusiveMinimum: 0),
                        ],
                        required: ["latitude", "longitude", "radius"],
                        additionalProperties: false
                    ),
                    "limit": .integer(
                        description: """
                            Maximum items to return. With query or near, \
                            a call examines about \(maxScannedAssets) items at most, \
                            so it can return fewer items and a nextCursor. \
                            Items with the same creation date are read together, \
                            so a call can examine more items than these numbers \
                            when many items share one creation date.
                            """,
                        default: .int(defaultLimit),
                        minimum: 1
                    ),
                    "cursor": .string(
                        description: "The nextCursor value from a previous photos_fetch, to fetch the next page"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Photos",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let request = try Self.fetchRequest(from: arguments)
            if request.query != nil, !Self.canMatchQuery {
                throw PhotosError.queryNeedsMacOS27
            }
            try await self.requireAccess()
            return try self.fetch(request)
        }

        Tool(
            name: "photo_image_fetch",
            description: """
                Fetch one photo as a JPEG image, scaled to fit maxDimension, \
                without its location or other metadata. \
                For a video or a Live Photo, the image is the still frame that Photos shows.
                """,
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "The @id of a photo, as returned by photos_fetch"
                    ),
                    "maxDimension": .integer(
                        description: "Length of the longest edge in pixels",
                        default: .int(defaultMaxDimension),
                        minimum: 1,
                        maximum: maxMaxDimension
                    ),
                    "original": .boolean(
                        description: "Use the original photo instead of the edited version",
                        default: false
                    ),
                    "output": .string(
                        description:
                            "image returns the image; reference writes the image to a file and returns its file URL",
                        default: .string(ImageOutput.image.rawValue),
                        enum: ImageOutput.allCases.map { .string($0.rawValue) }
                    ),
                    "fullSize": .boolean(
                        description: """
                            Only with output set to reference: write the image file as Photos stores it, at full size, \
                            instead of a JPEG that fits maxDimension. \
                            This file keeps its metadata, including the GPS coordinates of where the photo was taken.
                            """,
                        default: false
                    ),
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Photo Image",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let request = try Self.imageRequest(from: arguments)
            try await self.requireAccess()
            return try await self.image(for: request)
        }

        Tool(
            name: "photos_contact_sheet",
            description: """
                Fetch one JPEG image with a grid of thumbnails of up to \(maxContactSheetCount) photos. \
                Each thumbnail has a number label above it, starting at 1, in the order of ids: \
                label N is the photo ids[N-1]. \
                A photo that cannot be loaded, such as one in iCloud while the Mac is offline, \
                shows "Not available". \
                Use it to look at several photos at once, \
                then call photo_image_fetch with the @id of a photo to see it larger.
                """,
            inputSchema: .object(
                properties: [
                    "ids": .array(
                        description: "The @id values of the photos, as returned by photos_fetch, in display order",
                        items: .string(),
                        minItems: 1,
                        maxItems: maxContactSheetCount
                    ),
                    "output": .string(
                        description:
                            "image returns the image; reference writes the image to a file and returns its file URL",
                        default: .string(ImageOutput.image.rawValue),
                        enum: ImageOutput.allCases.map { .string($0.rawValue) }
                    ),
                ],
                required: ["ids"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Photos Contact Sheet",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let request = try Self.contactSheetRequest(from: arguments)
            try await self.requireAccess()
            return try await self.contactSheet(for: request)
        }

        Tool(
            name: "photos_pick",
            description: """
                Show the system photo picker, which can search the library for what photos show, \
                people, places, and text, so that the user can choose photos or videos. \
                Returns the metadata of the items that the user chooses, in the order chosen, \
                like photos_fetch, with no image data; \
                call photo_image_fetch or photos_contact_sheet with their @id values to see them. \
                If the user cancels, the list is empty and cancelled is true. \
                The picker closes after \(Int(pickTimeout.components.seconds)) seconds without a choice. \
                Only one picker can be open at a time. \
                Before macOS 27, the picker opens with no search text, and the user must type the search.
                """,
            inputSchema: .object(
                properties: [
                    "query": .string(
                        description: """
                            Search text that the picker opens with, such as "dog on a beach"; \
                            the user can change it. Needs macOS 27 or later; \
                            on earlier versions the picker opens with no search text, \
                            and the window title shows the query.
                            """
                    ),
                    "limit": .integer(
                        description: "How many items the user can choose",
                        default: .int(1),
                        minimum: 1
                    ),
                    "mediaType": .string(
                        description: "Show only photos or only videos; both when absent",
                        enum: MediaType.allCases.map { .string($0.rawValue) }
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Pick Photos",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let request = try Self.pickRequest(from: arguments)
            try await self.requireAccess()
            return try await self.pick(request, clientName: ToolCallContext.clientName)
        }
    }

    // MARK: - Access

    /// Asks for access the first time, and throws when the user has not allowed it.
    private func requireAccess() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized else {
            throw PhotosError.accessDenied
        }
    }

    // MARK: - Albums

    struct Album {
        enum Kind: String {
            case album, sharedAlbum, smartAlbum, folder
        }

        var id: String
        var name: String?
        var kind: Kind
        var parentID: String?
        var numberOfItems: Int?
        /// The collection to fetch assets from, or nil for a folder.
        var collection: PHAssetCollection?

        var value: Value {
            var object: [String: Value] = [
                "@id": .string(id),
                "kind": .string(kind.rawValue),
            ]
            if let name {
                object["name"] = .string(name)
            }
            if let parentID {
                object["parent"] = .object(["@id": .string(parentID)])
            }
            if let numberOfItems {
                object["numberOfItems"] = .int(numberOfItems)
            }
            return .object(object)
        }
    }

    /// Smart albums that the tools leave out, because they show hidden photos
    /// or describe the state of iCloud uploads rather than photos.
    private static let excludedSmartAlbums: Set<PHAssetCollectionSubtype> = [
        .smartAlbumAllHidden,
        .smartAlbumUnableToUpload,
    ]

    private static func isExcluded(_ collection: PHAssetCollection) -> Bool {
        collection.assetCollectionType == .smartAlbum
            && excludedSmartAlbums.contains(collection.assetCollectionSubtype)
    }

    /// Every album, shared album, smart album, and folder,
    /// with the folder that contains each one.
    private func albums() -> [Album] {
        // Walk the folders from the top level to learn each collection's parent.
        var parents: [String: String] = [:]
        var folders: [PHCollectionList] = []
        var pending: [PHCollectionList?] = [nil]
        while let folder = pending.popLast() {
            let children =
                folder.map { PHCollection.fetchCollections(in: $0, options: nil) }
                ?? PHCollectionList.fetchTopLevelUserCollections(with: nil)
            for index in 0 ..< children.count {
                let child = children.object(at: index)
                if let folder {
                    parents[child.localIdentifier] = folder.localIdentifier
                }
                if let list = child as? PHCollectionList {
                    folders.append(list)
                    pending.append(list)
                }
            }
        }

        var albums: [Album] = []
        var seen: Set<String> = []
        func append(_ album: Album) {
            guard seen.insert(album.id).inserted else { return }
            albums.append(album)
        }

        for type in [PHAssetCollectionType.album, .smartAlbum] {
            let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            for index in 0 ..< collections.count {
                let collection = collections.object(at: index)
                guard !Self.isExcluded(collection) else { continue }
                let kind: Album.Kind =
                    switch collection.assetCollectionType {
                    case .smartAlbum: .smartAlbum
                    default: collection.assetCollectionSubtype == .albumCloudShared ? .sharedAlbum : .album
                    }
                let count = collection.estimatedAssetCount
                append(
                    Album(
                        id: collection.localIdentifier,
                        name: collection.localizedTitle,
                        kind: kind,
                        parentID: parents[collection.localIdentifier],
                        numberOfItems: count == NSNotFound ? nil : count,
                        collection: collection
                    )
                )
            }
        }

        for folder in folders {
            append(
                Album(
                    id: folder.localIdentifier,
                    name: folder.localizedTitle,
                    kind: .folder,
                    parentID: parents[folder.localIdentifier]
                )
            )
        }
        return albums
    }

    /// The album with an identifier, or with a name without regard to case or diacritics.
    private func assetCollection(for album: String) throws -> PHAssetCollection {
        let byID = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album], options: nil)
        if let collection = byID.firstObject, !Self.isExcluded(collection) {
            return collection
        }

        let named = albums().filter {
            $0.id == album || $0.name.map { Self.namesMatch($0, album) } == true
        }
        let collections = named.filter { $0.collection != nil }
        if collections.count == 1, let collection = collections[0].collection {
            return collection
        }
        if collections.count > 1 {
            throw PhotosError.ambiguousAlbum(album, collections.map(\.id))
        }
        if !named.isEmpty {
            throw PhotosError.albumIsFolder(album)
        }
        throw PhotosError.albumNotFound(album)
    }

    static func namesMatch(_ name: String, _ other: String) -> Bool {
        name.compare(other, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    // MARK: - Fetch

    enum MediaType: String, CaseIterable {
        case photo, video

        var assetMediaType: PHAssetMediaType {
            switch self {
            case .photo: .image
            case .video: .video
            }
        }
    }

    /// The `PHAssetMediaSubtype` values that `photos_fetch` filters on and reports.
    enum Subtype: String, CaseIterable {
        case screenshot, livePhoto, panorama, hdr, depthEffect, animation, spatial
        case slomo, timelapse, screenRecording, cinematic

        var mediaSubtype: PHAssetMediaSubtype {
            switch self {
            case .screenshot: .photoScreenshot
            case .livePhoto: .photoLive
            case .panorama: .photoPanorama
            case .hdr: .photoHDR
            case .depthEffect: .photoDepthEffect
            // The Xcode 26 SDK does not declare `.photoAnimation`, although macOS 10.15 has it,
            // so this uses its value, which the Xcode 27 SDK declares as `1 << 6`.
            case .animation: PHAssetMediaSubtype(rawValue: 1 << 6)
            case .spatial: .spatialMedia
            case .slomo: .videoHighFrameRate
            case .timelapse: .videoTimelapse
            case .screenRecording: .videoScreenRecording
            case .cinematic: .videoCinematic
            }
        }

        /// The subtypes that a set of media subtypes contains, in declaration order.
        static func subtypes(in mediaSubtypes: PHAssetMediaSubtype) -> [Subtype] {
            allCases.filter { mediaSubtypes.contains($0.mediaSubtype) }
        }
    }

    /// A circle on the Earth's surface.
    struct Region: Equatable {
        var latitude: Double
        var longitude: Double
        /// The radius in meters.
        var radius: Double

        func contains(_ location: CLLocation?) -> Bool {
            guard let location, CLLocationCoordinate2DIsValid(location.coordinate) else {
                return false
            }
            let center = CLLocation(latitude: latitude, longitude: longitude)
            return location.distance(from: center) <= radius
        }
    }

    /// A position in the newest-first order of `photos_fetch`:
    /// the creation date and local identifier of the last item that a call examined.
    ///
    /// Items with the same creation date are in descending order of local identifier,
    /// so the position stays exact when photos are added between calls
    /// or several photos have the same creation date.
    struct Cursor: Equatable, LosslessStringConvertible {
        var creationDate: Date
        var localIdentifier: String

        init(creationDate: Date, localIdentifier: String) {
            self.creationDate = creationDate
            self.localIdentifier = localIdentifier
        }

        /// Decodes a cursor from its description.
        init?(_ description: String) {
            var base64 = description.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            guard
                let data = Data(base64Encoded: base64),
                let text = String(data: data, encoding: .utf8),
                let separator = text.firstIndex(of: "\n"),
                let interval = Double(text[..<separator]),
                interval.isFinite
            else {
                return nil
            }
            let identifier = String(text[text.index(after: separator)...])
            guard !identifier.isEmpty else { return nil }
            self.init(
                creationDate: Date(timeIntervalSinceReferenceDate: interval),
                localIdentifier: identifier
            )
        }

        /// The cursor as URL-safe Base64 text.
        /// The time interval's description converts back to the same `Double`,
        /// so the decoded date is equal to the date in the library.
        var description: String {
            let text = "\(creationDate.timeIntervalSinceReferenceDate)\n\(localIdentifier)"
            return Data(text.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        /// Whether a position comes after this one in newest-first order.
        func precedes(_ other: Cursor) -> Bool {
            other.creationDate < creationDate
                || (other.creationDate == creationDate && other.localIdentifier < localIdentifier)
        }
    }

    struct FetchRequest: Equatable {
        var album: String?
        var startDate: Date?
        var endDate: Date?
        var mediaType: MediaType?
        var subtypes: [Subtype] = []
        var favoritesOnly = false
        var query: String?
        var near: Region?
        var limit = defaultLimit
        var cursor: Cursor?

        /// Whether the service filters fetched assets itself,
        /// because PhotoKit cannot apply `query` or `near`.
        var filtersFetchedAssets: Bool {
            query != nil || near != nil
        }

        /// The conditions that PhotoKit applies, which use only the asset keys that it accepts.
        /// The album is not among them: PhotoKit fetches from an album with `fetchAssets(in:options:)`.
        var predicate: NSPredicate {
            var predicates: [NSPredicate] = []
            if let mediaType {
                predicates.append(
                    NSPredicate(format: "mediaType == %ld", mediaType.assetMediaType.rawValue)
                )
            } else {
                predicates.append(
                    NSPredicate(
                        format: "mediaType == %ld OR mediaType == %ld",
                        PHAssetMediaType.image.rawValue,
                        PHAssetMediaType.video.rawValue
                    )
                )
            }
            if !subtypes.isEmpty {
                let mask = subtypes.reduce(PHAssetMediaSubtype()) { $0.union($1.mediaSubtype) }
                predicates.append(NSPredicate(format: "(mediaSubtypes & %lu) != 0", mask.rawValue))
            }
            if favoritesOnly {
                predicates.append(NSPredicate(format: "isFavorite == YES"))
            }
            if let startDate {
                predicates.append(NSPredicate(format: "creationDate >= %@", startDate as NSDate))
            }
            if let endDate {
                predicates.append(NSPredicate(format: "creationDate < %@", endDate as NSDate))
            }
            if let cursor {
                // Items with the cursor's date are filtered by identifier after the fetch.
                predicates.append(NSPredicate(format: "creationDate <= %@", cursor.creationDate as NSDate))
            }
            return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }
    }

    static func fetchRequest(from arguments: [String: Value]) throws -> FetchRequest {
        var request = FetchRequest()
        request.album = try argument("album", in: arguments, as: \.stringValue)
        if let start = try argument("start", in: arguments, as: \.stringValue) {
            guard let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: start) else {
                throw PhotosError.invalidArgument("start must be an ISO 8601 date")
            }
            request.startDate = Calendar.current.normalizedStartDate(from: parsed.date, isDateOnly: parsed.isDateOnly)
        }
        if let end = try argument("end", in: arguments, as: \.stringValue) {
            guard let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: end) else {
                throw PhotosError.invalidArgument("end must be an ISO 8601 date")
            }
            request.endDate = Calendar.current.normalizedEndDate(from: parsed.date, isDateOnly: parsed.isDateOnly)
        }
        if let mediaType = try argument("mediaType", in: arguments, as: \.stringValue) {
            guard let parsed = MediaType(rawValue: mediaType) else {
                throw PhotosError.invalidArgument("mediaType must be photo or video")
            }
            request.mediaType = parsed
        }
        if let subtypes = try argument("subtypes", in: arguments, as: \.arrayValue) {
            guard !subtypes.isEmpty else {
                throw PhotosError.invalidArgument("subtypes must not be empty")
            }
            request.subtypes = try subtypes.map { value in
                guard let name = value.stringValue, let subtype = Subtype(rawValue: name) else {
                    let names = Subtype.allCases.map(\.rawValue).joined(separator: ", ")
                    throw PhotosError.invalidArgument("subtypes must contain only \(names)")
                }
                return subtype
            }
        }
        request.favoritesOnly = try argument("favorite", in: arguments, as: \.boolValue) ?? false
        if let query = try argument("query", in: arguments, as: \.stringValue) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw PhotosError.invalidArgument("query must not be empty")
            }
            request.query = trimmed
        }
        if let near = try argument("near", in: arguments, as: \.objectValue) {
            request.near = try region(from: near)
        }
        if let limit = try argument("limit", in: arguments, as: exactInt) {
            guard limit >= 1 else {
                throw PhotosError.invalidArgument("limit must be a positive integer")
            }
            request.limit = limit
        }
        if let cursor = try argument("cursor", in: arguments, as: \.stringValue) {
            guard let parsed = Cursor(cursor) else {
                throw PhotosError.invalidArgument("cursor must be a nextCursor value from photos_fetch")
            }
            request.cursor = parsed
        }
        return request
    }

    private static func region(from object: [String: Value]) throws -> Region {
        func coordinate(_ name: String, within range: ClosedRange<Double>) throws -> Double {
            guard let value = object[name].flatMap(number), range.contains(value) else {
                throw PhotosError.invalidArgument(
                    "near.\(name) must be a number from \(Int(range.lowerBound)) to \(Int(range.upperBound))"
                )
            }
            return value
        }
        let unknown = Set(object.keys).subtracting(["latitude", "longitude", "radius"])
        guard unknown.isEmpty else {
            throw PhotosError.invalidArgument(
                "near has unknown properties: \(unknown.sorted().joined(separator: ", "))"
            )
        }
        let latitude = try coordinate("latitude", within: -90 ... 90)
        let longitude = try coordinate("longitude", within: -180 ... 180)
        guard let radius = object["radius"].flatMap(number), radius > 0, radius.isFinite else {
            throw PhotosError.invalidArgument("near.radius must be a positive number of meters")
        }
        return Region(latitude: latitude, longitude: longitude, radius: radius)
    }

    /// Whether an asset's caption, keywords, or file name contains the query,
    /// without regard to case or diacritics.
    static func matches(query: String, caption: String?, keywords: [String], filename: String?) -> Bool {
        let fields = [caption, filename].compactMap { $0 } + keywords
        return fields.contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Returns one page of a newest-first sequence of items.
    ///
    /// The items must be in descending order of creation date.
    /// PhotoKit cannot sort by a second key, so the page reads each run of items
    /// with the same creation date together and orders the run by descending local identifier,
    /// so that every call sees those items in the same order.
    /// For this reason a page can read more items than `limit` or `scanLimit`:
    /// at most the rest of one such run, and the one item after it that ends the run.
    /// The page stops before it reads another run when it is full or has examined `scanLimit` items.
    /// Items without a creation date are skipped, because a cursor cannot hold their position.
    ///
    /// - Parameters:
    ///   - count: The number of items.
    ///   - item: Returns the item at an index; it is called at most once for each index,
    ///     and only for the items that the page needs.
    ///   - key: Returns an item's position, or nil when it has no creation date.
    ///   - cursor: The position after which the page starts.
    ///   - limit: The most items to return.
    ///   - scanLimit: The most items to examine, when `matches` filters them.
    ///   - matches: Whether to return an item.
    /// - Returns: The matching items, and the position of the last examined item
    ///   when more items remain.
    static func page<Item>(
        count: Int,
        item: (Int) -> Item,
        key: (Item) -> Cursor?,
        after cursor: Cursor?,
        limit: Int,
        scanLimit: Int? = nil,
        matches: (Item) -> Bool = { _ in true }
    ) -> (items: [Item], nextCursor: Cursor?) {
        var results: [Item] = []
        var scanned = 0
        var last: Cursor?
        var index = 0
        // The item that ended the previous run, which starts the next one.
        var lookahead: (item: Item, key: Cursor)?

        func nextItem() -> (item: Item, key: Cursor)? {
            while index < count {
                let candidate = item(index)
                index += 1
                if let candidateKey = key(candidate) {
                    return (candidate, candidateKey)
                }
            }
            return nil
        }

        func isFull() -> Bool {
            results.count == limit || scanLimit.map { scanned >= $0 } == true
        }

        while true {
            if isFull() {
                let hasMore = lookahead != nil || index < count
                return (results, hasMore ? last : nil)
            }
            guard let first = lookahead ?? nextItem() else { break }
            lookahead = nil
            var group = [first]
            while let next = nextItem() {
                guard next.key.creationDate == first.key.creationDate else {
                    lookahead = next
                    break
                }
                group.append(next)
            }
            group.sort { $0.key.localIdentifier > $1.key.localIdentifier }

            for (candidate, candidateKey) in group {
                if let cursor, !cursor.precedes(candidateKey) {
                    continue
                }
                if isFull() {
                    return (results, last)
                }
                scanned += 1
                last = candidateKey
                if matches(candidate) {
                    results.append(candidate)
                }
            }
        }
        return (results, nil)
    }

    private func fetch(_ request: FetchRequest) throws -> Value {
        let collection = try request.album.map(assetCollection(for:))

        let options = PHFetchOptions()
        options.predicate = request.predicate
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        Self.prefetchExtendedMetadata(options)
        let assets =
            collection.map { PHAsset.fetchAssets(in: $0, options: options) }
            ?? PHAsset.fetchAssets(with: options)

        let page = Self.page(
            count: assets.count,
            item: assets.object(at:),
            key: { asset in
                asset.creationDate.map { Cursor(creationDate: $0, localIdentifier: asset.localIdentifier) }
            },
            after: request.cursor,
            limit: request.limit,
            scanLimit: request.filtersFetchedAssets ? maxScannedAssets : nil,
            matches: { asset in
                if let near = request.near, !near.contains(asset.location) {
                    return false
                }
                if let query = request.query {
                    guard let metadata = Self.searchableMetadata(of: asset) else { return false }
                    return Self.matches(
                        query: query,
                        caption: metadata.caption,
                        keywords: metadata.keywords,
                        filename: metadata.filename
                    )
                }
                return true
            }
        )

        let items = page.items.map { asset in
            Self.value(of: asset, metadata: Self.metadata(of: asset, resource: Self.primaryResource(of: asset)))
        }
        var list: [String: Value] = [
            "@context": "https://schema.org",
            "@type": "ItemList",
            "name": .string(collection?.localizedTitle ?? "Photos"),
            "numberOfItems": .int(items.count),
            "itemListElement": .array(items),
        ]
        if let nextCursor = page.nextCursor {
            list["nextCursor"] = .string(nextCursor.description)
        }
        return .object(list)
    }

    /// An asset as an `ImageObject` or a `VideoObject`, without the properties it has no value for.
    private static func value(of asset: PHAsset, metadata: AssetMetadata) -> Value {
        var object: [String: Value] = [
            "@type": asset.mediaType == .video ? "VideoObject" : "ImageObject",
            "@id": .string(asset.localIdentifier),
            "width": .int(asset.pixelWidth),
            "height": .int(asset.pixelHeight),
            "favorite": .bool(asset.isFavorite),
            "edited": .bool(asset.hasAdjustments),
        ]
        if let filename = metadata.filename {
            object["name"] = .string(filename)
        }
        if let caption = metadata.caption, !caption.isEmpty {
            object["caption"] = .string(caption)
        }
        if !metadata.keywords.isEmpty {
            object["keywords"] = .array(metadata.keywords.map { .string($0) })
        }
        if let date = asset.creationDate {
            object["dateCreated"] = .string(date.formatted(.iso8601))
        }
        if let date = asset.modificationDate {
            object["dateModified"] = .string(date.formatted(.iso8601))
        }
        if asset.mediaType == .video, let duration = iso8601Duration(asset.duration) {
            object["duration"] = .string(duration)
        }
        if let encodingFormat = metadata.encodingFormat {
            object["encodingFormat"] = .string(encodingFormat)
        }
        if let contentSize = metadata.contentSize {
            object["contentSize"] = .int(contentSize)
        }
        if let location = asset.location, let coordinates = geoCoordinates(location) {
            object["contentLocation"] = coordinates
        }
        if let rating = metadata.rating {
            object["rating"] = .int(rating)
        }
        let subtypes = Subtype.subtypes(in: asset.mediaSubtypes)
        if !subtypes.isEmpty {
            object["subtypes"] = .array(subtypes.map { .string($0.rawValue) })
        }
        return .object(object)
    }

    /// A duration in seconds in ISO 8601 format, such as `PT1M5.5S`, to a tenth of a second.
    static func iso8601Duration(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let tenths = Int((seconds * 10).rounded())
        let hours = tenths / 36_000
        let minutes = tenths % 36_000 / 600
        let remainder = tenths % 600
        var text = "PT"
        if hours > 0 { text += "\(hours)H" }
        if minutes > 0 { text += "\(minutes)M" }
        if remainder > 0 || (hours == 0 && minutes == 0) {
            text += remainder % 10 == 0 ? "\(remainder / 10)S" : "\(remainder / 10).\(remainder % 10)S"
        }
        return text
    }

    /// A location as Schema.org `GeoCoordinates`, with the elevation when it is known.
    static func geoCoordinates(_ location: CLLocation) -> Value? {
        guard CLLocationCoordinate2DIsValid(location.coordinate) else { return nil }
        var object: [String: Value] = [
            "@type": "GeoCoordinates",
            "latitude": .double(location.coordinate.latitude),
            "longitude": .double(location.coordinate.longitude),
        ]
        if location.verticalAccuracy >= 0 {
            object["elevation"] = .double(location.altitude)
        }
        return .object(object)
    }

    /// The resource that holds an asset's original photo or video.
    private static func primaryResource(of asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let type: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        return resources.first { $0.type == type } ?? resources.first
    }

    // MARK: - Metadata That Needs macOS 26 or 27

    /// The properties of an asset that are only on some versions of macOS.
    struct AssetMetadata: Equatable {
        var filename: String?
        var caption: String?
        var keywords: [String] = []
        var encodingFormat: String?
        var contentSize: Int?
        var rating: Int?
    }

    // The macOS 27 symbols are not in the Xcode 26 SDK, so each use needs
    // `#if compiler(>=6.4)` as well as `#available`.
    // Every Xcode 26 release has Swift 6.3 or earlier, and every Xcode 27 release has Swift 6.4 or later.

    /// Whether `photos_fetch` can match `query`, which needs the extended metadata of macOS 27.
    static var canMatchQuery: Bool {
        #if compiler(>=6.4)
            if #available(macOS 27, *) {
                return true
            }
        #endif
        return false
    }

    /// Fetches the extended metadata with the assets, on macOS 27 or later.
    private static func prefetchExtendedMetadata(_ options: PHFetchOptions) {
        #if compiler(>=6.4)
            if #available(macOS 27, *) {
                options.prefetchAssetExtendedMetadata = true
            }
        #endif
    }

    /// The caption, keywords, and file name that `query` matches, or nil before macOS 27.
    private static func searchableMetadata(of asset: PHAsset) -> AssetMetadata? {
        #if compiler(>=6.4)
            if #available(macOS 27, *) {
                let extended = asset.extendedMetadata
                return AssetMetadata(
                    filename: extended.originalFilename,
                    caption: extended.caption,
                    keywords: extended.keywords
                )
            }
        #endif
        return nil
    }

    private static func metadata(of asset: PHAsset, resource: PHAssetResource?) -> AssetMetadata {
        var metadata = AssetMetadata()
        if #available(macOS 26, *) {
            metadata.encodingFormat = asset.contentType.preferredMIMEType ?? asset.contentType.identifier
        }
        #if compiler(>=6.4)
            if #available(macOS 27, *) {
                let extended = asset.extendedMetadata
                metadata.filename = extended.originalFilename
                metadata.caption = extended.caption
                metadata.keywords = extended.keywords
                metadata.contentSize = resource?.dataSize
                if asset.rating != .unset {
                    metadata.rating = asset.rating.rawValue
                }
                return metadata
            }
        #endif
        metadata.filename = resource?.originalFilename
        return metadata
    }

    // MARK: - Images

    enum ImageOutput: String, CaseIterable {
        case image, reference
    }

    struct ImageRequest: Equatable {
        var id: String
        var maxDimension = defaultMaxDimension
        var original = false
        var output = ImageOutput.image
        var fullSize = false
    }

    static func imageRequest(from arguments: [String: Value]) throws -> ImageRequest {
        guard let id = try argument("id", in: arguments, as: \.stringValue), !id.isEmpty else {
            throw PhotosError.invalidArgument("id must be the @id of a photo from photos_fetch")
        }
        var request = ImageRequest(id: id)
        if let maxDimension = try argument("maxDimension", in: arguments, as: exactInt) {
            guard (1 ... maxMaxDimension).contains(maxDimension) else {
                throw PhotosError.invalidArgument("maxDimension must be from 1 to \(maxMaxDimension)")
            }
            request.maxDimension = maxDimension
        }
        request.original = try argument("original", in: arguments, as: \.boolValue) ?? false
        request.output = try output(from: arguments)
        request.fullSize = try argument("fullSize", in: arguments, as: \.boolValue) ?? false
        if request.fullSize, request.output != .reference {
            throw PhotosError.invalidArgument("fullSize needs output set to reference")
        }
        return request
    }

    struct ContactSheetRequest: Equatable {
        var ids: [String]
        var output = ImageOutput.image
    }

    static func contactSheetRequest(from arguments: [String: Value]) throws -> ContactSheetRequest {
        guard let values = try argument("ids", in: arguments, as: \.arrayValue) else {
            throw PhotosError.invalidArgument("ids must be an array of @id values from photos_fetch")
        }
        guard (1 ... maxContactSheetCount).contains(values.count) else {
            throw PhotosError.invalidArgument("ids must have 1 to \(maxContactSheetCount) values")
        }
        let ids = try values.enumerated().map { index, value in
            guard let id = value.stringValue, !id.isEmpty else {
                throw PhotosError.invalidArgument("ids[\(index)] must be the @id of a photo from photos_fetch")
            }
            return id
        }
        return ContactSheetRequest(ids: ids, output: try output(from: arguments))
    }

    private static func output(from arguments: [String: Value]) throws -> ImageOutput {
        guard let output = try argument("output", in: arguments, as: \.stringValue) else {
            return .image
        }
        guard let parsed = ImageOutput(rawValue: output) else {
            throw PhotosError.invalidArgument("output must be image or reference")
        }
        return parsed
    }

    /// The photo or video with an identifier.
    /// A hidden asset gets the same error as an unknown identifier,
    /// because fetching by identifier includes hidden assets.
    private func visibleAsset(withID id: String) throws -> PHAsset {
        guard let result = visibleAssets(withIDs: [id])[id] else {
            throw PhotosError.photoNotFound(id)
        }
        return try result.get()
    }

    private func visibleAssets(withIDs ids: [String]) -> [String: Result<PHAsset, PhotosError>] {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(Set(ids)), options: nil)
        var assets: [String: PHAsset] = [:]
        for index in 0 ..< fetched.count {
            let asset = fetched.object(at: index)
            guard !asset.isHidden, asset.mediaType == .image || asset.mediaType == .video else { continue }
            assets[asset.localIdentifier] = asset
        }
        var results: [String: Result<PHAsset, PhotosError>] = [:]
        for id in ids {
            results[id] = assets[id].map { .success($0) } ?? .failure(.photoNotFound(id))
        }
        return results
    }

    private func image(for request: ImageRequest) async throws -> Value {
        let asset = try visibleAsset(withID: request.id)
        if request.fullSize {
            return try await fullSizeFile(of: asset, original: request.original)
        }

        let size = Self.targetSize(
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            maxDimension: request.maxDimension
        )
        let image = try await Self.requestImage(
            for: asset,
            targetSize: size,
            contentMode: .aspectFit,
            original: request.original
        )
        let data = try Self.jpegData(Self.sRGBImage(image), quality: jpegQuality)
        switch request.output {
        case .image:
            return .data(mimeType: "image/jpeg", data)
        case .reference:
            let url = try Self.writeReferenceFile(data, pathExtension: "jpg")
            return Self.referenceValue(
                id: request.id,
                url: url,
                encodingFormat: "image/jpeg",
                size: data.count,
                width: image.width,
                height: image.height
            )
        }
    }

    /// The size that fits an image's longest edge to a length, without enlarging it.
    static func targetSize(width: Int, height: Int, maxDimension: Int) -> CGSize {
        guard width > 0, height > 0 else {
            return CGSize(width: maxDimension, height: maxDimension)
        }
        let scale = min(1, Double(maxDimension) / Double(max(width, height)))
        return CGSize(
            width: max(1, (Double(width) * scale).rounded()),
            height: max(1, (Double(height) * scale).rounded())
        )
    }

    /// Writes the full-size image file of a photo, with its metadata, and returns a reference to it.
    private func fullSizeFile(of asset: PHAsset, original: Bool) async throws -> Value {
        guard asset.mediaType == .image else {
            throw PhotosError.invalidArgument("fullSize is only for photos, and \(asset.localIdentifier) is a video")
        }

        let url: URL
        let type: UTType?
        if original {
            let resources = PHAssetResource.assetResources(for: asset)
            guard let resource = resources.first(where: { $0.type == .photo }) else {
                throw PhotosError.noImageFile(asset.localIdentifier)
            }
            type = UTType(resource.uniformTypeIdentifier)
            url = try await Self.writeResource(
                resource,
                of: asset,
                pathExtension: type?.preferredFilenameExtension ?? "dat"
            )
        } else {
            let (data, uti) = try await Self.requestImageData(for: asset)
            type = uti.flatMap(UTType.init)
            url = try Self.writeReferenceFile(data, pathExtension: type?.preferredFilenameExtension ?? "dat")
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        var width: Int?
        var height: Int?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        {
            width = properties[kCGImagePropertyPixelWidth] as? Int
            height = properties[kCGImagePropertyPixelHeight] as? Int
        }
        return Self.referenceValue(
            id: asset.localIdentifier,
            url: url,
            encodingFormat: type?.preferredMIMEType ?? type?.identifier,
            size: size,
            width: width,
            height: height
        )
    }

    private func contactSheet(for request: ContactSheetRequest) async throws -> Value {
        let found = visibleAssets(withIDs: request.ids)
        var assets: [PHAsset] = []
        for (index, id) in request.ids.enumerated() {
            guard let asset = try? found[id]?.get() else {
                throw PhotosError.contactSheetPhotoNotFound(id, position: index + 1)
            }
            assets.append(asset)
        }

        let thumbnailSize = CGSize(width: ContactSheet.thumbnailSize, height: ContactSheet.thumbnailSize)
        // Cancellation ends the call; any other failure leaves a "Not available" cell.
        let thumbnails = try await withThrowingTaskGroup(of: (Int, CGImage?).self) { group in
            for (index, asset) in assets.enumerated() {
                group.addTask {
                    do {
                        let image = try await Self.requestImage(
                            for: asset,
                            targetSize: thumbnailSize,
                            contentMode: .aspectFit,
                            original: false
                        )
                        return (index, image)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try Task.checkCancellation()
                        log.error("Contact sheet thumbnail \(index + 1) failed: \(error.localizedDescription)")
                        return (index, nil)
                    }
                }
            }
            var thumbnails = [CGImage?](repeating: nil, count: assets.count)
            for try await (index, image) in group {
                thumbnails[index] = image
            }
            return thumbnails
        }

        try Task.checkCancellation()
        let sheet = try ContactSheet.render(thumbnails)
        let data = try ContactSheet.jpegData(sheet)
        switch request.output {
        case .image:
            return .data(mimeType: "image/jpeg", data)
        case .reference:
            try Task.checkCancellation()
            let url = try Self.writeReferenceFile(data, pathExtension: "jpg")
            return Self.referenceValue(
                id: nil,
                url: url,
                encodingFormat: "image/jpeg",
                size: data.count,
                width: sheet.width,
                height: sheet.height
            )
        }
    }

    // MARK: - Picker

    struct PickRequest: Equatable {
        var query: String?
        var limit = 1
        var mediaType: MediaType?
    }

    static func pickRequest(from arguments: [String: Value]) throws -> PickRequest {
        var request = PickRequest()
        if let query = try argument("query", in: arguments, as: \.stringValue) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw PhotosError.invalidArgument("query must not be empty")
            }
            request.query = trimmed
        }
        if let limit = try argument("limit", in: arguments, as: exactInt) {
            guard limit >= 1 else {
                throw PhotosError.invalidArgument("limit must be a positive integer")
            }
            request.limit = limit
        }
        if let mediaType = try argument("mediaType", in: arguments, as: \.stringValue) {
            guard let parsed = MediaType(rawValue: mediaType) else {
                throw PhotosError.invalidArgument("mediaType must be photo or video")
            }
            request.mediaType = parsed
        }
        return request
    }

    /// The picker window's title, which says who asks and for what,
    /// such as "Claude asks for a photo: dog on a beach".
    static func pickerTitle(for request: PickRequest, clientName: String?) -> String {
        let client: String = clientName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let asker: String = client.isEmpty ? "A client" : client
        let things: String
        switch (request.limit, request.mediaType) {
        case (1, .photo): things = "a photo"
        case (1, .video): things = "a video"
        case (1, nil): things = "a photo or video"
        case (let limit, .photo): things = "up to \(limit) photos"
        case (let limit, .video): things = "up to \(limit) videos"
        case (let limit, nil): things = "up to \(limit) photos or videos"
        }
        let title = "\(asker) asks for \(things)"
        guard let query = request.query else { return title }
        return "\(title): \(query)"
    }

    /// What the user did in the picker.
    enum PickOutcome: Equatable {
        /// The user closed the picker without choosing.
        case cancelled
        /// The local identifiers of the chosen items, in the order chosen,
        /// with nil for an item that the picker gave no identifier for.
        case picked([String?])
    }

    /// The result list of `photos_pick`.
    ///
    /// - Parameter item: Returns the values of the items with identifiers.
    ///   It leaves out an item that is hidden or no longer in the library.
    static func pickedList(_ outcome: PickOutcome, item: ([String]) -> [String: Value]) -> Value {
        var list: [String: Value] = [
            "@context": "https://schema.org",
            "@type": "ItemList",
            "name": "Photos Picker",
        ]
        switch outcome {
        case .cancelled:
            list["numberOfItems"] = .int(0)
            list["itemListElement"] = .array([])
            list["cancelled"] = .bool(true)
        case .picked(let ids):
            let identified: [String] = ids.compactMap { (id: String?) -> String? in id }
            let values: [String: Value] = item(identified)
            var items: [Value] = []
            for case let id? in ids {
                if let value = values[id] {
                    items.append(value)
                }
            }
            list["numberOfItems"] = .int(items.count)
            list["itemListElement"] = .array(items)
            list["cancelled"] = .bool(false)
            let leftOut = ids.count - items.count
            if leftOut > 0 {
                list["description"] = .string(
                    leftOut == 1
                        ? "1 chosen item is hidden or no longer in the library, so it is left out."
                        : "\(leftOut) chosen items are hidden or no longer in the library, so they are left out."
                )
            }
        }
        return .object(list)
    }

    private func pick(_ request: PickRequest, clientName: String?) async throws -> Value {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = request.limit
        configuration.selection = request.limit > 1 ? .ordered : .default
        configuration.preferredAssetRepresentationMode = .current
        switch request.mediaType {
        case .photo: configuration.filter = PHPickerFilter.images
        case .video: configuration.filter = PHPickerFilter.videos
        case nil: configuration.filter = nil
        }
        #if compiler(>=6.4)
            if #available(macOS 27, *), let query = request.query {
                configuration.searchText = PHPickerSearchText(query)
            }
        #endif

        let outcome = try await Picker.pick(
            configuration: configuration,
            title: Self.pickerTitle(for: request, clientName: clientName),
            clientName: clientName,
            timeout: pickTimeout
        )
        return Self.pickedList(outcome) { ids in
            var values: [String: Value] = [:]
            for case let (id, .success(asset)) in visibleAssets(withIDs: ids) {
                values[id] = Self.value(
                    of: asset,
                    metadata: Self.metadata(of: asset, resource: Self.primaryResource(of: asset))
                )
            }
            return values
        }
    }

    /// Shows the system photo picker in a window, one at a time, and waits for the user.
    ///
    /// The picker does not tell its delegate when its window closes,
    /// so closing the window counts as a cancel.
    @MainActor
    final class Picker: NSObject, PHPickerViewControllerDelegate, NSWindowDelegate {
        private static var current: Picker?

        private let window: NSWindow
        private var continuation: CheckedContinuation<PickOutcome, Error>?
        private var timeoutTask: Task<Void, Never>?
        private var isFinished = false

        /// Shows a picker and returns what the user does,
        /// or throws if another picker is open, the time runs out, or the task is cancelled.
        static func pick(
            configuration: PHPickerConfiguration,
            title: String,
            clientName: String?,
            timeout: Duration
        ) async throws -> PickOutcome {
            guard current == nil else {
                throw PhotosError.pickerOpen
            }
            try Task.checkCancellation()
            let picker = Picker(configuration: configuration, title: title)
            current = picker
            defer { current = nil }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    picker.continuation = continuation
                    picker.show(title: title, clientName: clientName)
                    picker.timeoutTask = Task { [weak picker] in
                        do {
                            try await Task.sleep(for: timeout)
                        } catch {
                            return
                        }
                        picker?.finish(.failure(PhotosError.pickerTimedOut(timeout)))
                    }
                }
            } onCancel: {
                Task { @MainActor in picker.finish(.failure(CancellationError())) }
            }
        }

        private init(configuration: PHPickerConfiguration, title: String) {
            let controller = PHPickerViewController(configuration: configuration)
            window = NSWindow(contentViewController: controller)
            super.init()
            controller.delegate = self
            window.title = title
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 800, height: 600))
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.delegate = self
        }

        private func show(title: String, clientName: String?) {
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)

            // If the window still opens behind the frontmost app,
            // bring it forward without activation and tell the user where it is.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, !self.isFinished, !(NSApp.isActive && self.window.isKeyWindow) else { return }
                self.window.orderFrontRegardless()
                Self.notify(title: title, clientName: clientName)
            }
        }

        private static func notify(title: String, clientName: String?) {
            let content = UNMutableNotificationContent()
            if let clientName {
                content.title = "\(clientName) asks for photos"
            } else {
                content.title = "A client asks for photos"
            }
            content.body = "Choose in the iMCP window \"\(title)\"."
            let request = UNNotificationRequest(
                identifier: "photos-pick-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    log.error("Failed to send the photo picker notification: \(error.localizedDescription)")
                }
            }
        }

        /// Closes the window and resumes the call with the first result; later results are ignored.
        private func finish(_ result: Result<PickOutcome, Error>) {
            guard !isFinished else { return }
            isFinished = true
            timeoutTask?.cancel()
            timeoutTask = nil
            window.delegate = nil
            (window.contentViewController as? PHPickerViewController)?.delegate = nil
            window.close()
            window.contentViewController = nil
            let continuation = self.continuation
            self.continuation = nil
            continuation?.resume(with: result)
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            finish(.success(results.isEmpty ? .cancelled : .picked(results.map(\.assetIdentifier))))
        }

        func windowWillClose(_ notification: Notification) {
            finish(.success(.cancelled))
        }
    }

    // MARK: - PhotoKit Requests

    /// Renders an asset's image, downloading it from iCloud when needed.
    static func requestImage(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        original: Bool
    ) async throws -> CGImage {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.version = original ? .original : .current
        let manager = PHImageManager.default()
        let id = asset.localIdentifier
        return try await withPhotoKitRequest(
            id: id,
            start: { finish in
                manager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    options: options
                ) { image, info in
                    if (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue == true {
                        return
                    }
                    if let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        finish(.success(cgImage))
                    } else {
                        finish(.failure(PhotosError.failure(id, info: info)))
                    }
                }
            },
            cancel: manager.cancelImageRequest
        )
    }

    /// The data of an asset's current image file, as Photos stores it, and its type.
    private static func requestImageData(for asset: PHAsset) async throws -> (Data, String?) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.version = .current
        let manager = PHImageManager.default()
        let id = asset.localIdentifier
        return try await withPhotoKitRequest(
            id: id,
            start: { finish in
                manager.requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, info in
                    if let data {
                        finish(.success((data, uti)))
                    } else {
                        finish(.failure(PhotosError.failure(id, info: info)))
                    }
                }
            },
            cancel: manager.cancelImageRequest
        )
    }

    /// Writes a resource's data to a new reference file, and returns the file's URL.
    ///
    /// This uses `requestData` with a file handle rather than `writeData(for:toFile:options:)`,
    /// because only `requestData` returns a request that a timeout can cancel.
    /// The file is removed if any step fails after its creation.
    private static func writeResource(
        _ resource: PHAssetResource,
        of asset: PHAsset,
        pathExtension: String
    ) async throws -> URL {
        let connectionID = ToolCallContext.connectionID
        let url = try referenceFiles.create(pathExtension: pathExtension, for: connectionID)
        do {
            let handle = try FileHandle(forWritingTo: url)
            do {
                try await writeResource(resource, of: asset, to: handle)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try referenceFiles.finish(url, for: connectionID)
            return url
        } catch {
            referenceFiles.discard(url)
            throw error
        }
    }

    private static func writeResource(
        _ resource: PHAssetResource,
        of asset: PHAsset,
        to handle: FileHandle
    ) async throws {
        let writeError = LockedValue<Error?>(nil)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let manager = PHAssetResourceManager.default()
        let id = asset.localIdentifier
        let _: Void = try await withPhotoKitRequest(
            id: id,
            start: { finish in
                manager.requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: { data in
                        do {
                            try handle.write(contentsOf: data)
                        } catch {
                            writeError.withLock { $0 = $0 ?? error }
                        }
                    },
                    completionHandler: { error in
                        if let error = error ?? writeError.withLock({ $0 }) {
                            finish(.failure(PhotosError.failure(id, error: error)))
                        } else {
                            finish(.success(()))
                        }
                    }
                )
            },
            cancel: manager.cancelDataRequest
        )
    }

    /// Runs a PhotoKit request that calls back once, and cancels it after a timeout
    /// or when the task is cancelled.
    ///
    /// - Parameters:
    ///   - start: Starts the request with a callback for its result, and returns the request's ID.
    ///   - cancel: Cancels the request with an ID.
    static func withPhotoKitRequest<T>(
        id: String,
        timeout: Duration = requestTimeout,
        start: (@escaping @Sendable (Result<T, Error>) -> Void) -> Int32,
        cancel: @escaping (Int32) -> Void
    ) async throws -> T {
        let pending = PendingRequest<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.setContinuation(continuation)
                let requestID = start { result in pending.finish(result) }
                pending.setRequestID(requestID, cancel: cancel)
                pending.setTimeoutTask(
                    Task {
                        do {
                            try await Task.sleep(for: timeout)
                        } catch {
                            return
                        }
                        pending.finish(.failure(PhotosError.timedOut(id)), cancelsRequest: true)
                    }
                )
            }
        } onCancel: {
            pending.finish(.failure(CancellationError()), cancelsRequest: true)
        }
    }

    /// A PhotoKit request's continuation, which the first result resumes.
    ///
    /// A result can arrive before the continuation is set, when PhotoKit calls back
    /// before it returns the request ID; the request keeps that result until the continuation takes it.
    /// A cancellation can arrive before the request ID is set; the request is cancelled when the ID arrives.
    /// Later results are ignored.
    final class PendingRequest<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var earlyResult: Result<T, Error>?
        private var isFinished = false
        private var requestID: Int32?
        private var cancel: ((Int32) -> Void)?
        private var cancelsRequest = false
        private var timeoutTask: Task<Void, Never>?

        /// Whether the request still holds a result that no continuation has taken.
        var holdsResult: Bool {
            lock.withLock { earlyResult != nil }
        }

        /// Whether the request still holds a timeout task.
        var holdsTimeoutTask: Bool {
            lock.withLock { timeoutTask != nil }
        }

        func setContinuation(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            if let result = earlyResult {
                earlyResult = nil
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func setRequestID(_ requestID: Int32, cancel: @escaping (Int32) -> Void) {
            lock.lock()
            let shouldCancel = isFinished && cancelsRequest
            if !isFinished {
                self.requestID = requestID
                self.cancel = cancel
            }
            lock.unlock()
            if shouldCancel {
                cancel(requestID)
            }
        }

        /// Keeps a timeout task until the request finishes, or cancels it if the request already has.
        func setTimeoutTask(_ task: Task<Void, Never>) {
            lock.lock()
            if isFinished {
                lock.unlock()
                task.cancel()
            } else {
                timeoutTask = task
                lock.unlock()
            }
        }

        /// Resumes the continuation with the first result, cancels the timeout,
        /// and cancels the request if asked.
        func finish(_ result: Result<T, Error>, cancelsRequest: Bool = false) {
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            isFinished = true
            self.cancelsRequest = cancelsRequest
            let continuation = self.continuation
            self.continuation = nil
            if continuation == nil {
                earlyResult = result
            }
            let requestID = self.requestID
            let cancel = self.cancel
            self.cancel = nil
            let timeoutTask = self.timeoutTask
            self.timeoutTask = nil
            lock.unlock()

            timeoutTask?.cancel()
            if cancelsRequest, let requestID, let cancel {
                cancel(requestID)
            }
            continuation?.resume(with: result)
        }
    }

    // MARK: - Encoding

    /// Draws an image into an sRGB bitmap on white, which drops its metadata and alpha channel.
    static func sRGBImage(_ image: CGImage) throws -> CGImage {
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else {
            throw PhotosError.encodingFailed
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let result = context.makeImage() else {
            throw PhotosError.encodingFailed
        }
        return result
    }

    /// Encodes an image's pixels as a JPEG, with no location or other metadata from the source photo.
    ///
    /// ImageIO still writes a small Exif segment with the color space and dimensions.
    static func jpegData(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else {
            throw PhotosError.encodingFailed
        }
        let properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotosError.encodingFailed
        }
        return data as Data
    }

    // MARK: - Contact Sheets

    enum ContactSheet {
        static let thumbnailSize = 240
        static let labelHeight = 34
        static let padding = 8

        /// The number of columns for a number of thumbnails: about as many as rows.
        static func columns(for count: Int) -> Int {
            max(1, Int(Double(count).squareRoot().rounded(.up)))
        }

        /// Draws thumbnails in a grid, each under a label with its position, starting at 1.
        /// A missing thumbnail leaves its cell empty but labeled.
        static func render(_ thumbnails: [CGImage?]) throws -> CGImage {
            let columns = columns(for: thumbnails.count)
            let rows = (thumbnails.count + columns - 1) / columns
            let cellWidth = thumbnailSize + padding
            let cellHeight = labelHeight + thumbnailSize + padding
            let width = columns * cellWidth + padding
            let height = rows * cellHeight + padding
            guard
                let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                )
            else {
                throw PhotosError.encodingFailed
            }
            context.setFillColor(CGColor(gray: 0.12, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            let labelFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, 26, nil)
            let noteFont = CTFontCreateUIFontForLanguage(.system, 18, nil)
            for (index, thumbnail) in thumbnails.enumerated() {
                let column = index % columns
                let row = index / columns
                // Core Graphics puts the origin at the bottom left.
                let left = padding + column * cellWidth
                let top = height - padding - row * cellHeight
                let imageRect = CGRect(
                    x: left,
                    y: top - labelHeight - thumbnailSize,
                    width: thumbnailSize,
                    height: thumbnailSize
                )

                context.setFillColor(CGColor(gray: 0.2, alpha: 1))
                context.fill(imageRect)
                if let thumbnail {
                    context.draw(thumbnail, in: aspectFitRect(for: thumbnail, in: imageRect))
                } else {
                    // Say why the cell is empty, so that it does not look like a dark photo.
                    let line = try line("Not available", font: noteFont, gray: 0.75)
                    // The image bounds include the context's text position, so measure from the origin.
                    context.textPosition = .zero
                    let bounds = CTLineGetImageBounds(line, context)
                    context.textPosition = CGPoint(
                        x: imageRect.midX - bounds.width / 2 - bounds.minX,
                        y: imageRect.midY - bounds.height / 2 - bounds.minY
                    )
                    CTLineDraw(line, context)
                }

                context.textPosition = CGPoint(x: CGFloat(left + 2), y: CGFloat(top - labelHeight + 8))
                CTLineDraw(try line("\(index + 1)", font: labelFont, gray: 1), context)
            }

            guard let image = context.makeImage() else {
                throw PhotosError.encodingFailed
            }
            return image
        }

        private static func line(_ string: String, font: CTFont?, gray: CGFloat) throws -> CTLine {
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font as Any,
                kCTForegroundColorAttributeName: CGColor(gray: gray, alpha: 1),
            ]
            guard let text = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary) else {
                throw PhotosError.encodingFailed
            }
            return CTLineCreateWithAttributedString(text)
        }

        static func aspectFitRect(for image: CGImage, in rect: CGRect) -> CGRect {
            guard image.width > 0, image.height > 0 else { return rect }
            let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            return CGRect(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }

        /// Encodes a sheet as a JPEG, lowering the quality until it fits the size limit.
        static func jpegData(_ image: CGImage) throws -> Data {
            var data = Data()
            for quality in [jpegQuality, 0.65, 0.5, 0.35] {
                data = try PhotosService.jpegData(image, quality: quality)
                if data.count <= maxContactSheetBytes {
                    break
                }
            }
            return data
        }
    }

    // MARK: - Reference Files

    /// The image files that tools return by reference, in the app's `Library/Caches/Photos` folder.
    static let referenceFiles = ReferenceFiles(
        root: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photos", isDirectory: true)
    )

    /// The files that tools write for clients to read, in one folder for each connection.
    ///
    /// The server does not cancel a tool call when its connection closes,
    /// so a call can finish writing after the connection's folder is removed.
    /// One lock covers the record of closed connections, the decision to write or keep a file,
    /// and the removal of a folder, so that a close and a write cannot interleave:
    /// a write for a closed connection is refused,
    /// and a streamed file that is complete after the close is removed.
    final class ReferenceFiles: @unchecked Sendable {
        let root: URL
        private let lock = NSLock()
        private var closedConnections: Set<UUID> = []

        init(root: URL) {
            self.root = root
        }

        /// The folder for the files of a connection.
        /// Calls outside a client connection use a folder that is removed at launch.
        func directory(for connectionID: UUID?) -> URL {
            root.appendingPathComponent(connectionID?.uuidString ?? "Unattributed", isDirectory: true)
        }

        /// Writes data to a new file for a connection.
        func write(_ data: Data, pathExtension: String, for connectionID: UUID?) throws -> URL {
            try withLock {
                let url = try createFileLocked(pathExtension: pathExtension, for: connectionID)
                do {
                    try data.write(to: url)
                } catch {
                    removeItem(at: url)
                    throw error
                }
                return url
            }
        }

        /// Creates an empty file for a connection, for data that arrives in parts.
        /// Call ``finish(_:for:)`` when the data is complete, or ``discard(_:)`` when it fails.
        func create(pathExtension: String, for connectionID: UUID?) throws -> URL {
            try withLock { try createFileLocked(pathExtension: pathExtension, for: connectionID) }
        }

        /// Keeps a file that ``create(pathExtension:for:)`` made,
        /// or removes it and throws if its connection closed while it was written.
        func finish(_ url: URL, for connectionID: UUID?) throws {
            try withLock {
                if let connectionID, closedConnections.contains(connectionID) {
                    removeItem(at: url)
                    throw PhotosError.connectionClosed
                }
            }
        }

        /// Removes a file whose write failed.
        func discard(_ url: URL) {
            withLock { removeItem(at: url) }
        }

        /// Records that a connection closed, and removes its files.
        func close(_ connectionID: UUID) {
            withLock {
                closedConnections.insert(connectionID)
                removeItem(at: directory(for: connectionID))
            }
        }

        /// Removes every file, which no client can still be reading at launch.
        func removeAll() {
            withLock { removeItem(at: root) }
        }

        private func createFileLocked(pathExtension: String, for connectionID: UUID?) throws -> URL {
            if let connectionID, closedConnections.contains(connectionID) {
                throw PhotosError.connectionClosed
            }
            let directory = directory(for: connectionID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(pathExtension)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw PhotosError.fileNotWritten(url.path)
            }
            return url
        }

        private func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }

        private func removeItem(at url: URL) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                return
            } catch {
                log.error("Failed to remove Photos files at \(url.path): \(error.localizedDescription)")
            }
        }
    }

    private static func writeReferenceFile(_ data: Data, pathExtension: String) throws -> URL {
        try referenceFiles.write(data, pathExtension: pathExtension, for: ToolCallContext.connectionID)
    }

    private static func referenceValue(
        id: String?,
        url: URL,
        encodingFormat: String?,
        size: Int?,
        width: Int?,
        height: Int?
    ) -> Value {
        var object: [String: Value] = [
            "@context": "https://schema.org",
            "@type": "ImageObject",
            "contentUrl": .string(url.absoluteString),
        ]
        if let id {
            object["@id"] = .string(id)
        }
        if let encodingFormat {
            object["encodingFormat"] = .string(encodingFormat)
        }
        if let size {
            object["contentSize"] = .int(size)
        }
        if let width {
            object["width"] = .int(width)
        }
        if let height {
            object["height"] = .int(height)
        }
        return .object(object)
    }

    /// Removes the files that tools wrote for a connection that closed,
    /// and refuses later writes for it.
    static func removeReferenceFiles(for connectionID: UUID) {
        referenceFiles.close(connectionID)
    }

    /// Removes every file that tools wrote, which no client can still be reading at launch.
    static func removeAllReferenceFiles() {
        referenceFiles.removeAll()
    }

    // MARK: - Arguments

    /// Returns an optional argument, or throws if it is present with the wrong type.
    private static func argument<T>(
        _ name: String,
        in arguments: [String: Value],
        as transform: (Value) -> T?
    ) throws -> T? {
        guard let value = arguments[name], !value.isNull else { return nil }
        guard let result = transform(value) else {
            throw PhotosError.invalidArgument("\(name) has the wrong type")
        }
        return result
    }

    /// The integer value of an integer or whole-number argument.
    private static func exactInt(_ value: Value) -> Int? {
        switch value {
        case .int(let value): value
        case .double(let value): Int(exactly: value)
        default: nil
        }
    }

    private static func number(_ value: Value) -> Double? {
        switch value {
        case .int(let value): Double(value)
        case .double(let value): value.isFinite ? value : nil
        default: nil
        }
    }

    // MARK: - Errors

    // The server reports a tool's error by interpolating it,
    // so each error describes itself with its readable message.
    enum PhotosError: LocalizedError, CustomStringConvertible {
        case accessDenied
        case invalidArgument(String)
        case queryNeedsMacOS27
        case albumNotFound(String)
        case albumIsFolder(String)
        case ambiguousAlbum(String, [String])
        case photoNotFound(String)
        case contactSheetPhotoNotFound(String, position: Int)
        case noImageFile(String)
        case inICloud(String)
        case requestFailed(String, String?)
        case timedOut(String)
        case encodingFailed
        case fileNotWritten(String)
        case connectionClosed
        case pickerOpen
        case pickerTimedOut(Duration)

        static func failure(_ id: String, info: [AnyHashable: Any]?) -> PhotosError {
            let error = info?[PHImageErrorKey] as? Error
            let isInCloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue == true
            if isInCloud {
                return .inICloud(id)
            }
            if let error {
                return failure(id, error: error)
            }
            return .requestFailed(id, nil)
        }

        static func failure(_ id: String, error: Error) -> PhotosError {
            if (error as NSError).domain == NSURLErrorDomain {
                return .inICloud(id)
            }
            return .requestFailed(id, error.localizedDescription)
        }

        var description: String { localizedDescription }

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return
                    "iMCP does not have access to Photos; allow it in System Settings > Privacy & Security > Photos, then switch Photos off and on in the iMCP menu"
            case .invalidArgument(let message):
                return "Invalid argument: \(message)"
            case .queryNeedsMacOS27:
                return
                    "query needs macOS 27 or later, which provides captions, keywords, and file names; remove query to fetch without it"
            case .albumNotFound(let album):
                return "No album has the identifier or name \(album); call photos_albums_list to see the albums"
            case .albumIsFolder(let album):
                return "\(album) is a folder; give the @id or name of an album in it from photos_albums_list"
            case .ambiguousAlbum(let album, let ids):
                return "Several albums are named \(album); give one of their @id values: \(ids.joined(separator: ", "))"
            case .photoNotFound(let id):
                return "No photo or video has the identifier \(id)"
            case .contactSheetPhotoNotFound(let id, let position):
                return "No photo or video has the identifier \(id), at position \(position) in ids"
            case .noImageFile(let id):
                return "The photo with identifier \(id) has no original image file"
            case .inICloud(let id):
                return
                    "The photo with identifier \(id) is in iCloud and could not be downloaded; check that the Mac is online and try again"
            case .requestFailed(let id, let message):
                return "Photos could not provide the photo with identifier \(id)"
                    + (message.map { ": \($0)" } ?? "")
            case .timedOut(let id):
                return
                    "Photos did not provide the photo with identifier \(id) in time; it may still be downloading from iCloud, so try again"
            case .encodingFailed:
                return "The image could not be encoded"
            case .connectionClosed:
                return "The client connection closed before the file was written"
            case .fileNotWritten(let path):
                return "The file at \(path) could not be written"
            case .pickerOpen:
                return
                    "The photo picker is already open for another photos_pick call; wait for that call to finish, then try again"
            case .pickerTimedOut(let timeout):
                return
                    "The user did not choose in the photo picker within \(timeout.components.seconds) seconds, so it closed; ask the user before you call photos_pick again"
            }
        }
    }
}

/// A value that a lock protects, for callbacks on PhotoKit's queues.
private final class LockedValue<Wrapped>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Wrapped

    init(_ value: Wrapped) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Wrapped) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
