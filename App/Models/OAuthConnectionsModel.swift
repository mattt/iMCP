import Foundation

/// The apps that the owner approved through OAuth, for Settings.
///
/// The model keeps the list current and ends grants.
/// A view reads `grants` and `storageError`, and calls `revoke(_:)`,
/// so it doesn't need to know how iMCP stores or enforces grants.
@MainActor
final class OAuthConnectionsModel: ObservableObject {
    @Published private(set) var grants: [OAuthGrant] = []
    /// Why iMCP can't read its connected apps, or `nil` if it can.
    @Published private(set) var storageError: String?

    private let authority: OAuthAuthority
    /// Runs after a grant ends, to close the sessions that it opened.
    var didRevoke: (@MainActor (UUID) -> Void)?

    init(authority: OAuthAuthority = .shared) {
        self.authority = authority
        authority.setChangeHandler { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    func reload() {
        storageError = authority.storageError
        grants = authority.allGrants.sorted {
            $0.clientName.localizedStandardCompare($1.clientName) == .orderedAscending
        }
    }

    /// Ends the grant. Its tokens stop working at once, even if iMCP can't save the change.
    func revoke(_ id: UUID) throws {
        defer {
            reload()
            didRevoke?(id)
        }
        try authority.revoke(id: id)
    }
}
