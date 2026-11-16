import Foundation

/// Reads, searches, and (when the person allows it) changes the folders that the person shared.
///
/// The folders, the limits, and the rules for paths are in `FilesAccess`, `FilesRootStore`, and `FilesTools`.
/// Its tools that change files follow the service's "Allow writes" setting, which starts off.
final class FilesService: Service {
    static let shared = FilesService()

    /// Sharing folders is new, so changing files stays off until the person turns it on.
    var writesEnabledByDefault: Bool { false }

    var tools: [Tool] {
        // An explicit return keeps the tool builder out of the way: this is already a list of tools.
        return FilesTools.tools(
            provider: FilesRootStore.shared,
            isEnabled: { FilesService.shared.areWritesEnabled() }
        )
    }

    func activate() async throws {
        FilesRootStore.shared.refresh()
    }
}
