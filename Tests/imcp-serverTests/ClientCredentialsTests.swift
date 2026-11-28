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
        let malformed: [String] = [
            "",
            "imcp_",
            "imcp_short",
            "IMCP_" + String(valid.dropFirst(5)),
            String(valid.dropLast()),
            valid + "A",
            String(valid.dropLast()) + "!",
            String(valid.dropLast()) + "=",
        ]
        for credential in malformed {
            XCTAssertNil(ClientCredential.identifier(for: credential), credential)
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

    // MARK: - Names

    func testReportedNamesAreSanitizedForDisplay() {
        XCTAssertEqual(ClientName.sanitized("Claude Desktop"), "Claude Desktop")
        XCTAssertEqual(ClientName.sanitized(" Claude\n\nDesktop\t"), "Claude Desktop")
        XCTAssertEqual(ClientName.sanitized("Claude\u{202E}potkseD"), "Claude potkseD")
        XCTAssertEqual(ClientName.sanitized("Zero\u{200B}Width"), "Zero Width")
        XCTAssertEqual(ClientName.sanitized("\u{0007}\n "), ClientName.unnamed)

        let long = ClientName.sanitized(String(repeating: "a", count: 500))
        XCTAssertEqual(long.count, ClientName.maximumLength)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testEvaluateShowsSanitizedName() {
        let store = makeStore()
        guard case .ask(let request) = store.evaluate(credential: nil, claimedName: "Evil\nThis client uses") else {
            return XCTFail("A connection without a credential must ask")
        }
        XCTAssertEqual(request.claimedName, "Evil This client uses")
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

        let credential = try XCTUnwrap(try store.alwaysTrust(request).credential)
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

        XCTAssertNil(try store.alwaysTrust(request).credential)
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

    func testCooldownKeyFollowsCredentialAndIgnoresName() throws {
        let store = makeStore()
        let credential = try store.credentialForSettings(name: "Client", existing: nil)

        guard case .ask(let withCredential) = store.evaluate(credential: credential, claimedName: "Client"),
            case .ask(let renamed) = store.evaluate(credential: credential, claimedName: "Other Name"),
            case .ask(let withoutCredential) = store.evaluate(credential: nil, claimedName: "Client"),
            case .ask(let withUnknownCredential) = store.evaluate(
                credential: ClientCredential.generate(),
                claimedName: "Client"
            )
        else { return XCTFail("Every connection must ask") }

        XCTAssertNotNil(withCredential.cooldownKey)
        XCTAssertEqual(withCredential.cooldownKey, renamed.cooldownKey)
        // A name or an unrecognized credential can be changed freely, so it keys no cooldown.
        XCTAssertNil(withoutCredential.cooldownKey)
        XCTAssertNil(withUnknownCredential.cooldownKey)
    }

    func testIdentityNoteSaysWhenClientPresentsNoCredential() throws {
        defaults.set(try JSONEncoder().encode(Set(["Claude"])), forKey: "trustedClients")
        let store = makeStore()

        guard case .ask(let unnamed) = store.evaluate(credential: nil, claimedName: "Client"),
            case .ask(let formerlyTrusted) = store.evaluate(credential: nil, claimedName: "Claude"),
            case .ask(let unknown) = store.evaluate(credential: ClientCredential.generate(), claimedName: "Client")
        else { return XCTFail("Every connection must ask") }

        XCTAssertTrue(unnamed.identityNote.hasPrefix("This client presented no credential"))
        XCTAssertTrue(formerlyTrusted.identityNote.hasPrefix("This client presented no credential"))
        XCTAssertTrue(formerlyTrusted.identityNote.contains("You trusted a client with this name before"))
        XCTAssertFalse(unknown.identityNote.contains("no credential"))
    }

    // MARK: - Trust by signature

    nonisolated private static let claudeCode = ClientSignature(
        identifier: "com.anthropic.claude-code",
        team: "Q6L2SF6YDW",
        publisher: "Anthropic PBC"
    )

    private static func verified(
        _ signature: ClientSignature = claudeCode,
        isApplication: Bool = false
    ) -> ClientVerification {
        .verified(VerifiedClient(signature: signature, launcherIdentifier: nil, isApplication: isApplication))
    }

    func testAlwaysTrustStoresVerifiedSignatureWithoutCredential() throws {
        let store = makeStore()
        guard
            case .ask(let request) = store.evaluate(
                credential: nil,
                verification: Self.verified(),
                claimedName: "claude"
            )
        else { return XCTFail("An untrusted signature must ask") }

        let trust = try store.alwaysTrust(request)
        XCTAssertNil(trust.credential)
        XCTAssertEqual(trust.record.signature, Self.claudeCode)
        XCTAssertEqual(trust.record.name, "claude")
        XCTAssertEqual(trust.record.id, "signature:Q6L2SF6YDW:com.anthropic.claude-code")
        XCTAssertEqual(Array(storage.records.values), [trust.record])

        XCTAssertEqual(
            store.evaluate(credential: nil, verification: Self.verified(), claimedName: "Other"),
            .approve(trust.record)
        )
        XCTAssertEqual(store.trustedRecords, [trust.record])
        XCTAssertEqual(
            makeStore().evaluate(credential: nil, verification: Self.verified(), claimedName: "Other"),
            .approve(trust.record)
        )
    }

    func testTrustedSignatureApprovesAfterUpdate() throws {
        let store = makeStore()
        let record = try store.trust(Self.claudeCode, name: "claude")

        // An update can change the publisher's name; the identifier and the team stay.
        var updated = Self.claudeCode
        updated.publisher = "Anthropic, PBC"
        XCTAssertEqual(
            store.evaluate(credential: nil, verification: Self.verified(updated), claimedName: "x"),
            .approve(record)
        )
    }

    func testSignatureApprovesOnlyItsIdentifierAndTeam() throws {
        let store = makeStore()
        _ = try store.trust(Self.claudeCode, name: "claude")

        var otherTeam = Self.claudeCode
        otherTeam.team = "ABCDE12345"
        var otherIdentifier = Self.claudeCode
        otherIdentifier.identifier = "com.anthropic.claudefordesktop"
        for verification in [
            Self.verified(otherTeam), Self.verified(otherIdentifier), .failed(.notHardened), .unidentified,
        ] {
            guard case .ask = store.evaluate(credential: nil, verification: verification, claimedName: "claude") else {
                return XCTFail("\(verification) must ask")
            }
        }
    }

    func testUnverifiedClientKeepsCredentialFlow() throws {
        let store = makeStore()
        guard
            case .ask(let request) = store.evaluate(
                credential: nil,
                verification: .failed(.electronFuses),
                claimedName: "Code"
            )
        else { return XCTFail("A client that fails the checks must ask") }

        XCTAssertEqual(request.signatureNote, ClientSignatureFailure.electronFuses.message)
        XCTAssertNil(request.verifiedClient)
        XCTAssertNotNil(try store.alwaysTrust(request).credential)
    }

    func testTrustedCredentialAndTrustedSignatureTogether() throws {
        let store = makeStore()
        let (credential, credentialRecord) = try store.issue(name: "Claude Desktop", trusted: true)
        let signatureRecord = try store.trust(Self.claudeCode, name: "claude")

        // The credential decides first.
        XCTAssertEqual(
            store.evaluate(credential: credential, verification: Self.verified(), claimedName: "claude"),
            .approve(credentialRecord)
        )
        // An unknown credential doesn't stop a trusted signature.
        XCTAssertEqual(
            store.evaluate(
                credential: ClientCredential.generate(),
                verification: Self.verified(),
                claimedName: "claude"
            ),
            .approve(signatureRecord)
        )
        XCTAssertEqual(Set(store.trustedRecords.map(\.id)), [credentialRecord.id, signatureRecord.id])

        try store.revoke(id: credentialRecord.id)
        XCTAssertEqual(
            store.evaluate(credential: credential, verification: Self.verified(), claimedName: "claude"),
            .approve(signatureRecord)
        )
        try store.revoke(id: signatureRecord.id)
        guard case .ask = store.evaluate(credential: credential, verification: Self.verified(), claimedName: "claude")
        else { return XCTFail("Both records are removed") }
    }

    func testVerifiedSignatureWithUntrustedSettingsCredentialTrustsSignature() throws {
        let store = makeStore()
        let credential = try store.credentialForSettings(name: "Claude Desktop", existing: nil)
        guard
            case .ask(let request) = store.evaluate(
                credential: credential,
                verification: Self.verified(),
                claimedName: "Claude"
            )
        else { return XCTFail("An untrusted credential must ask") }

        let trust = try store.alwaysTrust(request)
        XCTAssertNil(trust.credential)
        XCTAssertNotNil(trust.record.signature)
        XCTAssertFalse(store.record(for: credential)?.isTrusted ?? true)
    }

    func testRemovingSignatureEndsItsSessions() throws {
        let store = makeStore()
        let record = try store.trust(Self.claudeCode, name: "claude")
        var sessions = CredentialSessions()
        let connection = UUID()
        sessions.add(connection, credentialID: record.id)

        try store.revoke(id: record.id)
        XCTAssertEqual(sessions.revoke(credentialID: record.id), [connection])
        XCTAssertTrue(storage.records.isEmpty)
    }

    func testSignatureKeysCoalescingAndCooldown() {
        let store = makeStore()
        guard case .ask(let first) = store.evaluate(credential: nil, verification: Self.verified(), claimedName: "a"),
            case .ask(let renamed) = store.evaluate(credential: nil, verification: Self.verified(), claimedName: "b"),
            case .ask(let failed) = store.evaluate(
                credential: nil,
                verification: .failed(.notHardened),
                claimedName: "a"
            )
        else { return XCTFail("Every connection must ask") }

        XCTAssertEqual(first.approvalKey(connectionID: UUID()), renamed.approvalKey(connectionID: UUID()))
        XCTAssertEqual(first.cooldownKey, "signature:Q6L2SF6YDW:com.anthropic.claude-code")
        XCTAssertEqual(first.cooldownKey, renamed.cooldownKey)
        XCTAssertNil(failed.cooldownKey)
    }

    func testDialogNotesForVerifiedClients() {
        let store = makeStore()
        guard
            case .ask(let tool) = store.evaluate(credential: nil, verification: Self.verified(), claimedName: "claude"),
            case .ask(let app) = store.evaluate(
                credential: nil,
                verification: Self.verified(isApplication: true),
                claimedName: "Claude"
            )
        else { return XCTFail("Every connection must ask") }

        XCTAssertTrue(tool.identityNote.hasPrefix("Signed by Anthropic PBC (Q6L2SF6YDW) as com.anthropic.claude-code."))
        XCTAssertTrue(tool.identityNote.hasSuffix(#"It reports the name "claude"."#))
        XCTAssertNil(tool.signatureNote)
        XCTAssertNotNil(tool.sharedAccessNote)
        XCTAssertNil(app.sharedAccessNote)
    }

    func testRecordsFromEarlierVersionsDecodeWithoutSignature() throws {
        let data = Data(#"{"id":"abc","isTrusted":true,"issuedAt":0,"name":"Client"}"#.utf8)
        let record = try JSONDecoder().decode(ClientRecord.self, from: data)
        XCTAssertNil(record.signature)
        XCTAssertEqual(record.name, "Client")
    }

    // MARK: - Sessions

    func testRevokingCredentialReturnsItsConnections() {
        var sessions = CredentialSessions()
        let first = UUID()
        let second = UUID()
        let other = UUID()
        sessions.add(first, credentialID: "a")
        sessions.add(second, credentialID: "a")
        sessions.add(other, credentialID: "b")

        XCTAssertEqual(sessions.revoke(credentialID: "a"), [first, second])
        XCTAssertEqual(sessions.revoke(credentialID: "a"), [])
        XCTAssertEqual(sessions.connections, ["b": [other]])
    }

    func testClosedConnectionsAreForgotten() {
        var sessions = CredentialSessions()
        let closed = UUID()
        let open = UUID()
        sessions.add(closed, credentialID: "a")
        sessions.add(open, credentialID: "b")

        sessions.remove(closed)

        XCTAssertEqual(sessions.connections, ["b": [open]])
        XCTAssertEqual(sessions.revoke(credentialID: "a"), [])
    }

    func testRevokingAllReturnsEveryConnection() {
        var sessions = CredentialSessions()
        let first = UUID()
        let second = UUID()
        sessions.add(first, credentialID: "a")
        sessions.add(second, credentialID: "b")

        XCTAssertEqual(sessions.revokeAll(), [first, second])
        XCTAssertTrue(sessions.connections.isEmpty)
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

        let credential = try XCTUnwrap(try store.alwaysTrust(request).credential)
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
