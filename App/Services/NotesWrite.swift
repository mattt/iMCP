import Foundation

/// The Notes service's tools that change the Notes app.
///
/// Reading and changing use different routes:
/// notes are read from the database with TopoText, which never writes to it,
/// and a new note or folder is made through the Notes app's own scripting interface,
/// so Notes stores it as it stores anything else that it makes.
/// Creating is all that iMCP does there.
/// Editing an existing note through scripting is known to drop attachments, checklists, links, and tags
/// without an error, so iMCP doesn't offer it.
///
/// The tools change things, so they are offered only while "Allow writes" is on for Notes
/// (see `ServiceWrites`), which starts off.
extension NotesService {
    var tools: [Tool] {
        readTools
            + NotesWriteTools.tools(
                runner: AppleNotesScriptRunner(),
                resolver: DatabaseIdentifierResolver(service: self)
            )
    }

    var writesEnabledByDefault: Bool { false }
}

/// Looks in the Notes database through the Notes service.
struct DatabaseIdentifierResolver: NotesIdentifierResolving, @unchecked Sendable {
    let service: NotesService

    func noteID(
        title: String,
        folderPath: [String],
        folderName: String,
        accountName: String,
        createdAfter date: Date
    ) async -> String? {
        await service.lookUpCreatedNote(
            title: title,
            folderPath: folderPath,
            folderName: folderName,
            accountName: accountName,
            createdAfter: date
        )
    }

    func folderID(path: [String], accountName: String) async -> String? {
        await service.lookUpCreatedFolder(path: path, accountName: accountName)
    }
}
