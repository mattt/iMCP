import Foundation
import XCTest

/// Tests for client credentials and the trust decisions based on them.
///
/// These tests use in-memory storage and a throwaway defaults suite,
/// so they don't touch the Keychain or the app's preferences.
@MainActor
final class ClientCredentialsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storage: InMemoryClientRecordStorage!

    override func setUp() async throws {
        suiteName = "imcp-credential-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        storage = InMemoryClientRecordStorage()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> ClientCredentialStore {
        ClientCredentialStore(storage: storage, defaults: defaults, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    // MARK: - Format

    func testGeneratedCredentialsAreDistinctAndWellFormed() {
        let first = ClientCredential.generate()
        let second = ClientCredential.generate()
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasPrefix("imcp_"))
        XCTAssertEqual(first.count, "imcp_".count + 43)

        let identifier = ClientCredential.identifier(for: first)
        XCTAssertEqual(identifier?.count, 64)
        XCTAssertEqual(identifier, ClientCredential.identifier(for: first))
        XCTAssertNotEqual(identifier, ClientCredential.identifier(for: second))
    }

    func testIdentifierRejectsMalformedCredentials() {
        let valid = ClientCredential.generate()
        for credential in [
            "",
            "imcp_",
            "imcp_short",
            "IMCP_" + valid.dropFirst(5),
            String(valid.dropLast()),
            valid + "A",
            String(valid.dropLast()) + "!",
            String(valid.dropLast()) + "=",
        ] {
            XCTAssertNil(ClientCredential.identifier(for: String(credential)), String(credential))
        }
    }

    func testHelloReadsCredentialFromEnvironment() {
        XCTAssertNil(LocalSocketHello.fromEnvironment([:]).credential)
        XCTAssertNil(LocalSocketHello.fromEnvironment(["IMCP_CLIENT_CREDENTIAL": " \n"]).credential)
        XCTAssertEqual(
            LocalSocketHello.fromEnvironment(["IMCP_CLIENT_CREDENTIAL": " imcp_abc\n"]).credential,
            "imcp_abc"
        )
    }

    func testHelloWithCredentialRoundTrips() throws {
        let hello = LocalSocketHello(credential: ClientCredential.generate())
        let data = try hello.encoded()
        XCTAssertEqual(try LocalSocketHello.decode(data.dropLast()), hello)
        XCTAssertLessThanOrEqual(data.count - 1, LocalSocketHello.maximumLength)
    }

    // MARK: - Issuing and checking

    func testTrustedCredentialApprovesWithoutDialog() throws {
        let store = makeStore()
        let (credential, record) = try store.issue(name: "Claude Desktop", trusted: true)

        XCTAssertEqual(store.evaluate(credential: credential, claimedName: "Anything"), .approve(record))
        XCTAssertEqual(store.trustedRecords, [record])
    }

    func testStorageKeepsOnlyTheCredentialHash() throws {
        let store = makeStore()
        let (credential, record) = try store.issue(name: "Client", trusted: true)

        XCTAssertEqual(Array(storage.records.values), [record])
        let stored = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertFalse(stored.contains(String(credential.dropFirst(5))))
        XCTAssertEqual(record.id, ClientCredential.identifier(for: credential))
    }

    func testNameOfTrustedClientDoesNotApprove() throws {
        let store = makeStore()
        _ = try store.issue(name: "Claude Desktop", trusted: true)

        guard case .ask(let request) = store.evaluate(credential: nil, claimedName: "Claude Desktop") else {
            return XCTFail("A claimed name must not approve a connection")
        }
        XCTAssertNil(request.record)
        XCTAssertFalse(request.hasUnrecognizedCredential)
    }

    func testUnknownAndRevokedCredentialsAsk() throws {
        let store = makeStore()
        let (credential, record) = try store.issue(name: "Client", trusted: true)

        guard case .ask(let unknown) = store.evaluate(credential: ClientCredential.generate(), claimedName: "Client")
        else { return XCTFail("An unknown credential must ask") }
        XCTAssertTrue(unknown.hasUnrecognizedCredential)

        guard case .ask(let malformed) = store.evaluate(credential: "not a credential", claimedName: "Client")
        else { return XCTFail("A malformed credential must ask") }
        XCTAssertTrue(malformed.hasUnrecognizedCredential)

        try store.revoke(id: record.id)
        guard case .ask(let revoked) = store.evaluate(credential: credential, claimedName: "Client") else {
            return XCTFail("A revoked credential must ask")
        }
        XCTAssertTrue(revoked.hasUnrecognizedCredential)
        XCTAssertTrue(storage.records.isEmpty)
    }

    func testRecordsPersistAcrossStores() throws {
        let (credential, record) = try makeStore().issue(name: "Client", trusted: true)
        XCTAssertEqual(makeStore().evaluate(credential: credential, claimedName: "Client"), .approve(record))
    }

    func testFailedSaveIssuesNothing() {
        struct Failure: Error {}
        let store = makeStore()
        storage.error = Failure()

        XCTAssertThrowsError(try store.issue(name: "Client", trusted: true))
        XCTAssertTrue(store.records.isEmpty)
    }

    // MARK: - Always trust

    func testAlwaysTrustWithoutCredentialIssuesOne() throws {
        let store = makeStore()
        guard case .ask(let request) = store.evaluate(credential: nil, claimedName: "Cursor") else {
            return XCTFail("A connection without a credential must ask")
        }

        let credential = try XCTUnwrap(try store.alwaysTrust(request))
        guard case .approve(let record) = store.evaluate(credential: credential, claimedName: "Cursor") else {
            return XCTFail("The issued credential must approve")
        }
        XCTAssertEqual(record.name, "Cursor")

        // The approval applies to the credential, not to the name.
        guard case .ask = store.evaluate(credential: nil, claimedName: "Cursor") else {
            return XCTFail("Another connection with the same name must ask")
        }
    }

    func testSettingsCredentialIsTrustedOnlyAfterApproval() throws {
        let store = makeStore()
        let credential = try store.credentialForSettings(name: "Claude Desktop", existing: nil)

        guard case .ask(let request) = store.evaluate(credential: credential, claimedName: "Claude") else {
            return XCTFail("A credential from settings must ask until it's approved")
        }
        XCTAssertEqual(request.record?.name, "Claude Desktop")
        XCTAssertTrue(store.trustedRecords.isEmpty)

        XCTAssertNil(try store.alwaysTrust(request))
        guard case .approve(let record) = store.evaluate(credential: credential, claimedName: "Claude") else {
            return XCTFail("An approved credential must approve")
        }
        XCTAssertEqual(record.name, "Claude Desktop")
        XCTAssertEqual(store.records.count, 1)
    }

    func testSettingsKeepExistingCredential() throws {
        let store = makeStore()
        let credential = try store.credentialForSettings(name: "Claude Desktop", existing: nil)

        XCTAssertEqual(try store.credentialForSettings(name: "Claude Desktop", existing: credential), credential)
        XCTAssertNotEqual(
            try store.credentialForSettings(name: "Claude Desktop", existing: ClientCredential.generate()),
            credential
        )
    }

    func testApprovalKeyFollowsCredentialNotName() throws {
        let store = makeStore()
        let credential = try store.credentialForSettings(name: "Client", existing: nil)
        let first = UUID()
        let second = UUID()

        guard case .ask(let withCredential) = store.evaluate(credential: credential, claimedName: "Client"),
            case .ask(let withoutCredential) = store.evaluate(credential: nil, claimedName: "Client")
        else { return XCTFail("Both connections must ask") }

        XCTAssertEqual(
            withCredential.approvalKey(connectionID: first),
            withCredential.approvalKey(connectionID: second)
        )
        XCTAssertNotEqual(
            withoutCredential.approvalKey(connectionID: first),
            withoutCredential.approvalKey(connectionID: second)
        )
    }

    // MARK: - Trust by name from earlier versions

    func testNameTrustedByEarlierVersionMustReenroll() throws {
        defaults.set(try JSONEncoder().encode(Set(["Claude", "Cursor"])), forKey: "trustedClients")
        let store = makeStore()
        XCTAssertEqual(store.legacyTrustedNames, ["Claude", "Cursor"])

        guard case .ask(let request) = store.evaluate(credential: nil, claimedName: "Claude") else {
            return XCTFail("A name trusted by an earlier version must not approve")
        }
        XCTAssertTrue(request.wasTrustedByName)

        let credential = try XCTUnwrap(try store.alwaysTrust(request))
        XCTAssertEqual(store.legacyTrustedNames, ["Cursor"])
        guard case .approve = store.evaluate(credential: credential, claimedName: "Claude") else {
            return XCTFail("The re-enrolled client's credential must approve")
        }

        store.removeLegacyTrustedName("Cursor")
        XCTAssertEqual(store.legacyTrustedNames, [])
        XCTAssertNil(defaults.object(forKey: "trustedClients"))
    }

    func testRevokeAllRemovesCredentialsAndNames() throws {
        defaults.set(try JSONEncoder().encode(Set(["Claude"])), forKey: "trustedClients")
        let store = makeStore()
        let (credential, _) = try store.issue(name: "Client", trusted: true)

        try store.revokeAll()

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(storage.records.isEmpty)
        XCTAssertEqual(store.legacyTrustedNames, [])
        guard case .ask = store.evaluate(credential: credential, claimedName: "Client") else {
            return XCTFail("A revoked credential must ask")
        }
    }
}
