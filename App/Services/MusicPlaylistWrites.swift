import Foundation
import MCP

// Creating playlists and changing the tracks in them, through Music's scripting interface.
//
// This file holds the logic that needs no Music app, so that tests can cover it:
// the setting, checking a request, the fixed script, and shaping what it returns.
// `Music.swift` connects it to the Music service.
//
// There is deliberately no tool that deletes a playlist.
// A playlist can hold tracks that exist nowhere else in the library,
// and deleting the playlist deletes them.

/// A request that the playlist tools refuse, and the reason.
enum MusicPlaylistWriteError: LocalizedError, CustomStringConvertible, Equatable {
    case invalid(String)
    case playlistWritesDisabled
    case noSuchPlaylist(String)
    case notEditable(String)
    case automationDenied
    case scriptFailed(String)

    var description: String { localizedDescription }

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return "Invalid argument: \(message)"
        case .playlistWritesDisabled:
            return
                "Changing playlists is turned off. Turn on \"Allow playlist changes\" in iMCP's Music settings to use this tool."
        case .noSuchPlaylist(let id):
            return "No playlist has ID \(id). Use music_playlists_list to find playlist IDs."
        case .notEditable(let message):
            return message
        case .automationDenied:
            return
                "Not authorized to send Apple events to Music. Enable iMCP in System Settings > Privacy & Security > Automation."
        case .scriptFailed(let message):
            return "Music could not complete the request: \(message)"
        }
    }
}

/// The setting that lets clients change playlists, on top of the Music service's "Allow writes".
///
/// "Allow writes" already covers playback control, which Music had before playlist tools,
/// so it starts on.
/// Changing playlists is new, so this setting starts off.
enum MusicPlaylistWrites {
    static let settingKey = "musicPlaylistWritesEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: settingKey) as? Bool ?? false
    }

    /// Throws unless playlist changes are on, so that a tool changes nothing while the setting is off.
    static func requireEnabled(defaults: UserDefaults = .standard) throws {
        guard isEnabled(defaults: defaults) else { throw MusicPlaylistWriteError.playlistWritesDisabled }
    }

    static let toolNames: Set<String> = [
        "music_playlist_create", "music_playlist_add_tracks", "music_playlist_remove_tracks",
    ]

    /// The most tracks that one call adds or removes.
    static let maximumTracks = 100
    static let maximumNameLength = 255

    /// Checks the name of a new playlist.
    static func validatedName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MusicPlaylistWriteError.invalid("name can't be empty") }
        guard name.count <= maximumNameLength else {
            throw MusicPlaylistWriteError.invalid("name can have at most \(maximumNameLength) characters")
        }
        guard !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw MusicPlaylistWriteError.invalid("name can't contain control characters or line breaks")
        }
        return name
    }

    /// Checks a list of track IDs: one to ``maximumTracks`` persistent IDs, in uppercase, without repeats.
    static func validatedTrackIDs(from value: Value?) throws -> [String] {
        guard let value, !value.isNull else { throw MusicPlaylistWriteError.invalid("trackIDs is required") }
        guard let items = value.arrayValue else {
            throw MusicPlaylistWriteError.invalid("trackIDs must be an array of track IDs")
        }
        guard !items.isEmpty else { throw MusicPlaylistWriteError.invalid("trackIDs can't be empty") }
        var ids: [String] = []
        for item in items {
            guard let id = item.stringValue?.uppercased(), id.count == 16, id.allSatisfy(\.isHexDigit) else {
                throw MusicPlaylistWriteError.invalid(
                    "each track ID must be a 16-digit hexadecimal ID, as music_playlist_tracks lists them"
                )
            }
            if !ids.contains(id) { ids.append(id) }
        }
        guard ids.count <= maximumTracks else {
            throw MusicPlaylistWriteError.invalid("trackIDs can have at most \(maximumTracks) different IDs")
        }
        return ids
    }

    /// The AppleScript error numbers that the script uses.
    static let noSuchPlaylistNumber = 1003
    static let notEditableNumber = 1004
}

/// The script, and the calls to its handlers.
///
/// The script is fixed text. The name, the playlist ID, and the track IDs
/// reach it as arguments of a handler, never as part of its source.
enum MusicPlaylistScripts {
    static let source = """
        on requireplain(thePlaylist)
            tell application id "com.apple.Music"
                if (class of thePlaylist) is not user playlist then
                    error "That playlist can't be changed through iMCP." number \(MusicPlaylistWrites.notEditableNumber)
                end if
                if smart of thePlaylist then
                    error "That is a smart playlist, which Music fills by its rules. Only playlists that you filled yourself can be changed." number \(MusicPlaylistWrites.notEditableNumber)
                end if
                if (special kind of thePlaylist) is not none then
                    error "That is a folder or a playlist that Music manages itself. Only playlists that you filled yourself can be changed." number \(MusicPlaylistWrites.notEditableNumber)
                end if
            end tell
        end requireplain

        on createplaylist(playlistName)
            tell application id "com.apple.Music"
                set newPlaylist to make new user playlist with properties {name:playlistName}
                return {persistent ID of newPlaylist, name of newPlaylist}
            end tell
        end createplaylist

        on addtracks(playlistID, trackIDs)
            tell application id "com.apple.Music"
                set matchingPlaylists to (every user playlist whose persistent ID is playlistID)
                if (count of matchingPlaylists) is 0 then error "No playlist has that ID." number \(MusicPlaylistWrites.noSuchPlaylistNumber)
                set thePlaylist to item 1 of matchingPlaylists
                my requireplain(thePlaylist)
                set countBefore to count of tracks of thePlaylist
                set addedIDs to {}
                set missingIDs to {}
                repeat with oneID in trackIDs
                    set theID to contents of oneID
                    set matchingTracks to (every track of library playlist 1 whose persistent ID is theID)
                    if (count of matchingTracks) is 0 then
                        set end of missingIDs to theID
                    else
                        duplicate (item 1 of matchingTracks) to thePlaylist
                        set end of addedIDs to theID
                    end if
                end repeat
                return {name of thePlaylist, countBefore, count of tracks of thePlaylist, addedIDs, missingIDs}
            end tell
        end addtracks

        on removetracks(playlistID, trackIDs)
            tell application id "com.apple.Music"
                set matchingPlaylists to (every user playlist whose persistent ID is playlistID)
                if (count of matchingPlaylists) is 0 then error "No playlist has that ID." number \(MusicPlaylistWrites.noSuchPlaylistNumber)
                set thePlaylist to item 1 of matchingPlaylists
                my requireplain(thePlaylist)
                set countBefore to count of tracks of thePlaylist
                set takenOutIDs to {}
                set missingIDs to {}
                repeat with oneID in trackIDs
                    set theID to contents of oneID
                    if (count of (every track of thePlaylist whose persistent ID is theID)) is 0 then
                        set end of missingIDs to theID
                    else
                        delete (every track of thePlaylist whose persistent ID is theID)
                        set end of takenOutIDs to theID
                    end if
                end repeat
                return {name of thePlaylist, countBefore, count of tracks of thePlaylist, takenOutIDs, missingIDs}
            end tell
        end removetracks
        """

    static func createPlaylist(name: String) -> NSAppleScript.Subroutine {
        .init("createplaylist", [.string(name)])
    }

    static func addTracks(playlistID: String, trackIDs: [String]) -> NSAppleScript.Subroutine {
        .init("addtracks", [.string(playlistID), .strings(trackIDs)])
    }

    static func removeTracks(playlistID: String, trackIDs: [String]) -> NSAppleScript.Subroutine {
        .init("removetracks", [.string(playlistID), .strings(trackIDs)])
    }
}

/// What a script returns, as values.
enum MusicPlaylistResults {
    private static func strings(of descriptor: NSAppleEventDescriptor) -> [String] {
        guard descriptor.descriptorType == typeAEList, descriptor.numberOfItems > 0 else { return [] }
        return (1 ... descriptor.numberOfItems).compactMap { descriptor.atIndex($0)?.stringValue }
    }

    static func created(from descriptor: NSAppleEventDescriptor) throws -> Value {
        guard descriptor.numberOfItems >= 2,
            let id = descriptor.atIndex(1)?.stringValue,
            let name = descriptor.atIndex(2)?.stringValue
        else { throw MusicPlaylistWriteError.scriptFailed("Music returned an unexpected answer") }
        return ["id": .string(id), "name": .string(name), "trackCount": 0]
    }

    /// The answer of `addtracks` and `removetracks`: the playlist's name,
    /// its track counts before and after, the IDs that were changed, and the IDs that weren't found.
    static func changed(
        from descriptor: NSAppleEventDescriptor,
        playlistID: String,
        changedKey: String
    ) throws -> Value {
        guard descriptor.numberOfItems >= 5,
            let name = descriptor.atIndex(1)?.stringValue,
            let descriptorBefore = descriptor.atIndex(2),
            let descriptorAfter = descriptor.atIndex(3),
            let changed = descriptor.atIndex(4),
            let missing = descriptor.atIndex(5)
        else { throw MusicPlaylistWriteError.scriptFailed("Music returned an unexpected answer") }
        return [
            "id": .string(playlistID),
            "name": .string(name),
            "trackCountBefore": .int(Int(descriptorBefore.int32Value)),
            "trackCountAfter": .int(Int(descriptorAfter.int32Value)),
            changedKey: .array(strings(of: changed).map(Value.string)),
            "notFound": .array(strings(of: missing).map(Value.string)),
        ]
    }
}
