import CryptoKit
import Foundation

// Finding, reading, editing, moving, and removing notes and folders through the Notes app's
// scripting interface.
//
// This file holds the logic that needs no Notes app, so that tests can cover it:
// checking a request, the guard that refuses a stale write, reading the script's answers,
// and the fixed script. `NotesOrganizeTools.swift` connects it to the Notes service.

/// A note as the Notes app reports it, through scripting.
struct NotesScriptNote: Equatable, Sendable {
    /// The number of strings that the `getNote` handler returns for one note.
    static let fieldCount = 11

    let id: String
    let title: String
    let folderID: String
    let folder: String
    let account: String
    let created: Date?
    let modified: Date?
    let plainText: String
    let bodyHTML: String
    let isPasswordProtected: Bool
    let isShared: Bool
    let attachmentCount: Int

    /// The answer of `getNote`, which lists these fields in order and ends with the account name.
    init(fields: [String]) throws {
        guard fields.count == Self.fieldCount + 1 else {
            throw NotesWriteError.scriptFailed("Notes returned an unexpected answer")
        }
        id = fields[0]
        title = fields[1]
        folderID = fields[2]
        folder = fields[3]
        created = NotesDates.date(fromLocalISO: fields[4])
        modified = NotesDates.date(fromLocalISO: fields[5])
        plainText = fields[6]
        bodyHTML = fields[7]
        isPasswordProtected = fields[8] == "true"
        isShared = fields[9] == "true"
        attachmentCount = Int(fields[10]) ?? 0
        account = fields[11]
    }

    /// A short code of the note's text, which a later write passes back to show that the text is unchanged.
    var contentHash: String { NotesContentHash.hash(of: plainText) }
}

/// A line of a list of notes: the note, where it is, and when it changed.
struct NotesScriptSummary: Equatable, Sendable {
    static let fieldCount = 5

    let id: String
    let title: String
    let folder: String
    let folderID: String
    let modified: Date?

    /// Reads a flat list of strings, `fieldCount` for each note.
    static func list(from fields: [String]) throws -> [NotesScriptSummary] {
        guard fields.count.isMultiple(of: fieldCount) else {
            throw NotesWriteError.scriptFailed("Notes returned an unexpected answer")
        }
        return stride(from: 0, to: fields.count, by: fieldCount).map { start in
            NotesScriptSummary(
                id: fields[start],
                title: fields[start + 1],
                folder: fields[start + 2],
                folderID: fields[start + 3],
                modified: NotesDates.date(fromLocalISO: fields[start + 4])
            )
        }
    }

    /// The most recently changed first, at most `limit`, leaving out the notes that were deleted.
    static func recent(_ notes: [NotesScriptSummary], limit: Int) -> [NotesScriptSummary] {
        let kept = notes.filter { !NotesFolderNames.isRecentlyDeleted($0.folder) }
        let sorted = kept.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        return Array(sorted.prefix(max(0, limit)))
    }
}

/// A folder of the tree of folders.
struct NotesScriptFolder: Equatable, Sendable {
    static let fieldCount = 5

    let id: String
    let name: String
    /// The id of the folder that holds this one, or empty at the top level of the account.
    let parentID: String
    let account: String
    let noteCount: Int

    static func list(from fields: [String]) throws -> [NotesScriptFolder] {
        guard fields.count.isMultiple(of: fieldCount) else {
            throw NotesWriteError.scriptFailed("Notes returned an unexpected answer")
        }
        return stride(from: 0, to: fields.count, by: fieldCount).map { start in
            NotesScriptFolder(
                id: fields[start],
                name: fields[start + 1],
                parentID: fields[start + 2],
                account: fields[start + 3],
                noteCount: Int(fields[start + 4]) ?? 0
            )
        }
    }

    /// The folders as a tree, in the order that they were listed.
    static func tree(_ folders: [NotesScriptFolder]) -> [Node] {
        let ids = Set(folders.map(\.id))
        func children(of parent: String) -> [Node] {
            folders.filter { $0.parentID == parent }.map {
                Node(folder: $0, children: children(of: $0.id))
            }
        }
        // A folder whose parent isn't listed is shown at the top, so that none is lost.
        let top = folders.filter { $0.parentID.isEmpty || !ids.contains($0.parentID) }
        return top.map { Node(folder: $0, children: children(of: $0.id)) }
    }

    struct Node: Equatable, Sendable {
        let folder: NotesScriptFolder
        let children: [Node]
    }
}

/// An attachment of a note.
struct NotesScriptAttachment: Equatable, Sendable {
    static let fieldCount = 5

    let id: String
    let name: String
    let contentID: String
    let url: String
    let created: Date?

    static func list(from fields: [String]) throws -> [NotesScriptAttachment] {
        guard fields.count.isMultiple(of: fieldCount) else {
            throw NotesWriteError.scriptFailed("Notes returned an unexpected answer")
        }
        return stride(from: 0, to: fields.count, by: fieldCount).map { start in
            NotesScriptAttachment(
                id: fields[start],
                name: fields[start + 1],
                contentID: fields[start + 2],
                url: fields[start + 3],
                created: NotesDates.date(fromLocalISO: fields[start + 4])
            )
        }
    }
}

/// The names that the Notes app gives its own folders.
enum NotesFolderNames {
    /// Notes shows deleted notes in a folder with this name, in English.
    /// The scripting interface has no flag for it, so another language's name isn't recognized.
    static func isRecentlyDeleted(_ name: String) -> Bool {
        name == "Recently Deleted"
    }
}

/// The dates that scripting returns, as local ISO 8601 text without a time zone.
enum NotesDates {
    static func date(fromLocalISO text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: text)
    }

    static func iso(_ date: Date?) -> String? {
        date.map { $0.formatted(.iso8601) }
    }
}

/// A code of a note's text.
///
/// A write that replaces a note's text takes the code of the text that the caller read.
/// It is refused when the note has changed since, so that an edit never overwrites a newer one.
enum NotesContentHash {
    static func hash(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Throws unless `expected` is the code of `note`'s current text.
    static func requireCurrent(_ note: NotesScriptNote, expected: String) throws {
        let expected = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !expected.isEmpty else {
            throw NotesWriteError.invalid(
                "expectedContentHash is required: read the note first and pass its contentHash"
            )
        }
        guard expected == note.contentHash else {
            throw NotesWriteError.stale
        }
    }
}

/// The arguments of the tools that organize and edit notes, once checked.
enum NotesOrganizeInput {
    static let maximumBatch = 50
    static let maximumListed = 200

    /// A note id as the scripting interface gives it, such as `x-coredata://…/ICNote/p12`.
    static func validatedNoteID(_ id: String) throws -> String {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasPrefix("x-coredata://"), id.count <= 500,
            !id.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else {
            throw NotesWriteError.invalid(
                "id must be a note id as the Notes app reports it, starting with x-coredata://"
            )
        }
        return id
    }

    static func validatedNoteIDs(_ ids: [String]) throws -> [String] {
        guard !ids.isEmpty else { throw NotesWriteError.invalid("ids can't be empty") }
        guard ids.count <= maximumBatch else {
            throw NotesWriteError.invalid("ids can have at most \(maximumBatch) notes")
        }
        return try ids.map(validatedNoteID)
    }

    /// A folder that must exist: its path can't be empty.
    static func requiredFolderPath(_ text: String) throws -> NotesFolderPath {
        try NotesFolderPath.parse(text)
    }

    static func validatedLimit(_ limit: Int?, default defaultLimit: Int) throws -> Int {
        guard let limit else { return defaultLimit }
        guard (1 ... maximumListed).contains(limit) else {
            throw NotesWriteError.invalid("limit must be between 1 and \(maximumListed)")
        }
        return limit
    }

    /// A file that an attachment is read from or written to: an absolute path with no control characters.
    static func validatedPath(_ path: String, called label: String) throws -> String {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), path.count <= 1024,
            !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else {
            throw NotesWriteError.invalid("\(label) must be an absolute path")
        }
        return path
    }
}

/// The fixed script of the tools that organize and edit notes, and the calls that run its handlers.
///
/// As in `NotesScripts`, every value is a handler argument, never part of the script's text.
/// The script raises errors numbered 4001 and up, with messages that say what went wrong.
enum NotesOrganizeScripts {
    static let source = NotesScripts.source + "\n" + organizeSource

    static let organizeSource = """
        -- Local ISO 8601 text of a date, without a time zone.
        on isoDate(theDate)
        	return (theDate as «class isot» as string)
        end isoDate

        -- The note with the id, which is the id that Notes gives it.
        on findNote(noteID)
        	tell application "Notes"
        		try
        			set theNote to note id noteID
        			set ignored to id of theNote
        			return theNote
        		on error
        			error "There is no note with the id: " & noteID number 4004
        		end try
        	end tell
        end findNote

        -- The name of the account that holds a folder, found through the folders that contain it.
        on accountNameOf(theFolder)
        	tell application "Notes"
        		set walker to container of theFolder
        		repeat while (class of walker) is folder
        			set walker to container of walker
        		end repeat
        		return name of walker
        	end tell
        end accountNameOf

        -- The folders directly inside an account or a folder.
        on childFolders(parentRef)
        	set found to {}
        	tell application "Notes"
        		set parentID to id of parentRef
        		repeat with candidate in (folders of parentRef)
        			if (id of (container of candidate)) is parentID then set end of found to contents of candidate
        		end repeat
        	end tell
        	return found
        end childFolders

        -- A note's fields: id, title, folder id, folder name, created, modified, plain text, HTML,
        -- whether it is locked, whether it is shared, how many attachments it has, and its account's name.
        -- A locked note's text can't be read, so it has none.
        on getNote(noteID)
        	set theNote to my findNote(noteID)
        	tell application "Notes"
        		set isLocked to password protected of theNote
        		set thePlain to ""
        		set theBody to ""
        		if not isLocked then
        			set thePlain to plaintext of theNote
        			set theBody to body of theNote
        		end if
        		set theFolder to container of theNote
        		return {id of theNote, name of theNote, id of theFolder, name of theFolder, my isoDate(creation date of theNote), my isoDate(modification date of theNote), thePlain, theBody, isLocked as text, (shared of theNote) as text, (count of attachments of theNote) as text, my accountNameOf(theFolder)}
        	end tell
        end getNote

        -- Lists the notes of a folder, or of every folder of an account when the path is empty,
        -- as id, title, folder name, folder id, and modified date for each note.
        on listNotes(accountName, folderPath)
        	set theAccount to my resolveAccount(accountName)
        	set scopes to {}
        	if (count of folderPath) > 0 then
        		set scopes to {my resolveFolder(accountName, folderPath, false)}
        	else
        		tell application "Notes" to set scopes to folders of theAccount
        	end if
        	set results to {}
        	repeat with scope in scopes
        		tell application "Notes"
        			set folderName to name of scope
        			set folderID to id of scope
        			set noteIDs to id of every note of scope
        			set noteNames to name of every note of scope
        			set noteDates to modification date of every note of scope
        		end tell
        		repeat with position from 1 to (count of noteIDs)
        			set end of results to item position of noteIDs
        			set end of results to item position of noteNames
        			set end of results to folderName
        			set end of results to folderID
        			set end of results to my isoDate(item position of noteDates)
        		end repeat
        	end repeat
        	return results
        end listNotes

        -- The notes that are selected in the Notes window, as id, title, folder name, folder id, and modified date.
        on selectedNotes()
        	set results to {}
        	tell application "Notes"
        		repeat with theNote in (selection as list)
        			set theFolder to container of theNote
        			set end of results to id of theNote
        			set end of results to name of theNote
        			set end of results to name of theFolder
        			set end of results to id of theFolder
        			set end of results to my isoDate(modification date of theNote)
        		end repeat
        	end tell
        	return results
        end selectedNotes

        -- The default account and its default folder: account id, account name, folder id, folder name.
        on defaultLocation()
        	tell application "Notes"
        		set theAccount to default account
        		set theFolder to default folder of theAccount
        		return {id of theAccount, name of theAccount, id of theFolder, name of theFolder}
        	end tell
        end defaultLocation

        -- Every folder of an account, with the folders inside them, as id, name, parent id, account name, and note count.
        on listFolders(accountName)
        	set theAccount to my resolveAccount(accountName)
        	set results to {}
        	tell application "Notes" to set accountLabel to name of theAccount
        	return my collectFolders(theAccount, "", accountLabel, results, 0)
        end listFolders

        on collectFolders(parentRef, parentID, accountLabel, results, depth)
        	if depth > 10 then return results
        	repeat with theFolder in my childFolders(parentRef)
        		tell application "Notes"
        			set folderID to id of theFolder
        			set end of results to folderID
        			set end of results to name of theFolder
        			set end of results to parentID
        			set end of results to accountLabel
        			set end of results to (count of notes of theFolder) as text
        		end tell
        		set results to my collectFolders(contents of theFolder, folderID, accountLabel, results, depth + 1)
        	end repeat
        	return results
        end collectFolders

        -- Replaces a note's HTML, but only while its plain text is still expectedPlain.
        -- A locked note, or one with attachments, is refused, because the HTML would drop them.
        on updateNote(noteID, expectedPlain, newBody)
        	set theNote to my findNote(noteID)
        	tell application "Notes"
        		if password protected of theNote then error "The note is locked with a password" number 4005
        		if (count of attachments of theNote) > 0 then error "The note has attachments, which replacing its text would drop" number 4006
        		considering case
        			set isCurrent to ((plaintext of theNote) is expectedPlain)
        		end considering
        		if not isCurrent then error "The note changed after it was read" number 4007
        		set body of theNote to newBody
        		return {id of theNote, name of theNote, my isoDate(modification date of theNote)}
        	end tell
        end updateNote

        -- Adds HTML to the end of a note's HTML, with the same refusals and guard as updateNote.
        on appendToNote(noteID, expectedPlain, checkExpected, addition)
        	set theNote to my findNote(noteID)
        	tell application "Notes"
        		if password protected of theNote then error "The note is locked with a password" number 4005
        		if (count of attachments of theNote) > 0 then error "The note has attachments, which rewriting its text would drop" number 4006
        		if checkExpected then
        			considering case
        				set isCurrent to ((plaintext of theNote) is expectedPlain)
        			end considering
        			if not isCurrent then error "The note changed after it was read" number 4007
        		end if
        		set body of theNote to (body of theNote) & addition
        		return {id of theNote, name of theNote, my isoDate(modification date of theNote)}
        	end tell
        end appendToNote

        -- Moves a note to Recently Deleted, from which Notes can restore it. Nothing is erased.
        on deleteNote(noteID)
        	set theNote to my findNote(noteID)
        	tell application "Notes"
        		set theName to name of theNote
        		delete theNote
        		return {noteID, theName}
        	end tell
        end deleteNote

        -- Moves a note into a folder that exists, and returns its id, which a move to another account changes.
        on moveNote(noteID, accountName, folderPath)
        	set theNote to my findNote(noteID)
        	if (count of folderPath) is 0 then error "A folder path is required" number 4008
        	set targetFolder to my resolveFolder(accountName, folderPath, false)
        	tell application "Notes"
        		set moved to move theNote to targetFolder
        		return {id of moved, name of moved, name of targetFolder}
        	end tell
        end moveNote

        -- Renames a folder, refusing a name that a sibling has.
        on renameFolder(accountName, folderPath, newName)
        	if (count of folderPath) is 0 then error "A folder path is required" number 4008
        	set theFolder to my resolveFolder(accountName, folderPath, false)
        	tell application "Notes" to set parentRef to container of theFolder
        	set existing to my findChild(parentRef, newName)
        	if existing is not missing value then error "There is already a folder named: " & newName number 4003
        	tell application "Notes"
        		set name of theFolder to newName
        		return {id of theFolder, name of theFolder}
        	end tell
        end renameFolder

        -- Deletes a folder. A folder that holds notes or folders is refused unless deleteContents is true,
        -- and then its notes go to Recently Deleted with it. The account's default folder is never deleted.
        on deleteFolder(accountName, folderPath, deleteContents)
        	if (count of folderPath) is 0 then error "A folder path is required" number 4008
        	set theAccount to my resolveAccount(accountName)
        	set theFolder to my resolveFolder(accountName, folderPath, false)
        	tell application "Notes"
        		if (id of theFolder) is (id of (default folder of theAccount)) then error "The default folder can't be deleted" number 4009
        		set noteTotal to count of notes of theFolder
        	end tell
        	set subfolderTotal to count of my childFolders(theFolder)
        	if (noteTotal > 0 or subfolderTotal > 0) and not deleteContents then
        		error "The folder holds " & noteTotal & " notes and " & subfolderTotal & " folders; pass deleteContents to delete it with them" number 4010
        	end if
        	tell application "Notes"
        		set theName to name of theFolder
        		set theID to id of theFolder
        		delete theFolder
        		return {theID, theName, noteTotal as text, subfolderTotal as text}
        	end tell
        end deleteFolder

        -- Shows a note in the Notes window.
        on showNote(noteID)
        	set theNote to my findNote(noteID)
        	tell application "Notes"
        		activate
        		show theNote
        		return {id of theNote, name of theNote}
        	end tell
        end showNote

        -- Shows a folder in the Notes window.
        on showFolder(accountName, folderPath)
        	if (count of folderPath) is 0 then error "A folder path is required" number 4008
        	set theFolder to my resolveFolder(accountName, folderPath, false)
        	tell application "Notes"
        		activate
        		show theFolder
        		return {id of theFolder, name of theFolder}
        	end tell
        end showFolder

        -- A note's attachments, as id, name, content identifier, URL, and created date for each.
        on listAttachments(noteID)
        	set theNote to my findNote(noteID)
        	set results to {}
        	tell application "Notes"
        		repeat with theAttachment in (attachments of theNote)
        			set theURL to ""
        			try
        				set theURL to (URL of theAttachment) as text
        			end try
        			set theCID to ""
        			try
        				set theCID to (content identifier of theAttachment) as text
        			end try
        			set theCreated to ""
        			try
        				set theCreated to my isoDate(creation date of theAttachment)
        			end try
        			set end of results to id of theAttachment
        			set end of results to name of theAttachment
        			set end of results to theCID
        			set end of results to theURL
        			set end of results to theCreated
        		end repeat
        	end tell
        	return results
        end listAttachments

        -- Adds the file at filePath to the end of a note. Notes itself reads the file.
        on addAttachment(noteID, filePath)
        	set theNote to my findNote(noteID)
        	set theFile to POSIX file filePath
        	tell application "Notes"
        		set newAttachment to make new attachment at end of attachments of theNote with data theFile
        		return {id of newAttachment, name of newAttachment, id of theNote}
        	end tell
        end addAttachment

        -- Saves an attachment of a note to filePath. Notes itself writes the file.
        on saveAttachment(noteID, attachmentID, filePath)
        	set theNote to my findNote(noteID)
        	set theFile to POSIX file filePath
        	tell application "Notes"
        		set found to missing value
        		repeat with theAttachment in (attachments of theNote)
        			if (id of theAttachment) is attachmentID then set found to contents of theAttachment
        		end repeat
        		if found is missing value then error "The note has no attachment with the id: " & attachmentID number 4004
        		save found in theFile
        		return {attachmentID, name of found}
        	end tell
        end saveAttachment
        """

    private static func call(_ name: String, _ parameters: [NSAppleScript.Subroutine.Parameter])
        -> NSAppleScript.Subroutine
    {
        NSAppleScript.Subroutine(name, parameters)
    }

    static func getNote(_ id: String) -> NSAppleScript.Subroutine { call("getNote", [.string(id)]) }

    static func listNotes(account: String?, folder: NotesFolderPath) -> NSAppleScript.Subroutine {
        call("listNotes", [.string(account ?? ""), .strings(folder.components)])
    }

    static let selectedNotes = call("selectedNotes", [])
    static let defaultLocation = call("defaultLocation", [])

    static func listFolders(account: String?) -> NSAppleScript.Subroutine {
        call("listFolders", [.string(account ?? "")])
    }

    static func updateNote(id: String, expectedPlainText: String, bodyHTML: String) -> NSAppleScript.Subroutine {
        call("updateNote", [.string(id), .string(expectedPlainText), .string(bodyHTML)])
    }

    static func appendToNote(id: String, expectedPlainText: String?, additionHTML: String) -> NSAppleScript.Subroutine {
        call(
            "appendToNote",
            [.string(id), .string(expectedPlainText ?? ""), .boolean(expectedPlainText != nil), .string(additionHTML)]
        )
    }

    static func deleteNote(_ id: String) -> NSAppleScript.Subroutine { call("deleteNote", [.string(id)]) }

    static func moveNote(id: String, account: String?, folder: NotesFolderPath) -> NSAppleScript.Subroutine {
        call("moveNote", [.string(id), .string(account ?? ""), .strings(folder.components)])
    }

    static func renameFolder(account: String?, folder: NotesFolderPath, newName: String) -> NSAppleScript.Subroutine {
        call("renameFolder", [.string(account ?? ""), .strings(folder.components), .string(newName)])
    }

    static func deleteFolder(account: String?, folder: NotesFolderPath, deleteContents: Bool)
        -> NSAppleScript.Subroutine
    {
        call("deleteFolder", [.string(account ?? ""), .strings(folder.components), .boolean(deleteContents)])
    }

    static func showNote(_ id: String) -> NSAppleScript.Subroutine { call("showNote", [.string(id)]) }

    static func showFolder(account: String?, folder: NotesFolderPath) -> NSAppleScript.Subroutine {
        call("showFolder", [.string(account ?? ""), .strings(folder.components)])
    }

    static func listAttachments(_ id: String) -> NSAppleScript.Subroutine { call("listAttachments", [.string(id)]) }

    static func addAttachment(id: String, path: String) -> NSAppleScript.Subroutine {
        call("addAttachment", [.string(id), .string(path)])
    }

    static func saveAttachment(id: String, attachmentID: String, path: String) -> NSAppleScript.Subroutine {
        call("saveAttachment", [.string(id), .string(attachmentID), .string(path)])
    }
}
