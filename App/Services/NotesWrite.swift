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
extension NotesService {
    var tools: [Tool] {
        readTools
            + NotesWriteTools.tools(
                isEnabled: { NotesWriteTools.isEnabledInSettings },
                runner: AppleNotesScriptRunner()
            )
    }

    /// The tools that create notes are new, so they start off until the person turns writes on.
    var writesEnabledByDefault: Bool { false }
}
