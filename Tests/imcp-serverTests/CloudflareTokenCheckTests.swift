import XCTest

final class CloudflareTokenCheckTests: XCTestCase {
    private func parse(_ json: String, status: Int = 200) -> CloudflareTokenVerification {
        CloudflareTokenVerification.parse(data: Data(json.utf8), statusCode: status)
    }

    func testActiveTokenIsValid() {
        let verdict = parse(#"{"success":true,"result":{"id":"x","status":"active"},"errors":[]}"#)
        XCTAssertEqual(verdict, .valid(expiresOn: nil))
        XCTAssertEqual(verdict.summary, "Token is valid.")
    }

    func testExpiryShowsTheDateOnly() {
        let verdict = parse(
            #"{"success":true,"result":{"status":"active","expires_on":"2027-01-31T23:59:59Z"}}"#
        )
        XCTAssertEqual(verdict.summary, "Token is valid. It expires on 2027-01-31.")
    }

    func testExpiredAndDisabledAreNotActive() {
        XCTAssertEqual(
            parse(#"{"success":true,"result":{"status":"expired"}}"#),
            .notActive("This token has expired. Create a new one.")
        )
        guard case .notActive(let text) = parse(#"{"success":true,"result":{"status":"disabled"}}"#) else {
            return XCTFail("disabled should not be active")
        }
        XCTAssertTrue(text.contains("disabled"))
    }

    func testRejectedTokenCarriesCloudflaresReason() {
        let verdict = parse(
            #"{"success":false,"errors":[{"code":1000,"message":"Invalid API Token"}],"result":null}"#,
            status: 401
        )
        XCTAssertEqual(verdict, .rejected("Cloudflare did not accept this token: Invalid API Token"))
        XCTAssertFalse(verdict.isValid)
    }

    func testUnreadableAnswerIsRejected() {
        XCTAssertFalse(parse("<html>", status: 502).isValid)
        XCTAssertFalse(parse(#"{"success":true,"result":{"status":"active"}}"#, status: 500).isValid)
    }

    func testVerifyCallUsesTheUserEndpointWithBearerAuth() async throws {
        final class Box: @unchecked Sendable { var request: URLRequest? }
        let box = Box()
        let client = CloudflareAPIClient(apiToken: "secret-token") { request in
            box.request = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"success":true,"result":{"status":"active"}}"#.utf8), response)
        }
        let verdict = try await client.verifyToken()
        XCTAssertTrue(verdict.isValid)
        XCTAssertEqual(box.request?.url?.absoluteString, "https://api.cloudflare.com/client/v4/user/tokens/verify")
        XCTAssertEqual(box.request?.httpMethod, "GET")
        XCTAssertEqual(box.request?.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testPermissionLinesNameEveryRequiredPermission() {
        let lines = CloudflareChecklist.permissionLines
        XCTAssertEqual(lines.count, CloudflareChecklist.requiredPermissions.count)
        XCTAssertTrue(lines.contains { $0.contains("DNS") && $0.contains("Edit") })
        XCTAssertTrue(lines.contains { $0.contains("Cloudflare Tunnel") && $0.contains("Edit") })
        XCTAssertEqual(CloudflareChecklist.apiTokensURL.host, "dash.cloudflare.com")
    }

    @MainActor
    func testTokenSignInStoresOnlyInTheInjectedStorageAndCanBeRemoved() async throws {
        let suite = "imcp-cf-token-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = InMemoryCloudflareSecretStorage()
        let controller = CloudflareTunnelController(
            secretStorage: storage,
            defaults: defaults,
            httpTransport: { request in
                let path = request.url!.path
                let body: String
                if path.hasSuffix("/user/tokens/verify") {
                    body = #"{"success":true,"result":{"status":"active"}}"#
                } else {
                    body =
                        #"{"success":true,"result":[{"id":"z1","name":"example.com","status":"active","account":{"id":"a1","name":"A"}}]}"#
                }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(body.utf8), response)
            },
            certSearchURLs: []
        )
        let verdict = await controller.checkAPIToken("tok")
        XCTAssertTrue(verdict.isValid)
        await controller.signIn(withAPIToken: "tok")
        XCTAssertEqual(try storage.load()?.apiToken, "tok")
        XCTAssertEqual(controller.zones.map(\.name), ["example.com"])
        XCTAssertTrue(controller.isSignedInWithToken)

        controller.logOut()
        XCTAssertNil(try storage.load())
        XCTAssertFalse(controller.isSignedInWithToken)
        XCTAssertNil(controller.account)
    }
}
