import CryptoKit
import Foundation
import XCTest

/// Tests for iMCP's OAuth authorization server for public access.
final class OAuthTests: XCTestCase {
    private let host = "mac-imcp.example.ts.net"
    private var resource: String { "https://\(host)/mcp" }
    private let redirect = "https://claude.ai/api/mcp/auth_callback"
    // The example from RFC 7636, appendix B.
    private let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    private let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
    }

    private func makeAuthority(
        storage: InMemoryOAuthGrantStorage = InMemoryOAuthGrantStorage(),
        clock: Clock = Clock(),
        fetch: @escaping OAuthAuthority.MetadataFetch = { _ in throw URLError(.cannotFindHost) }
    ) -> OAuthAuthority {
        OAuthAuthority(storage: storage, fetchMetadata: fetch, now: { clock.now })
    }

    /// Runs the authorization steps that the owner's approval completes, and returns a code.
    private func issueCode(
        _ authority: OAuthAuthority,
        client: OAuthClient,
        readOnly: Bool = true,
        resource requested: String? = nil
    ) throws -> String {
        let request = try XCTUnwrap(
            authority.beginPending(
                client: client,
                redirectURI: client.redirectURIs[0],
                state: "s",
                challenge: challenge,
                resource: requested ?? resource
            )
        )
        let secret = authority.takePollSecret(forPending: request.id)
        XCTAssertEqual(authority.outcome(ofPending: request.id, pollSecret: secret), .waiting)
        authority.setDecision(.approved(readOnly: readOnly), for: request.id)
        guard case .approved(_, _, let code) = authority.outcome(ofPending: request.id, pollSecret: secret) else {
            throw XCTSkip("Not approved")
        }
        return code
    }

    private func register(_ authority: OAuthAuthority) throws -> OAuthClient {
        try authority.register(name: "Claude", redirectURIs: [redirect])
    }

    private func exchange(
        _ authority: OAuthAuthority,
        code: String,
        client: OAuthClient,
        verifier override: String? = nil,
        resource: String? = nil
    ) throws -> OAuthTokens {
        try authority.exchange(
            code: code,
            clientID: client.id,
            redirectURI: client.redirectURIs[0],
            verifier: override ?? verifier,
            resource: resource,
            host: host
        )
    }

    // MARK: PKCE

    func testPKCEAcceptsOnlyS256Matches() {
        XCTAssertTrue(OAuthAuthority.verifyPKCE(verifier: verifier, challenge: challenge))
        // The plain method would send the verifier as the challenge.
        XCTAssertFalse(OAuthAuthority.verifyPKCE(verifier: verifier, challenge: verifier))
        XCTAssertFalse(OAuthAuthority.verifyPKCE(verifier: verifier + "a", challenge: challenge))
        XCTAssertFalse(OAuthAuthority.verifyPKCE(verifier: "short", challenge: challenge))
        XCTAssertFalse(OAuthAuthority.isValidChallenge(String(challenge.dropLast())))
    }

    func testCodeExchangeNeedsTheVerifier() throws {
        let authority = makeAuthority()
        let client = try register(authority)
        let code = try issueCode(authority, client: client)
        let wrong = String(repeating: "a", count: 43)
        XCTAssertThrowsError(try exchange(authority, code: code, client: client, verifier: wrong)) {
            XCTAssertEqual(($0 as? OAuthError)?.code, "invalid_grant")
        }
        // A failed attempt uses the code up.
        XCTAssertThrowsError(try exchange(authority, code: code, client: client))
    }

    // MARK: Redirect URIs

    func testRedirectURIRules() {
        for ok in [
            "https://claude.ai/cb", "http://localhost:3000/cb", "http://127.0.0.1:8080/cb", "http://[::1]:9/cb",
        ] {
            XCTAssertTrue(OAuthAuthority.isAllowedRedirectURI(ok), ok)
        }
        for bad in [
            "http://example.com/cb", "claude://callback", "https://claude.ai/cb#frag",
            "https://user@claude.ai/cb", "javascript:alert(1)", "https:///cb", "",
        ] {
            XCTAssertFalse(OAuthAuthority.isAllowedRedirectURI(bad), bad)
        }
        let authority = makeAuthority()
        XCTAssertThrowsError(try authority.register(name: "x", redirectURIs: ["http://example.com/cb"]))
        XCTAssertThrowsError(try authority.register(name: "x", redirectURIs: []))
    }

    func testAuthorizeRefusesUnregisteredRedirectWithoutRedirecting() async throws {
        let authority = makeAuthority()
        let client = try register(authority)
        let endpoints = OAuthEndpoints(authority: authority, pollWindow: .milliseconds(10))
        let query =
            "response_type=code&client_id=\(client.id)&redirect_uri=https%3A%2F%2Fevil.example%2Fcb"
            + "&code_challenge=\(challenge)&code_challenge_method=S256&state=x"
        let response = await endpoints.handle(get("/authorize", query: query), host: host)
        XCTAssertEqual(response.statusCode, 400)
        XCTAssertNil(header(response, "Location"))
        // Even a prefix of a registered URI isn't a match.
        let prefixed = query.replacingOccurrences(
            of: "evil.example%2Fcb",
            with: "claude.ai%2Fapi%2Fmcp%2Fauth_callback%2Fx"
        )
        let second = await endpoints.handle(get("/authorize", query: prefixed), host: host)
        XCTAssertEqual(second.statusCode, 400)
    }

    func testAuthorizeRequiresS256AndTheResource() async throws {
        let authority = makeAuthority()
        let client = try register(authority)
        let endpoints = OAuthEndpoints(authority: authority, pollWindow: .milliseconds(10))
        let base =
            "response_type=code&client_id=\(client.id)&redirect_uri=\(OAuthEndpoints.formEncode(redirect))&state=x"

        let plain = await endpoints.handle(
            get("/authorize", query: base + "&code_challenge=\(challenge)&code_challenge_method=plain"),
            host: host
        )
        XCTAssertTrue(header(plain, "Location")?.contains("error=invalid_request") == true)
        let none = await endpoints.handle(get("/authorize", query: base), host: host)
        XCTAssertTrue(header(none, "Location")?.contains("error=invalid_request") == true)
        let other = await endpoints.handle(
            get(
                "/authorize",
                query: base
                    + "&code_challenge=\(challenge)&code_challenge_method=S256&resource=https%3A%2F%2Fother.example%2Fmcp"
            ),
            host: host
        )
        XCTAssertTrue(header(other, "Location")?.contains("error=invalid_target") == true)
        XCTAssertTrue(header(other, "Location")?.contains("state=x") == true)
    }

    // MARK: Codes

    func testCodeWorksOnceAndExpires() throws {
        let clock = Clock()
        let authority = makeAuthority(clock: clock)
        let client = try register(authority)

        let code = try issueCode(authority, client: client)
        let tokens = try exchange(authority, code: code, client: client)
        XCTAssertTrue(tokens.accessToken.hasPrefix(OAuthAuthority.accessPrefix))
        XCTAssertEqual(tokens.expiresIn, 3600)
        XCTAssertNotNil(authority.authenticate(accessToken: tokens.accessToken, resource: resource))

        // Using the code again fails, and ends the grant that it created.
        XCTAssertThrowsError(try exchange(authority, code: code, client: client))
        XCTAssertNil(authority.authenticate(accessToken: tokens.accessToken, resource: resource))
        XCTAssertTrue(authority.allGrants.isEmpty)

        let late = try issueCode(authority, client: client)
        clock.advance(OAuthAuthority.codeLifetime + 1)
        XCTAssertThrowsError(try exchange(authority, code: late, client: client)) {
            XCTAssertEqual(($0 as? OAuthError)?.code, "invalid_grant")
        }
    }

    func testCodeBelongsToItsClientAndRedirect() throws {
        let authority = makeAuthority()
        let client = try register(authority)
        let other = try authority.register(name: "Other", redirectURIs: ["https://other.example/cb"])
        let code = try issueCode(authority, client: client)
        XCTAssertThrowsError(
            try authority.exchange(
                code: code,
                clientID: other.id,
                redirectURI: client.redirectURIs[0],
                verifier: verifier,
                resource: nil,
                host: host
            )
        )
        let again = try issueCode(authority, client: client)
        XCTAssertThrowsError(
            try authority.exchange(
                code: again,
                clientID: client.id,
                redirectURI: "https://claude.ai/other",
                verifier: verifier,
                resource: nil,
                host: host
            )
        )
    }

    // MARK: Refresh tokens

    func testRefreshRotatesAndReuseEndsTheGrant() throws {
        let storage = InMemoryOAuthGrantStorage()
        let authority = makeAuthority(storage: storage)
        let client = try register(authority)
        let first = try exchange(authority, code: try issueCode(authority, client: client), client: client)

        let second = try authority.refresh(
            refreshToken: first.refreshToken,
            clientID: client.id,
            resource: resource,
            host: host
        )
        XCTAssertNotEqual(second.refreshToken, first.refreshToken)
        XCTAssertNotNil(authority.authenticate(accessToken: second.accessToken, resource: resource))

        // Only hashes are saved.
        let saved = try JSONEncoder().encode(storage.grants)
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains(second.refreshToken))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains(first.refreshToken))

        // The replaced token comes back: someone kept a copy, so the whole grant ends.
        XCTAssertThrowsError(
            try authority.refresh(refreshToken: first.refreshToken, clientID: client.id, resource: nil, host: host)
        )
        XCTAssertNil(authority.authenticate(accessToken: second.accessToken, resource: resource))
        XCTAssertThrowsError(
            try authority.refresh(refreshToken: second.refreshToken, clientID: client.id, resource: nil, host: host)
        )
        XCTAssertTrue(storage.grants.isEmpty)
    }

    func testRefreshNeedsTheSameClient() throws {
        let authority = makeAuthority()
        let client = try register(authority)
        let other = try authority.register(name: "Other", redirectURIs: ["https://other.example/cb"])
        let tokens = try exchange(authority, code: try issueCode(authority, client: client), client: client)
        XCTAssertThrowsError(
            try authority.refresh(refreshToken: tokens.refreshToken, clientID: other.id, resource: nil, host: host)
        )
        // A client mix-up doesn't end the real client's grant.
        XCTAssertNoThrow(
            try authority.refresh(refreshToken: tokens.refreshToken, clientID: client.id, resource: nil, host: host)
        )
    }

    func testAccessTokensExpire() throws {
        let clock = Clock()
        let authority = makeAuthority(clock: clock)
        let client = try register(authority)
        let tokens = try exchange(authority, code: try issueCode(authority, client: client), client: client)
        clock.advance(OAuthAuthority.accessTokenLifetime - 1)
        XCTAssertNotNil(authority.authenticate(accessToken: tokens.accessToken, resource: resource))
        clock.advance(2)
        XCTAssertNil(authority.authenticate(accessToken: tokens.accessToken, resource: resource))
        // The refresh token still works, because access lasts until revoked.
        XCTAssertNoThrow(
            try authority.refresh(refreshToken: tokens.refreshToken, clientID: client.id, resource: nil, host: host)
        )
    }

    // MARK: Resource binding

    func testTokensWorkOnlyForTheirResource() throws {
        let authority = makeAuthority()
        let client = try register(authority)
        let tokens = try exchange(authority, code: try issueCode(authority, client: client), client: client)
        XCTAssertNotNil(authority.authenticate(accessToken: tokens.accessToken, resource: resource))
        XCTAssertNil(authority.authenticate(accessToken: tokens.accessToken, resource: "https://other.example/mcp"))
        // A token that a person created in Settings isn't an OAuth token.
        XCTAssertNil(authority.authenticate(accessToken: AccessToken.makeSecret(), resource: resource))
    }

    func testResourceIndicatorForms() {
        let canonical = "https://\(host)/mcp"
        for ok in [nil, canonical, "https://\(host)", "https://\(host)/", "HTTPS://MAC-IMCP.EXAMPLE.TS.NET/mcp"] {
            XCTAssertEqual(OAuthAuthority.canonicalResource(ok, host: host), canonical, ok ?? "nil")
        }
        for bad in [
            "https://other.example/mcp", "http://\(host)/mcp", "https://\(host)/other", "https://\(host)/mcp?x=1",
            "https://\(host)/mcp#f", "https://\(host):8443/mcp", "mac-imcp",
        ] {
            XCTAssertNil(OAuthAuthority.canonicalResource(bad, host: host), bad)
        }
    }

    func testExchangeWithAnotherResourceFails() throws {
        let authority = makeAuthority()
        let client = try register(authority)
        let code = try issueCode(authority, client: client)
        XCTAssertThrowsError(try exchange(authority, code: code, client: client, resource: "https://other.example/mcp"))
        {
            XCTAssertEqual(($0 as? OAuthError)?.code, "invalid_target")
        }
    }

    // MARK: Revocation

    func testRevokingEndsEveryToken() throws {
        let storage = InMemoryOAuthGrantStorage()
        let authority = makeAuthority(storage: storage)
        let client = try register(authority)
        let tokens = try exchange(authority, code: try issueCode(authority, client: client), client: client)
        let grant = try XCTUnwrap(authority.allGrants.first)
        XCTAssertEqual(grant.clientName, "Claude")
        XCTAssertEqual(grant.redirectHost, "claude.ai")
        XCTAssertEqual(grant.permissions, .readOnly)

        try authority.revoke(id: grant.id)
        XCTAssertNil(authority.authenticate(accessToken: tokens.accessToken, resource: resource))
        XCTAssertThrowsError(
            try authority.refresh(refreshToken: tokens.refreshToken, clientID: client.id, resource: nil, host: host)
        )
        XCTAssertNil(authority.grant(id: grant.id))
        XCTAssertTrue(storage.grants.isEmpty)
    }

    func testRevokingStaysEffectiveWhenTheSaveFails() throws {
        let storage = InMemoryOAuthGrantStorage()
        let authority = makeAuthority(storage: storage)
        let client = try register(authority)
        let tokens = try exchange(authority, code: try issueCode(authority, client: client), client: client)
        let grant = try XCTUnwrap(authority.allGrants.first)

        storage.failsToSave = true
        XCTAssertThrowsError(try authority.revoke(id: grant.id))
        XCTAssertNil(authority.authenticate(accessToken: tokens.accessToken, resource: resource))
        XCTAssertThrowsError(
            try authority.refresh(refreshToken: tokens.refreshToken, clientID: client.id, resource: nil, host: host)
        )
    }

    func testGrantsSurviveARestartButAccessTokensDoNot() throws {
        let storage = InMemoryOAuthGrantStorage()
        let first = makeAuthority(storage: storage)
        let client = try register(first)
        let tokens = try exchange(first, code: try issueCode(first, client: client), client: client)

        let restarted = makeAuthority(storage: storage)
        XCTAssertNil(restarted.authenticate(accessToken: tokens.accessToken, resource: resource))
        XCTAssertNoThrow(
            try restarted.refresh(refreshToken: tokens.refreshToken, clientID: client.id, resource: nil, host: host)
        )
    }

    func testConnectingAgainReplacesTheEarlierGrant() throws {
        let authority = makeAuthority()
        let client = try register(authority)
        let first = try exchange(authority, code: try issueCode(authority, client: client), client: client)
        let second = try exchange(authority, code: try issueCode(authority, client: client), client: client)
        XCTAssertEqual(authority.allGrants.count, 1)
        XCTAssertNil(authority.authenticate(accessToken: first.accessToken, resource: resource))
        XCTAssertNotNil(authority.authenticate(accessToken: second.accessToken, resource: resource))
    }

    // MARK: Endpoints

    func testMetadataDocuments() async throws {
        let endpoints = OAuthEndpoints(authority: makeAuthority())
        for path in OAuthEndpoints.protectedResourcePaths {
            let response = await endpoints.handle(get(path), host: host)
            let json = try body(response)
            XCTAssertEqual(json["resource"] as? String, resource)
            XCTAssertEqual(json["authorization_servers"] as? [String], ["https://\(host)"])
        }
        let response = await endpoints.handle(get("/.well-known/oauth-authorization-server"), host: host)
        let json = try body(response)
        XCTAssertEqual(json["issuer"] as? String, "https://\(host)")
        XCTAssertEqual(json["code_challenge_methods_supported"] as? [String], ["S256"])
        XCTAssertEqual(json["token_endpoint"] as? String, "https://\(host)/token")
        XCTAssertEqual(json["registration_endpoint"] as? String, "https://\(host)/register")
        XCTAssertEqual(json["token_endpoint_auth_methods_supported"] as? [String], ["none"])
        XCTAssertEqual(json["client_id_metadata_document_supported"] as? Bool, true)
    }

    func testFullFlowThroughTheEndpoints() async throws {
        let authority = makeAuthority()
        let endpoints = OAuthEndpoints(authority: authority, pollWindow: .milliseconds(500))
        let asked = LockedBox<OAuthApprovalRequest?>(nil)
        endpoints.setApprovalHandler { request in
            asked.value = request
            return .approved(readOnly: false)
        }

        let registration = await endpoints.handle(
            post(
                "/register",
                json: ["client_name": "Claude", "redirect_uris": [redirect], "token_endpoint_auth_method": "none"]
            ),
            host: host
        )
        XCTAssertEqual(registration.statusCode, 201)
        let clientID = try XCTUnwrap(try body(registration)["client_id"] as? String)

        let query =
            "response_type=code&client_id=\(clientID)&redirect_uri=\(OAuthEndpoints.formEncode(redirect))"
            + "&code_challenge=\(challenge)&code_challenge_method=S256&state=a%2Bb&resource=\(OAuthEndpoints.formEncode(resource))"
        let waiting = await endpoints.handle(get("/authorize", query: query), host: host)
        XCTAssertEqual(waiting.statusCode, 200)
        let page = String(decoding: try rawBody(waiting), as: UTF8.self)
        XCTAssertTrue(page.contains("http-equiv=\"refresh\""))
        XCTAssertTrue(page.contains("Claude"))
        XCTAssertEqual(asked.value?.redirectHost, "claude.ai")

        let pendingID = try XCTUnwrap(asked.value?.id)
        let cookie = try XCTUnwrap(header(waiting, "Set-Cookie"))
        for attribute in ["HttpOnly", "Secure", "SameSite=Lax", "Path=/authorize"] {
            XCTAssertTrue(cookie.contains(attribute), cookie)
        }
        let cookieHeader = String(try XCTUnwrap(cookie.split(separator: ";").first))
        // The page and the owner's request show one code, with the full client ID and redirect URI.
        let code6 = try XCTUnwrap(asked.value?.verificationCode)
        XCTAssertEqual(code6.count, 6)
        XCTAssertTrue(page.contains(code6))
        XCTAssertTrue(try XCTUnwrap(asked.value?.confirmationPrompt).contains(code6))
        XCTAssertEqual(asked.value?.redirectURI, redirect)
        XCTAssertEqual(asked.value?.clientID, clientID)
        // A poll without the cookie, or with another secret, gets nothing.
        let bare = await endpoints.handle(get("/authorize", query: "pending=\(pendingID)"), host: host)
        XCTAssertEqual(bare.statusCode, 400)
        XCTAssertNil(header(bare, "Location"))
        let wrong = await endpoints.handle(
            get("/authorize", query: "pending=\(pendingID)", cookie: "imcp_\(pendingID)=nope"),
            host: host
        )
        XCTAssertNil(header(wrong, "Location"))
        let done = await endpoints.handle(
            get("/authorize", query: "pending=\(pendingID)", cookie: cookieHeader),
            host: host
        )
        XCTAssertEqual(done.statusCode, 302)
        let location = try XCTUnwrap(header(done, "Location"))
        let components = try XCTUnwrap(URLComponents(string: location))
        XCTAssertEqual(components.host, "claude.ai")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["state"], "a+b")
        XCTAssertEqual(items["iss"], "https://\(host)")
        let code = try XCTUnwrap(items["code"])
        // A finished request can't be replayed.
        let replay = await endpoints.handle(
            get("/authorize", query: "pending=\(pendingID)", cookie: cookieHeader),
            host: host
        )
        XCTAssertEqual(replay.statusCode, 400)

        let tokenResponse = await endpoints.handle(
            post(
                "/token",
                form: [
                    "grant_type": "authorization_code", "code": code, "client_id": clientID,
                    "redirect_uri": redirect, "code_verifier": verifier, "resource": resource,
                ]
            ),
            host: host
        )
        XCTAssertEqual(tokenResponse.statusCode, 200)
        XCTAssertEqual(header(tokenResponse, "Cache-Control"), "no-store")
        let tokens = try body(tokenResponse)
        XCTAssertEqual(tokens["token_type"] as? String, "Bearer")
        let access = try XCTUnwrap(tokens["access_token"] as? String)
        XCTAssertEqual(authority.authenticate(accessToken: access, resource: resource)?.permissions, .allTools)

        let refreshed = await endpoints.handle(
            post(
                "/token",
                form: [
                    "grant_type": "refresh_token", "refresh_token": try XCTUnwrap(tokens["refresh_token"] as? String),
                    "client_id": clientID,
                ]
            ),
            host: host
        )
        XCTAssertEqual(refreshed.statusCode, 200)
    }

    func testDenialRedirectsWithAnError() async throws {
        let authority = makeAuthority()
        let endpoints = OAuthEndpoints(authority: authority, pollWindow: .milliseconds(500))
        endpoints.setApprovalHandler { _ in .denied }
        let client = try register(authority)
        let query =
            "response_type=code&client_id=\(client.id)&redirect_uri=\(OAuthEndpoints.formEncode(redirect))"
            + "&code_challenge=\(challenge)&code_challenge_method=S256&state=z"
        let waiting = await endpoints.handle(get("/authorize", query: query), host: host)
        let page = String(decoding: try rawBody(waiting), as: UTF8.self)
        let pendingID = try XCTUnwrap(page.components(separatedBy: "pending=").dropFirst().first?.prefix { $0 != "\"" })
        let cookie = String(try XCTUnwrap(header(waiting, "Set-Cookie")?.split(separator: ";").first))
        let done = await endpoints.handle(get("/authorize", query: "pending=\(pendingID)", cookie: cookie), host: host)
        let location = try XCTUnwrap(header(done, "Location"))
        XCTAssertTrue(location.contains("error=access_denied"), location)
        XCTAssertTrue(location.contains("state=z"), location)
    }

    func testPendingRequestExpires() async throws {
        let clock = Clock()
        let authority = makeAuthority(clock: clock)
        let client = try register(authority)
        let request = try XCTUnwrap(
            authority.beginPending(
                client: client,
                redirectURI: redirect,
                state: nil,
                challenge: challenge,
                resource: resource
            )
        )
        let secret = authority.takePollSecret(forPending: request.id)
        clock.advance(OAuthAuthority.pendingLifetime + 1)
        guard case .denied = authority.outcome(ofPending: request.id, pollSecret: secret) else {
            return XCTFail("Expected denied")
        }
    }

    func testFailedTokenRequestsAreThrottledButGoodOnesAreNot() async throws {
        let authority = makeAuthority()
        let endpoints = OAuthEndpoints(authority: authority)
        let client = try register(authority)
        let bad = post(
            "/token",
            form: [
                "grant_type": "refresh_token", "refresh_token": "imcprt_nope", "client_id": client.id,
            ]
        )
        var statuses: [Int] = []
        for _ in 0 ..< FailedAuthLimiter().maximumFailures + 2 {
            statuses.append(await endpoints.handle(bad, host: host).statusCode)
        }
        XCTAssertEqual(statuses.first, 400)
        XCTAssertEqual(statuses.last, 429)

        let tokens = try exchange(authority, code: try issueCode(authority, client: client), client: client)
        let good = await endpoints.handle(
            post(
                "/token",
                form: [
                    "grant_type": "refresh_token", "refresh_token": tokens.refreshToken, "client_id": client.id,
                ]
            ),
            host: host
        )
        XCTAssertEqual(good.statusCode, 200)
    }

    func testTokenEndpointRejectsOtherGrantsAndJSON() async throws {
        let endpoints = OAuthEndpoints(authority: makeAuthority())
        let password = await endpoints.handle(
            post("/token", form: ["grant_type": "password", "client_id": "x"]),
            host: host
        )
        XCTAssertEqual(try body(password)["error"] as? String, "unsupported_grant_type")
        var json = post("/token", form: [:])
        json.headers["Content-Type"] = "application/json"
        let response = await endpoints.handle(json, host: host)
        XCTAssertEqual(response.statusCode, 400)
        let wrongMethod = await endpoints.handle(get("/token"), host: host)
        XCTAssertEqual(wrongMethod.statusCode, 405)
    }

    func testRegistrationIsLimited() async throws {
        let endpoints = OAuthEndpoints(authority: makeAuthority())
        var last = 0
        for _ in 0 ..< 25 {
            last = await endpoints.handle(post("/register", json: ["redirect_uris": [redirect]]), host: host).statusCode
        }
        XCTAssertEqual(last, 429)
        let bad = OAuthEndpoints(authority: makeAuthority())
        let response = await bad.handle(
            post("/register", json: ["redirect_uris": ["http://evil.example/cb"]]),
            host: host
        )
        XCTAssertEqual(try body(response)["error"] as? String, "invalid_redirect_uri")
    }

    // MARK: Client ID Metadata Documents

    func testMetadataDocumentMustNameItsOwnURL() throws {
        let url = "https://app.example/client.json"
        func document(_ id: String, uris: [String] = ["https://app.example/cb"], method: String? = nil) -> Data {
            var object: [String: Any] = ["client_id": id, "client_name": "App", "redirect_uris": uris]
            if let method { object["token_endpoint_auth_method"] = method }
            return try! JSONSerialization.data(withJSONObject: object)
        }
        XCTAssertEqual(OAuthAuthority.parseMetadataDocument(document(url), url: url)?.name, "App")
        XCTAssertNil(OAuthAuthority.parseMetadataDocument(document("https://evil.example/c.json"), url: url))
        XCTAssertNil(OAuthAuthority.parseMetadataDocument(document(url, uris: ["http://evil.example/cb"]), url: url))
        XCTAssertNil(OAuthAuthority.parseMetadataDocument(document(url, method: "client_secret_basic"), url: url))
        XCTAssertNil(OAuthAuthority.metadataURL(for: "https://app.example"))
        XCTAssertNil(OAuthAuthority.metadataURL(for: "https://app.example/c.json?x=1"))
        XCTAssertNil(OAuthAuthority.metadataURL(for: "http://app.example/c.json"))
    }

    func testResolvingAMetadataClientCachesTheFetch() async throws {
        let url = "https://app.example/client.json"
        let fetches = LockedBox(0)
        let document = try JSONSerialization.data(withJSONObject: [
            "client_id": url, "client_name": "App", "redirect_uris": ["https://app.example/cb"],
        ])
        let authority = makeAuthority(fetch: { _ in
            fetches.value += 1
            return document
        })
        let first = await authority.resolveClient(id: url)
        let second = await authority.resolveClient(id: url)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.redirectURIs, ["https://app.example/cb"])
        XCTAssertEqual(fetches.value, 1)
        let unknown = await authority.resolveClient(id: "imcpc_unknown")
        XCTAssertNil(unknown)
    }

    func testMetadataFetchRefusesPrivateTargets() {
        for name in [
            "localhost", "127.0.0.1", "10.0.0.1", "intranet", "printer.local", "mac.ts.net", "a.internal", "1.2.3.4",
        ] {
            XCTAssertFalse(ClientMetadataFetcher.isPublicName(name), name)
        }
        XCTAssertTrue(ClientMetadataFetcher.isPublicName("app.example.com"))
        for address in [
            [127, 0, 0, 1], [10, 1, 1, 1], [100, 64, 0, 1], [169, 254, 1, 1], [172, 16, 0, 1], [192, 168, 1, 1],
            [0, 0, 0, 0],
        ] {
            XCTAssertFalse(ClientMetadataFetcher.isPublicIPv4(address.map(UInt8.init)), "\(address)")
        }
        XCTAssertTrue(ClientMetadataFetcher.isPublicIPv4([8, 8, 8, 8]))
        let loopback = [UInt8](repeating: 0, count: 15) + [1]
        let mapped = [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 127, 0, 0, 1]
        let unique = [0xFD] + [UInt8](repeating: 0, count: 15)
        for address in [loopback, mapped, unique] {
            XCTAssertFalse(ClientMetadataFetcher.isPublicIPv6(address))
        }
        XCTAssertTrue(
            ClientMetadataFetcher.isPublicIPv6([0x26, 0x06, 0x47, 0x00] + [UInt8](repeating: 0, count: 11) + [0x11])
        )
    }

    func testMetadataFetchBlocksTranslationAndTunnelRanges() {
        func v6(_ prefix: [UInt8], last: UInt8 = 1) -> [UInt8] {
            prefix + [UInt8](repeating: 0, count: 15 - prefix.count) + [last]
        }
        let blocked: [[UInt8]] = [
            v6([0x00, 0x64, 0xFF, 0x9B], last: 7),  // 64:ff9b::/96
            [0x00, 0x64, 0xFF, 0x9B] + [0, 0, 0, 0, 0, 0, 0, 0] + [10, 0, 0, 1],  // NAT64 to 10.0.0.1
            [0x00, 0x64, 0xFF, 0x9B, 0x00, 0x01] + [UInt8](repeating: 0xAB, count: 10),  // 64:ff9b:1::/48
            [0x20, 0x02, 0x0A, 0x00, 0x00, 0x01] + [UInt8](repeating: 0, count: 10),  // 2002::/16
            [0xFE, 0xC0] + [UInt8](repeating: 0, count: 14),  // fec0::/10
            [0xFE, 0xFF] + [UInt8](repeating: 1, count: 14),
            [UInt8](repeating: 0, count: 12) + [8, 8, 8, 8],  // ::/96, IPv4-compatible
            [UInt8](repeating: 0, count: 16),
        ]
        for address in blocked {
            XCTAssertFalse(ClientMetadataFetcher.isPublicIPv6(address), "\(address)")
            XCTAssertFalse(ClientMetadataFetcher.isPublic(bytes: address))
        }
        // Neighbors outside the ranges stay reachable.
        XCTAssertTrue(
            ClientMetadataFetcher.isPublicIPv6([0x00, 0x64, 0xFF, 0x9B, 0x00, 0x02] + [UInt8](repeating: 1, count: 10))
        )
        XCTAssertTrue(ClientMetadataFetcher.isPublicIPv6([0x20, 0x03] + [UInt8](repeating: 1, count: 14)))
    }

    func testMetadataFetchConnectsToTheCheckedAddress() async throws {
        let pinned: [UInt8] = [93, 184, 216, 34]
        let seen = LockedBox<[(String, [UInt8], String)]>([])
        let url = try XCTUnwrap(URL(string: "https://app.example.com/meta.json?x=1"))
        let data = try await ClientMetadataFetcher.fetch(
            url,
            resolve: { _ in [pinned, [1, 1, 1, 1]] },
            transport: { host, address, request in
                seen.value.append((host, address, String(decoding: request, as: UTF8.self)))
                return Data("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n{\"a\":1}".utf8)
            }
        )
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"a\":1}")
        XCTAssertEqual(seen.value.count, 1)
        XCTAssertEqual(seen.value[0].0, "app.example.com")
        XCTAssertEqual(seen.value[0].1, pinned)
        XCTAssertTrue(seen.value[0].2.hasPrefix("GET /meta.json?x=1 HTTP/1.0\r\nHost: app.example.com\r\n"))
    }

    func testMetadataFetchKeepsEncodedLineBreaksOutOfTheRequest() async throws {
        let seen = LockedBox<[String]>([])
        let url = try XCTUnwrap(URL(string: "https://app.example.com/m%0D%0AX-Evil:%201.json?q=%0D%0A"))
        _ = try await ClientMetadataFetcher.fetch(
            url,
            resolve: { _ in [[93, 184, 216, 34]] },
            transport: { _, _, request in
                seen.value.append(String(decoding: request, as: UTF8.self))
                return Data("HTTP/1.0 200 OK\r\n\r\n{}".utf8)
            }
        )
        let request = try XCTUnwrap(seen.value.first)
        XCTAssertTrue(request.hasPrefix("GET /m%0D%0AX-Evil:%201.json?q=%0D%0A HTTP/1.0\r\nHost: app.example.com\r\n"))
        XCTAssertFalse(request.contains("\r\nX-Evil"))
    }

    func testMetadataFetchRefusesWhenAnyAddressIsPrivateOrTheAnswerIsNotOK() async throws {
        let url = try XCTUnwrap(URL(string: "https://app.example.com/meta.json"))
        let called = LockedBox(false)
        let transport: ClientMetadataFetcher.Transport = { _, _, _ in
            called.value = true
            return Data("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1/\r\n\r\n".utf8)
        }
        do {
            _ = try await ClientMetadataFetcher.fetch(
                url,
                resolve: { _ in [[8, 8, 8, 8], [10, 0, 0, 1]] },
                transport: transport
            )
            XCTFail("Expected a refusal")
        } catch is ClientMetadataFetcher.Refused {}
        XCTAssertFalse(called.value)
        do {
            _ = try await ClientMetadataFetcher.fetch(url, resolve: { _ in [[8, 8, 8, 8]] }, transport: transport)
            XCTFail("Expected a refusal")
        } catch is ClientMetadataFetcher.Refused {}
    }

    // MARK: Helpers

    private func get(_ path: String, query: String = "", cookie: String? = nil) -> HTTPRequestMessage {
        HTTPRequestMessage(
            method: "GET",
            path: path,
            query: query,
            headers: cookie.map { ["Cookie": $0] } ?? [:],
            body: Data(),
            keepAlive: true
        )
    }

    private func post(_ path: String, form: [String: String]) -> HTTPRequestMessage {
        let body = form.map { "\($0.key)=\(OAuthEndpoints.formEncode($0.value))" }.joined(separator: "&")
        return HTTPRequestMessage(
            method: "POST",
            path: path,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8),
            keepAlive: true
        )
    }

    private func post(_ path: String, json: [String: Any]) -> HTTPRequestMessage {
        HTTPRequestMessage(
            method: "POST",
            path: path,
            headers: ["Content-Type": "application/json"],
            body: (try? JSONSerialization.data(withJSONObject: json)) ?? Data(),
            keepAlive: true
        )
    }

    private func header(_ response: ServedResponse, _ name: String) -> String? {
        guard case .raw(_, let headers, _) = response else { return nil }
        return headers[name]
    }

    private func rawBody(_ response: ServedResponse) throws -> Data {
        guard case .raw(_, _, let body) = response else { throw XCTSkip("Not a raw response") }
        return body
    }

    private func body(_ response: ServedResponse) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: rawBody(response)) as? [String: Any])
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
