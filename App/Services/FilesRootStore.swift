import Foundation
import OSLog

private let log = Logger.service("files")

/// The folders that the person shared with the Files service, kept as security-scoped bookmarks.
///
/// A bookmark is resolved each time that a tool runs, and its scope is open only while the tool works:
/// every `startAccessingSecurityScopedResource` is paired with a stop.
/// A bookmark that has gone stale is made again from the folder that it still resolves to.
/// One that no longer resolves stays in the list, marked as needing to be added again,
/// so the person sees which folder stopped working instead of it vanishing.
final class FilesRootStore: FilesRootProviding, @unchecked Sendable {
    static let shared = FilesRootStore()

    static let defaultsKey = "me.mattt.iMCP.filesRoots"

    /// One shared folder as stored.
    struct Grant: Codable, Identifiable, Equatable {
        var id: UUID
        var name: String
        var bookmark: Data
    }

    enum AddError: Error, LocalizedError {
        case notAFolder
        case wholeDisk
        case photosLibrary
        case alreadyShared(String)

        var errorDescription: String? {
            switch self {
            case .notAFolder: return "Choose a folder."
            case .wholeDisk: return "Choose a folder, not the whole disk."
            case .photosLibrary:
                return "iMCP never opens a Photos library, so it can't share one or a folder inside one."
            case .alreadyShared(let name): return "That folder is already shared as \"\(name)\"."
            }
        }
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Stored grants

    func grants() -> [Grant] {
        lock.withLock { loadGrants() }
    }

    private func loadGrants() -> [Grant] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode([Grant].self, from: data)
        } catch {
            log.error("The stored folders can't be read: \(error.localizedDescription)")
            return []
        }
    }

    private func save(_ grants: [Grant]) {
        do {
            defaults.set(try JSONEncoder().encode(grants), forKey: Self.defaultsKey)
        } catch {
            log.error("The folders can't be stored: \(error.localizedDescription)")
        }
    }

    // MARK: - Adding and removing

    /// Shares a folder that the person chose in an open panel.
    @discardableResult
    func add(_ url: URL) throws -> Grant {
        // The panel's URL carries the grant, which is open while this method works.
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
            let resolved = FilesAccess.realPath(url.path)
        else { throw AddError.notAFolder }
        let canonical = URL(fileURLWithPath: resolved)
        guard canonical.pathComponents.count > 1 else { throw AddError.wholeDisk }
        guard !FilesAccess.isInsidePhotosLibrary(canonical), !FilesAccess.isInsidePhotosLibrary(url) else {
            throw AddError.photosLibrary
        }

        return try lock.withLock {
            var grants = loadGrants()
            for grant in grants {
                if let existing = Self.resolve(grant).url.flatMap({ FilesAccess.realPath($0.path) }),
                    canonical.pathComponents.starts(with: URL(fileURLWithPath: existing).pathComponents)
                {
                    throw AddError.alreadyShared(grant.name)
                }
            }
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let grant = Grant(
                id: UUID(),
                name: Self.uniqueName(canonical.lastPathComponent, among: grants.map(\.name)),
                bookmark: bookmark
            )
            grants.append(grant)
            save(grants)
            return grant
        }
    }

    func remove(_ id: UUID) {
        lock.withLock { save(loadGrants().filter { $0.id != id }) }
    }

    static func uniqueName(_ base: String, among names: [String]) -> String {
        var name = base
        var suffix = 2
        while names.contains(name) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        return name
    }

    // MARK: - Resolving

    /// Resolves a stored bookmark, making it again if it is stale.
    /// The URL is nil if the bookmark no longer resolves.
    private static func resolve(_ grant: Grant) -> (url: URL?, renewed: Grant?) {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: grant.bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            log.error("The folder \"\(grant.name)\" no longer resolves: \(error.localizedDescription)")
            return (nil, nil)
        }
        guard isStale else { return (url, nil) }

        // A stale bookmark still resolves. Make it again while the folder is open.
        // If that fails, this resolution still works, so keep the old one and try next time.
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            var renewed = grant
            renewed.bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            log.debug("Renewed the stale bookmark for \"\(grant.name)\"")
            return (url, renewed)
        } catch {
            log.error("The stale bookmark for \"\(grant.name)\" can't be renewed: \(error.localizedDescription)")
            return (url, nil)
        }
    }

    /// Resolves every grant, and stores the bookmarks that were made again.
    private func resolveAll() -> [(grant: Grant, url: URL?)] {
        lock.withLock {
            var grants = loadGrants()
            var results: [(Grant, URL?)] = []
            var changed = false
            for index in grants.indices {
                let result = Self.resolve(grants[index])
                if let renewed = result.renewed {
                    grants[index] = renewed
                    changed = true
                }
                results.append((grants[index], result.url))
            }
            if changed { save(grants) }
            return results
        }
    }

    /// Resolves the folders at launch, so that stale bookmarks are renewed before a client asks.
    func refresh() {
        _ = resolveAll()
    }

    /// The folders with the state of each, which Settings shows.
    func summaries() -> [(id: UUID, status: FilesRootStatus)] {
        resolveAll().map { grant, url in
            guard let url else { return (grant.id, FilesRootStatus(name: grant.name, path: nil, state: .needsReAdd)) }
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            let usable = didStart && FilesAccess.realPath(url.path) != nil
            return (
                grant.id,
                FilesRootStatus(name: grant.name, path: url.path, state: usable ? .available : .needsReAdd)
            )
        }
    }

    // MARK: - FilesRootProviding

    func statuses() -> [FilesRootStatus] {
        summaries().map(\.status)
    }

    func withAccess<T>(_ body: (FilesAccess) throws -> T) throws -> T {
        var open: [URL] = []
        var roots: [FilesRoot] = []
        defer { for url in open { url.stopAccessingSecurityScopedResource() } }

        for (grant, url) in resolveAll() {
            guard let url, url.startAccessingSecurityScopedResource() else { continue }
            open.append(url)
            guard let path = FilesAccess.realPath(url.path) else { continue }
            let canonical = URL(fileURLWithPath: path)
            guard !FilesAccess.isInsidePhotosLibrary(canonical) else { continue }
            roots.append(FilesRoot(name: grant.name, url: canonical))
        }
        return try body(FilesAccess(roots: roots))
    }
}
