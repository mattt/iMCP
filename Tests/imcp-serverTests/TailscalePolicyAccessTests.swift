import XCTest

final class TailscalePolicyEditTests: XCTestCase {
    private let target = "100.64.0.7"

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func updated(_ policy: String) throws -> Data {
        guard case .updated(let data) = try TailscalePolicyEdit.apply(to: Data(policy.utf8), target: target) else {
            throw XCTSkip("expected an update")
        }
        return data
    }

    func testAddsNodeAttrsWhenMissingAndKeepsEverythingElse() throws {
        let policy = #"{"acls":[{"action":"accept","src":["*"],"dst":["*:*"]}],"tagOwners":{"tag:a":["a@b.c"]}}"#
        let result = try object(try updated(policy))
        XCTAssertEqual((result["acls"] as? [[String: Any]])?.count, 1)
        XCTAssertNotNil(result["tagOwners"])
        let entries = try XCTUnwrap(result["nodeAttrs"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["target"] as? [String], [target])
        XCTAssertEqual(entries[0]["attr"] as? [String], ["funnel"])
    }

    func testAppendsToExistingNodeAttrs() throws {
        let policy = #"{"nodeAttrs":[{"target":["*"],"attr":["nextdns:abc"]}]}"#
        let entries = try XCTUnwrap(try object(try updated(policy))["nodeAttrs"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0]["attr"] as? [String], ["nextdns:abc"])
    }

    func testIsIdempotent() throws {
        let first = try updated("{}")
        XCTAssertEqual(try TailscalePolicyEdit.apply(to: first, target: target), .alreadyAllowed)
        let entries = try XCTUnwrap(try object(first)["nodeAttrs"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
    }

    func testBroaderRulesCountAsAllowed() throws {
        for who in ["*", "autogroup:member", target] {
            let policy = #"{"nodeAttrs":[{"target":["\#(who)"],"attr":["funnel"]}]}"#
            XCTAssertEqual(try TailscalePolicyEdit.apply(to: Data(policy.utf8), target: target), .alreadyAllowed)
        }
        // Another attribute, or another address, does not count.
        let other = #"{"nodeAttrs":[{"target":["100.64.0.9"],"attr":["funnel"]},{"target":["*"],"attr":["x"]}]}"#
        XCTAssertFalse(TailscalePolicyEdit.allows(policy: Data(other.utf8), target: target))
    }

    func testRefusesPolicyThatIsNotPlainJSON() {
        let hujson = """
            {
              // keep this note
              "acls": [],
            }
            """
        XCTAssertThrowsError(try TailscalePolicyEdit.apply(to: Data(hujson.utf8), target: target)) {
            XCTAssertEqual($0 as? TailscalePolicyEdit.Failure, .notPlainJSON)
        }
        XCTAssertThrowsError(try TailscalePolicyEdit.apply(to: Data("[]".utf8), target: target))
    }

    func testRefusesOddNodeAttrs() {
        XCTAssertThrowsError(try TailscalePolicyEdit.apply(to: Data(#"{"nodeAttrs":"x"}"#.utf8), target: target)) {
            XCTAssertEqual($0 as? TailscalePolicyEdit.Failure, .unexpectedShape)
        }
    }

    func testSlashesAreNotEscaped() throws {
        let data = try updated(#"{"note":"a/b"}"#)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("a/b"))
    }
}

final class TailscaleCredentialTests: XCTestCase {
    func testReadsAccessTokenAndOAuthSecret() {
        XCTAssertEqual(TailscaleCredential(pasted: "  tskey-api-abc \n"), .accessToken("tskey-api-abc"))
        XCTAssertEqual(
            TailscaleCredential(pasted: "tskey-client-k123CNTRL-secretpart"),
            .oauthClient(id: "k123CNTRL", secret: "tskey-client-k123CNTRL-secretpart")
        )
        XCTAssertNil(TailscaleCredential(pasted: "   "))
    }

    func testVaultSavesLoadsAndRemovesThroughTheInjectedStore() throws {
        let store = InMemorySecretBytesStore()
        let vault = TailscaleCredentialVault(store: store)
        XCTAssertNil(try vault.load())
        XCTAssertNil(try vault.save(pasted: "  "))
        XCTAssertNil(try store.read())
        try vault.save(pasted: " tskey-api-1 ")
        XCTAssertEqual(try vault.load(), .accessToken("tskey-api-1"))
        XCTAssertEqual(try store.read(), Data("tskey-api-1".utf8))
        try vault.remove()
        XCTAssertNil(try vault.load())
    }

    func testKeychainServiceNameIsThisAppsOwn() {
        XCTAssertEqual(KeychainSecretBytesStore().service, "iMCP Tailscale API token")
    }
}

/// A policy service that records what it is asked and answers from a script.
private final class FakePolicyService: TailscalePolicyService, @unchecked Sendable {
    var policy: Data
    var etag: String
    var failReplace: TailscaleAPIError?
    var dropWrites = false
    private(set) var replaced: [(Data, String)] = []

    init(policy: String, etag: String = "\"e1\"") {
        self.policy = Data(policy.utf8)
        self.etag = etag
    }

    func fetchPolicy() async throws -> TailscalePolicySnapshot {
        TailscalePolicySnapshot(data: policy, etag: etag)
    }

    func replacePolicy(_ new: Data, ifMatch: String) async throws {
        replaced.append((new, ifMatch))
        if let failReplace { throw failReplace }
        if !dropWrites { policy = new }
    }
}

@MainActor
final class TailscaleAccessControllerTests: XCTestCase {
    private let target = "100.64.0.7"

    private func make(_ service: FakePolicyService) -> (TailscaleAccessController, InMemorySecretBytesStore) {
        let store = InMemorySecretBytesStore()
        let controller = TailscaleAccessController(
            vault: TailscaleCredentialVault(store: store),
            makeService: { _ in service }
        )
        return (controller, store)
    }

    func testReviewThenConfirmWritesWithIfMatchAndVerifies() async throws {
        let service = FakePolicyService(policy: #"{"acls":[]}"#)
        let (controller, store) = make(service)
        await controller.useCredential("tskey-api-1", target: target)
        guard case .review(let plan) = controller.phase else { return XCTFail("expected review") }
        XCTAssertEqual(plan.etag, "\"e1\"")
        XCTAssertTrue(plan.entryText.contains(target))
        XCTAssertTrue(service.replaced.isEmpty, "nothing is written before confirmation")
        XCTAssertNotNil(try store.read())

        await controller.confirm()
        XCTAssertEqual(controller.phase, .done)
        XCTAssertEqual(service.replaced.count, 1)
        XCTAssertEqual(service.replaced[0].1, "\"e1\"")
    }

    func testAlreadyAllowedWritesNothing() async {
        let service = FakePolicyService(policy: #"{"nodeAttrs":[{"target":["*"],"attr":["funnel"]}]}"#)
        let (controller, _) = make(service)
        await controller.useCredential("tskey-api-1", target: target)
        XCTAssertEqual(controller.phase, .alreadyAllowed)
        XCTAssertTrue(service.replaced.isEmpty)
    }

    func testHuJSONPolicyIsRefusedWithAClearMessage() async {
        let service = FakePolicyService(policy: "{ // note\n \"acls\": [], }")
        let (controller, _) = make(service)
        await controller.useCredential("tskey-api-1", target: target)
        guard case .failed(let message) = controller.phase else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("will not rewrite"))
        XCTAssertTrue(service.replaced.isEmpty)
    }

    func testConcurrentEditIsReportedAndNotOverwritten() async {
        let service = FakePolicyService(policy: "{}")
        service.failReplace = .policyChanged
        let (controller, _) = make(service)
        await controller.useCredential("tskey-api-1", target: target)
        await controller.confirm()
        XCTAssertEqual(controller.phase, .failed(TailscaleAPIError.policyChanged.localizedDescription))
    }

    func testReadBackThatLacksTheChangeIsAFailure() async {
        let service = FakePolicyService(policy: "{}")
        service.dropWrites = true
        let (controller, _) = make(service)
        await controller.useCredential("tskey-api-1", target: target)
        await controller.confirm()
        guard case .failed = controller.phase else { return XCTFail("expected failure") }
    }

    func testRemoveClearsTheStoredToken() async throws {
        let (controller, store) = make(FakePolicyService(policy: "{}"))
        await controller.useCredential("tskey-api-1", target: target)
        XCTAssertTrue(controller.hasCredential)
        controller.removeCredential()
        XCTAssertFalse(controller.hasCredential)
        XCTAssertNil(try store.read())
        XCTAssertEqual(controller.phase, .idle)
    }
}

final class TailscaleAPIClientTests: XCTestCase {
    private final class Recorder: @unchecked Sendable { var requests: [URLRequest] = [] }

    private func response(_ request: URLRequest, _ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    func testFetchAsksForHuJSONAndReadsTheETag() async throws {
        let recorder = Recorder()
        let client = TailscaleAPIClient(credential: .accessToken("tok")) { [self] request in
            recorder.requests.append(request)
            return (Data("{}".utf8), response(request, 200, headers: ["ETag": "\"abc\""]))
        }
        let snapshot = try await client.fetchPolicy()
        XCTAssertEqual(snapshot.etag, "\"abc\"")
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.tailscale.com/api/v2/tailnet/-/acl")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/hujson")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testReplaceSendsIfMatch() async throws {
        let recorder = Recorder()
        let client = TailscaleAPIClient(credential: .accessToken("tok")) { [self] request in
            recorder.requests.append(request)
            return (Data(), response(request, 200))
        }
        try await client.replacePolicy(Data("{}".utf8), ifMatch: "\"abc\"")
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"abc\"")
        XCTAssertEqual(request.httpBody, Data("{}".utf8))
    }

    func testStatusCodesBecomePlainReasons() async {
        for (status, expected) in [
            (401, TailscaleAPIError.rejectedCredential), (403, .missingPermission), (412, .policyChanged),
        ] {
            let client = TailscaleAPIClient(credential: .accessToken("tok")) { [self] request in
                (Data(), response(request, status))
            }
            do {
                try await client.replacePolicy(Data(), ifMatch: "x")
                XCTFail("expected failure for \(status)")
            } catch {
                XCTAssertEqual(error as? TailscaleAPIError, expected)
            }
        }
    }

    func testMissingETagIsAnInvalidResponse() async {
        let client = TailscaleAPIClient(credential: .accessToken("tok")) { [self] request in
            (Data("{}".utf8), response(request, 200))
        }
        do {
            _ = try await client.fetchPolicy()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? TailscaleAPIError, .invalidResponse)
        }
    }

    func testOAuthClientIsExchangedBeforeTheCall() async throws {
        let recorder = Recorder()
        let client = TailscaleAPIClient(credential: .oauthClient(id: "k1", secret: "tskey-client-k1-zzz")) {
            [self] request in
            recorder.requests.append(request)
            if request.url?.path.hasSuffix("/oauth/token") == true {
                return (Data(#"{"access_token":"short-lived","expires_in":3600}"#.utf8), response(request, 200))
            }
            return (Data("{}".utf8), response(request, 200, headers: ["ETag": "\"e\""]))
        }
        _ = try await client.fetchPolicy()
        XCTAssertEqual(recorder.requests.count, 2)
        let body = String(decoding: recorder.requests[0].httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=client_credentials"))
        XCTAssertTrue(body.contains("scope=policy_file"))
        XCTAssertEqual(recorder.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer short-lived")
    }
}
