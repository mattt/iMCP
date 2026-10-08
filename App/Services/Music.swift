import Foundation
import MusicKit
import OSLog

private let log = Logger.service("music")
private let defaultSearchLimit = 10
private let artworkSize = 512

final class MusicService: Service {
    static let shared = MusicService()

    var isActivated: Bool {
        get async {
            return MusicAuthorization.currentStatus == .authorized
        }
    }

    func activate() async throws {
        let status = await MusicAuthorization.request()
        guard status == .authorized else {
            throw NSError(
                domain: "MusicServiceError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Apple Music access not authorized"]
            )
        }
    }

    var tools: [Tool] {
        Tool(
            name: "music_now_playing",
            description: "Get currently playing track info from Music app",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Now Playing",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            try await self.activate()
            return try await self.fetchNowPlaying()
        }

        Tool(
            name: "music_control",
            description: "Control Music app playback using a single action parameter",
            inputSchema: .object(
                properties: [
                    "action": .string(
                        enum: ControlAction.allCases.map { .string($0.rawValue) }
                    ),
                    "position": .number(
                        description: "Playback position in seconds (for seek)"
                    ),
                ],
                required: ["action"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Control Playback",
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()
            guard let actionRaw = arguments["action"]?.stringValue,
                let action = ControlAction(rawValue: actionRaw)
            else {
                throw NSError(
                    domain: "MusicServiceError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid action"]
                )
            }

            var position: Double?
            if let value = arguments["position"], !value.isNull {
                guard let parsed = Double(value), parsed.isFinite else {
                    throw NSError(
                        domain: "MusicServiceError",
                        code: 11,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Position must be a finite number"
                        ]
                    )
                }
                position = parsed
            }

            try await self.performControlAction(action, position: position)
            return true
        }

        Tool(
            name: "music_catalog_search",
            description: "Search the Apple Music catalog",
            inputSchema: .object(
                properties: [
                    "term": .string(description: "Search term"),
                    "types": .array(
                        description: "Catalog types to include",
                        items: .string(
                            enum: CatalogSearchType.allCases.map { .string($0.rawValue) }
                        )
                    ),
                    "limit": .integer(
                        description: "Maximum results per type",
                        default: .int(defaultSearchLimit),
                        minimum: 1,
                        maximum: 50
                    ),
                    "offset": .integer(
                        description: "Offset into the results",
                        minimum: 0
                    ),
                    "includeTopResults": .boolean(
                        description: "Include top results in the response",
                        default: false
                    ),
                ],
                required: ["term"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Apple Music Catalog",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            try await self.activate()
            return try await self.searchCatalog(with: arguments)
        }
    }
}

private enum ControlAction: String, CaseIterable {
    case play
    case pause
    case playpause
    case next
    case previous
    case stop
    case seek
}

private enum CatalogSearchType: String, CaseIterable {
    case songs
    case albums
    case artists
    case playlists
    case musicVideos
    case stations
    case topResults
}

private struct MusicCatalogResult: Encodable {
    let id: String
    let type: String
    let title: String
    let artistName: String?
    let url: URL?
    let artworkURL: URL?
}

extension MusicService {
    @MainActor
    private func executeAppleScript(_ source: String) throws -> NSAppleEventDescriptor {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw NSError(
                domain: "MusicServiceError",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create AppleScript"]
            )
        }

        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            if let errorNumber = errorInfo[NSAppleScript.errorNumber] as? NSNumber,
                errorNumber.intValue == -1743
            {
                throw NSError(
                    domain: "MusicServiceError",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Not authorized to send Apple events to Music. Enable iMCP in System Settings > Privacy & Security > Automation."
                    ]
                )
            }
            throw NSError(
                domain: "MusicServiceError",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: String(describing: errorInfo)]
            )
        }

        return result
    }

    private func listItems(from descriptor: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard descriptor.descriptorType == typeAEList, descriptor.numberOfItems > 0 else {
            return []
        }

        return (1 ... descriptor.numberOfItems).compactMap { index in
            descriptor.atIndex(index)
        }
    }

    @MainActor
    private func fetchNowPlaying() throws -> [String: Value] {
        let script = """
            tell application "Music"
                if player state is stopped then
                    return {"stopped", "", "", "", 0, 0}
                else
                    set trackName to name of current track
                    set trackArtist to artist of current track
                    set trackAlbum to album of current track
                    set trackDuration to duration of current track
                    set trackPosition to player position
                    return {player state as string, trackName, trackArtist, trackAlbum, trackDuration, trackPosition}
                end if
            end tell
            """

        let descriptor = try executeAppleScript(script)
        let items = listItems(from: descriptor)
        guard items.count >= 6 else {
            throw NSError(
                domain: "MusicServiceError",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected Music app response"]
            )
        }

        let state = items[0].stringValue ?? "stopped"
        let title = items[1].stringValue ?? ""
        let artist = items[2].stringValue ?? ""
        let album = items[3].stringValue ?? ""
        let duration = items[4].doubleValue
        let position = items[5].doubleValue

        return [
            "state": .string(state),
            "title": .string(title),
            "artist": .string(artist),
            "album": .string(album),
            "duration": .double(duration),
            "position": .double(position),
        ]
    }

    @MainActor
    private func performControlAction(_ action: ControlAction, position: Double?) throws {
        let script: String
        switch action {
        case .play:
            script = "tell application \"Music\" to play"
        case .pause:
            script = "tell application \"Music\" to pause"
        case .playpause:
            script = "tell application \"Music\" to playpause"
        case .next:
            script = "tell application \"Music\" to next track"
        case .previous:
            script = "tell application \"Music\" to previous track"
        case .stop:
            script = "tell application \"Music\" to stop"
        case .seek:
            guard let position else {
                throw NSError(
                    domain: "MusicServiceError",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Seek position required"]
                )
            }
            let clampedPosition = max(0, position)
            script = "tell application \"Music\" to set player position to \(clampedPosition)"
        }

        log.debug("Executing Music control action: \(action.rawValue)")
        _ = try executeAppleScript(script)
    }

    private func searchCatalog(with arguments: [String: Value]) async throws -> [MusicCatalogResult] {
        guard let term = arguments["term"]?.stringValue, !term.isEmpty else {
            throw NSError(
                domain: "MusicServiceError",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Search term is required"]
            )
        }

        var requestedTypes: [CatalogSearchType] = []
        if let value = arguments["types"], !value.isNull {
            guard let rawTypes = value.arrayValue else {
                throw NSError(
                    domain: "MusicServiceError",
                    code: 12,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Types must be an array of catalog types"
                    ]
                )
            }

            for rawType in rawTypes {
                guard let name = rawType.stringValue,
                    let type = CatalogSearchType(rawValue: name)
                else {
                    throw NSError(
                        domain: "MusicServiceError",
                        code: 12,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unknown catalog type. Expected one of: \(CatalogSearchType.allCases.map(\.rawValue).joined(separator: ", "))"
                        ]
                    )
                }
                requestedTypes.append(type)
            }
        }

        let includeTopResults: Bool
        if let value = arguments["includeTopResults"], !value.isNull {
            guard let flag = value.boolValue else {
                throw NSError(
                    domain: "MusicServiceError",
                    code: 13,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Include top results must be a boolean"
                    ]
                )
            }
            includeTopResults = flag
        } else {
            includeTopResults = requestedTypes.contains(.topResults)
        }

        let (types, includeTopResultsResolved) = resolveSearchTypes(from: requestedTypes)
        var request = MusicCatalogSearchRequest(term: term, types: types)
        request.includeTopResults = includeTopResults || includeTopResultsResolved

        if let value = arguments["limit"], !value.isNull {
            guard let limit = exactInt(from: value), (1 ... 50).contains(limit) else {
                throw NSError(
                    domain: "MusicServiceError",
                    code: 9,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Limit must be an integer between 1 and 50"
                    ]
                )
            }
            request.limit = limit
        } else {
            request.limit = defaultSearchLimit
        }

        if let value = arguments["offset"], !value.isNull {
            guard let offset = exactInt(from: value), offset >= 0 else {
                throw NSError(
                    domain: "MusicServiceError",
                    code: 10,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Offset must be a non-negative integer"
                    ]
                )
            }
            request.offset = offset
        }

        let response = try await request.response()
        var results: [MusicCatalogResult] = []

        if request.includeTopResults {
            for result in response.topResults {
                results.append(contentsOf: mapTopResult(result))
            }
        }

        results.append(
            contentsOf: response.songs.map {
                MusicCatalogResult(
                    id: $0.id.rawValue,
                    type: "song",
                    title: $0.title,
                    artistName: $0.artistName,
                    url: $0.url,
                    artworkURL: $0.artwork?.url(width: artworkSize, height: artworkSize)
                )
            }
        )

        results.append(
            contentsOf: response.albums.map {
                MusicCatalogResult(
                    id: $0.id.rawValue,
                    type: "album",
                    title: $0.title,
                    artistName: $0.artistName,
                    url: $0.url,
                    artworkURL: $0.artwork?.url(width: artworkSize, height: artworkSize)
                )
            }
        )

        results.append(
            contentsOf: response.artists.map {
                MusicCatalogResult(
                    id: $0.id.rawValue,
                    type: "artist",
                    title: $0.name,
                    artistName: nil,
                    url: $0.url,
                    artworkURL: $0.artwork?.url(width: artworkSize, height: artworkSize)
                )
            }
        )

        results.append(
            contentsOf: response.playlists.map {
                MusicCatalogResult(
                    id: $0.id.rawValue,
                    type: "playlist",
                    title: $0.name,
                    artistName: $0.curatorName,
                    url: $0.url,
                    artworkURL: $0.artwork?.url(width: artworkSize, height: artworkSize)
                )
            }
        )

        results.append(
            contentsOf: response.musicVideos.map {
                MusicCatalogResult(
                    id: $0.id.rawValue,
                    type: "musicVideo",
                    title: $0.title,
                    artistName: $0.artistName,
                    url: $0.url,
                    artworkURL: $0.artwork?.url(width: artworkSize, height: artworkSize)
                )
            }
        )

        results.append(
            contentsOf: response.stations.map {
                MusicCatalogResult(
                    id: $0.id.rawValue,
                    type: "station",
                    title: $0.name,
                    artistName: nil,
                    url: $0.url,
                    artworkURL: $0.artwork?.url(width: artworkSize, height: artworkSize)
                )
            }
        )

        return results
    }

    /// Returns the integer value of an integer or whole-number argument.
    ///
    /// Numeric strings are rejected so runtime behavior matches the integer schema.
    private func exactInt(from value: Value) -> Int? {
        switch value {
        case .int(let value):
            return value
        case .double(let value):
            return Int(exactly: value)
        default:
            return nil
        }
    }

    private func resolveSearchTypes(
        from requestedTypes: [CatalogSearchType]
    ) -> ([any MusicCatalogSearchable.Type], Bool) {
        var types: [any MusicCatalogSearchable.Type] = []
        var includeTopResults = false

        for requestedType in requestedTypes {
            switch requestedType {
            case .songs:
                types.append(Song.self)
            case .albums:
                types.append(Album.self)
            case .artists:
                types.append(Artist.self)
            case .playlists:
                types.append(Playlist.self)
            case .musicVideos:
                types.append(MusicVideo.self)
            case .stations:
                types.append(Station.self)
            case .topResults:
                includeTopResults = true
            }
        }

        if types.isEmpty {
            types = [Song.self, Album.self, Artist.self, Playlist.self]
        }

        return (types, includeTopResults)
    }

    private func mapTopResult(
        _ result: MusicCatalogSearchResponse.TopResult
    ) -> [MusicCatalogResult] {
        switch result {
        case .song(let song):
            return [
                MusicCatalogResult(
                    id: song.id.rawValue,
                    type: "song",
                    title: song.title,
                    artistName: song.artistName,
                    url: song.url,
                    artworkURL: song.artwork?.url(width: artworkSize, height: artworkSize)
                )
            ]
        case .album(let album):
            return [
                MusicCatalogResult(
                    id: album.id.rawValue,
                    type: "album",
                    title: album.title,
                    artistName: album.artistName,
                    url: album.url,
                    artworkURL: album.artwork?.url(width: artworkSize, height: artworkSize)
                )
            ]
        case .artist(let artist):
            return [
                MusicCatalogResult(
                    id: artist.id.rawValue,
                    type: "artist",
                    title: artist.name,
                    artistName: nil,
                    url: artist.url,
                    artworkURL: artist.artwork?.url(width: artworkSize, height: artworkSize)
                )
            ]
        case .playlist(let playlist):
            return [
                MusicCatalogResult(
                    id: playlist.id.rawValue,
                    type: "playlist",
                    title: playlist.name,
                    artistName: playlist.curatorName,
                    url: playlist.url,
                    artworkURL: playlist.artwork?.url(width: artworkSize, height: artworkSize)
                )
            ]
        case .musicVideo(let video):
            return [
                MusicCatalogResult(
                    id: video.id.rawValue,
                    type: "musicVideo",
                    title: video.title,
                    artistName: video.artistName,
                    url: video.url,
                    artworkURL: video.artwork?.url(width: artworkSize, height: artworkSize)
                )
            ]
        case .station(let station):
            return [
                MusicCatalogResult(
                    id: station.id.rawValue,
                    type: "station",
                    title: station.name,
                    artistName: nil,
                    url: station.url,
                    artworkURL: station.artwork?.url(width: artworkSize, height: artworkSize)
                )
            ]
        case .curator(let curator):
            return [
                MusicCatalogResult(
                    id: curator.id.rawValue,
                    type: "curator",
                    title: curator.name,
                    artistName: nil,
                    url: curator.url,
                    artworkURL: curator.artwork?.url(width: artworkSize, height: artworkSize)
                )
            ]
        case .radioShow(let show):
            return [
                MusicCatalogResult(
                    id: show.id.rawValue,
                    type: "radioShow",
                    title: show.name,
                    artistName: show.hostName,
                    url: show.url,
                    artworkURL: show.artwork?.url(width: artworkSize, height: artworkSize)
                )
            ]
        case .recordLabel(let label):
            return [
                MusicCatalogResult(
                    id: label.id.rawValue,
                    type: "recordLabel",
                    title: label.name,
                    artistName: nil,
                    url: label.url,
                    artworkURL: label.artwork?.url(width: artworkSize, height: artworkSize)
                )
            ]
        @unknown default:
            return []
        }
    }
}
