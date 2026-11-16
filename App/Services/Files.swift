import Foundation

/// Reads, searches, and (when the person allows it) changes the folders that the person shared.
///
/// The folders, the limits, and the rules for paths are in `FilesAccess`, `FilesRootStore`, and `FilesTools`.
final class FilesService: Service {
    static let shared = FilesService()

    var tools: [Tool] {
        // An explicit return keeps the tool builder out of the way: this is already a list of tools.
        return FilesTools.tools(
            provider: FilesRootStore.shared,
            isEnabled: { FilesTools.isEnabledInSettings }
        )
    }

    /// The tools that change files are listed only while the person allows changes.
    /// Until then a client that calls one still gets the reason that it can't.
    func isToolListed(_ name: String) -> Bool {
        FilesTools.isListed(name, writesEnabled: FilesTools.isEnabledInSettings)
    }

    func activate() async throws {
        FilesRootStore.shared.refresh()
    }
}
