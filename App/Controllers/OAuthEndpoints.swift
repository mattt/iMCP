import Foundation
import MCP

/// A response that the server writes: an MCP response, or a plain one for the OAuth endpoints.
enum ServedResponse: Sendable {
    case mcp(MCP.HTTPResponse)
    case raw(status: Int, headers: [String: String], body: Data)

    var statusCode: Int {
        switch self {
        case .mcp(let response): response.statusCode
        case .raw(let status, _, _): status
        }
    }
}

/// The HTTP side of iMCP's OAuth authorization server, which public access serves
/// beside the MCP endpoint, following the MCP authorization spec, version 2025-11-25.
///
/// | Path | Standard |
/// | --- | --- |
/// | `/.well-known/oauth-protected-resource` (and `/mcp` suffix) | RFC 9728 |
/// | `/.well-known/oauth-authorization-server` | RFC 8414 |
/// | `/register` | RFC 7591 dynamic client registration |
/// | `/authorize` | OAuth 2.1 authorization endpoint, with PKCE S256 and RFC 8707 `resource` |
/// | `/token` | OAuth 2.1 token endpoint, with refresh token rotation |
///
/// These paths need no bearer token, because they're how a client gets one.
/// The caller checks the `Host` and `Origin` first, like it does for `/mcp`.
final class OAuthEndpoints: @unchecked Sendable {
    typealias ApprovalHandler = @Sendable (OAuthApprovalRequest) async -> OAuthDecision

    static let protectedResourcePaths: Set<String> = [
        "/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp",
    ]
    static let authorizationServerPath = "/.well-known/oauth-authorization-server"
    static let paths: Set<String> = protectedResourcePaths.union([
        authorizationServerPath, "/authorize", "/token", "/register",
    ])

    static func handles(path: String) -> Bool { paths.contains(path) }

    /// The URL of the protected resource metadata, which a `401` response points to.
    static func resourceMetadataURL(host: String) -> String {
        "https://\(host)/.well-known/oauth-protected-resource"
    }

    let authority: OAuthAuthority
    /// How long one request to `/authorize` waits for a decision before the page asks again.
    private let pollWindow: Duration
    private let lock = NSLock()
    private var approve: ApprovalHandler?

    init(authority: OAuthAuthority, pollWindow: Duration = .seconds(15)) {
        self.authority = authority
        self.pollWindow = pollWindow
    }

    /// Sets how iMCP asks the owner. Without a handler, every request is denied.
    func setApprovalHandler(_ handler: ApprovalHandler?) {
        lock.withLock { approve = handler }
    }

    func handle(_ message: HTTPRequestMessage, host: String) async -> ServedResponse {
        switch message.path {
        case let path where Self.protectedResourcePaths.contains(path):
            return get(message) { Self.json(200, Self.protectedResourceMetadata(host: host)) }
        case Self.authorizationServerPath:
            return get(message) { Self.json(200, Self.authorizationServerMetadata(host: host)) }
        case "/register":
            return message.method == "POST" ? register(message) : methodNotAllowed("POST")
        case "/authorize":
            return message.method == "GET" ? await authorize(message, host: host) : methodNotAllowed("GET")
        case "/token":
            return message.method == "POST" ? token(message, host: host) : methodNotAllowed("POST")
        default:
            return Self.json(404, ["error": "not_found"])
        }
    }

    // MARK: Metadata

    static func protectedResourceMetadata(host: String) -> [String: Any] {
        [
            "resource": FunnelPolicy.publicURL(host: host),
            "authorization_servers": ["https://\(host)"],
            "bearer_methods_supported": ["header"],
            "scopes_supported": [OAuthAuthority.scope],
            "resource_name": "iMCP",
        ]
    }

    static func authorizationServerMetadata(host: String) -> [String: Any] {
        let issuer = "https://\(host)"
        return [
            "issuer": issuer,
            "authorization_endpoint": "\(issuer)/authorize",
            "token_endpoint": "\(issuer)/token",
            "registration_endpoint": "\(issuer)/register",
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["S256"],
            "token_endpoint_auth_methods_supported": ["none"],
            "scopes_supported": [OAuthAuthority.scope],
            "client_id_metadata_document_supported": true,
            "authorization_response_iss_parameter_supported": true,
        ]
    }

    private func get(_ message: HTTPRequestMessage, _ body: () -> ServedResponse) -> ServedResponse {
        message.method == "GET" ? body() : methodNotAllowed("GET")
    }

    // MARK: Registration

    private func register(_ message: HTTPRequestMessage) -> ServedResponse {
        if let wait = authority.admitRegistration() { return tooManyRequests(wait, json: true) }
        guard let object = (try? JSONSerialization.jsonObject(with: message.body)) as? [String: Any],
            let uris = object["redirect_uris"] as? [String]
        else {
            return Self.registrationError("invalid_client_metadata", "Send a JSON object with redirect_uris.")
        }
        if let method = object["token_endpoint_auth_method"] as? String, method != "none" {
            return Self.registrationError("invalid_client_metadata", "iMCP supports public clients only: use none.")
        }
        if let grants = object["grant_types"] as? [String],
            !Set(grants).isSubset(of: ["authorization_code", "refresh_token"])
        {
            return Self.registrationError(
                "invalid_client_metadata",
                "Use the authorization_code and refresh_token grants."
            )
        }
        if let types = object["response_types"] as? [String], !Set(types).isSubset(of: ["code"]) {
            return Self.registrationError("invalid_client_metadata", "Use the code response type.")
        }
        do {
            let client = try authority.register(name: object["client_name"] as? String, redirectURIs: uris)
            return Self.json(
                201,
                [
                    "client_id": client.id,
                    "client_id_issued_at": Int(Date().timeIntervalSince1970),
                    "client_name": client.name,
                    "redirect_uris": client.redirectURIs,
                    "grant_types": ["authorization_code", "refresh_token"],
                    "response_types": ["code"],
                    "token_endpoint_auth_method": "none",
                ],
                extra: ["Cache-Control": "no-store"]
            )
        } catch let error as OAuthError {
            return Self.registrationError(error.code, error.description)
        } catch {
            return Self.registrationError("invalid_client_metadata", "The registration isn't valid.")
        }
    }

    private static func registrationError(_ code: String, _ description: String) -> ServedResponse {
        json(400, ["error": code, "error_description": description], extra: ["Cache-Control": "no-store"])
    }

    // MARK: Authorization

    private func authorize(_ message: HTTPRequestMessage, host: String) async -> ServedResponse {
        guard let query = Self.parseForm(message.query) else {
            return Self.errorPage("The request repeats a parameter or isn't valid.")
        }
        if let pending = query["pending"] {
            return await continuePending(pending, cookie: message.header("Cookie"), host: host)
        }
        if let wait = authority.admitAuthorization() { return tooManyRequests(wait, json: false) }
        // Errors about the client or the redirect URI show a page, and never redirect,
        // because the redirect URI isn't trusted until it matches a registered one.
        guard let clientID = query["client_id"], let client = await authority.resolveClient(id: clientID) else {
            return Self.errorPage("The app that sent you here isn't registered with iMCP.")
        }
        guard let redirectURI = query["redirect_uri"], client.redirectURIs.contains(redirectURI) else {
            return Self.errorPage("The app's redirect address doesn't match its registration.")
        }
        let state = query["state"]
        func fail(_ code: String, _ description: String) -> ServedResponse {
            Self.redirect(
                to: redirectURI,
                parameters: ["error": code, "error_description": description, "state": state, "iss": "https://\(host)"]
            )
        }
        guard query["response_type"] == "code" else {
            return fail("unsupported_response_type", "Use response_type=code.")
        }
        guard let challenge = query["code_challenge"], OAuthAuthority.isValidChallenge(challenge),
            query["code_challenge_method"] == "S256"
        else {
            return fail("invalid_request", "Use PKCE with code_challenge_method=S256.")
        }
        guard let resource = OAuthAuthority.canonicalResource(query["resource"], host: host) else {
            return fail("invalid_target", "The resource isn't this server's MCP endpoint.")
        }
        guard
            let request = authority.beginPending(
                client: client,
                redirectURI: redirectURI,
                state: state,
                challenge: challenge,
                resource: resource
            )
        else {
            return Self.html(503, Self.page("Try again later", "Too many apps are waiting for approval."))
        }
        let handler = lock.withLock { approve }
        Task { [authority] in
            let decision = await handler?(request) ?? .denied
            authority.setDecision(decision, for: request.id)
        }
        // The cookie ties the pending request to this browser: only a poll that sends it can get the code.
        // SameSite=Lax is enough, because the polls are same-site, and the redirect back to the app leaves this site.
        var response = waitingPage(request)
        if let secret = authority.takePollSecret(forPending: request.id),
            case .raw(let status, var headers, let body) = response
        {
            headers["Set-Cookie"] = Self.pollCookie(pendingID: request.id, secret: secret)
            response = .raw(status: status, headers: headers, body: body)
        }
        return response
    }

    static func pollCookieName(pendingID: String) -> String { "imcp_\(pendingID)" }

    static func pollCookie(pendingID: String, secret: String) -> String {
        "\(pollCookieName(pendingID: pendingID))=\(secret); Path=/authorize; Max-Age=\(Int(OAuthAuthority.pendingLifetime)); HttpOnly; Secure; SameSite=Lax"
    }

    /// The value of the cookie `name` in a `Cookie` header, if it's there exactly once.
    static func cookieValue(_ name: String, in header: String?) -> String? {
        let values = (header ?? "").split(separator: ";").compactMap { part -> String? in
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == name else { return nil }
            return String(pair[1]).trimmingCharacters(in: .whitespaces)
        }
        return values.count == 1 ? values[0] : nil
    }

    private func continuePending(_ id: String, cookie: String?, host: String) async -> ServedResponse {
        let secret = Self.cookieValue(Self.pollCookieName(pendingID: id), in: cookie)
        let deadline = ContinuousClock.now + pollWindow
        while true {
            switch authority.outcome(ofPending: id, pollSecret: secret) {
            case .unknown:
                return Self.errorPage("This request expired. Start again from the app.")
            case .denied(let uri, let state):
                return Self.redirect(
                    to: uri,
                    parameters: [
                        "error": "access_denied", "error_description": "The owner didn't approve access.",
                        "state": state, "iss": "https://\(host)",
                    ]
                )
            case .approved(let uri, let state, let code):
                return Self.redirect(to: uri, parameters: ["code": code, "state": state, "iss": "https://\(host)"])
            case .waiting:
                guard ContinuousClock.now < deadline else {
                    guard let request = authority.approvalRequest(forPending: id, pollSecret: secret) else {
                        return Self.errorPage("This request expired. Start again from the app.")
                    }
                    return waitingPage(request)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func waitingPage(_ request: OAuthApprovalRequest) -> ServedResponse {
        let body = """
            <p><strong>\(Self.escape(request.clientName))</strong> wants to use iMCP on your Mac.</p>
            <p>Confirmation code:</p>
            <p style="font-size:2.2rem;letter-spacing:.2em;font-family:ui-monospace,monospace"><strong>\(Self.escape(request.verificationCode))</strong></p>
            <p>Approve only if the iMCP window on your Mac shows this same code.</p>
            <p>Approve or deny it in the iMCP window on your Mac. This page continues by itself.</p>
            <p class="note">After approval, you return to \(Self.escape(request.redirectHost)).</p>
            """
        return Self.html(
            200,
            Self.page("Approve on your Mac", body, refresh: "/authorize?pending=\(request.id)")
        )
    }

    // MARK: Token

    private func token(_ message: HTTPRequestMessage, host: String) -> ServedResponse {
        let result: Result<OAuthTokens, OAuthError>
        if let form = Self.parseForm(String(decoding: message.body, as: UTF8.self)),
            message.header("Content-Type")?.lowercased().hasPrefix("application/x-www-form-urlencoded") == true
        {
            result = exchange(form, host: host)
        } else {
            result = .failure(.invalidRequest("Send the parameters as application/x-www-form-urlencoded."))
        }
        switch result {
        case .success(let tokens):
            return Self.json(
                200,
                [
                    "access_token": tokens.accessToken,
                    "token_type": "Bearer",
                    "expires_in": tokens.expiresIn,
                    "refresh_token": tokens.refreshToken,
                    "scope": OAuthAuthority.scope,
                ],
                extra: ["Cache-Control": "no-store", "Pragma": "no-cache"]
            )
        case .failure(let error):
            // A save that failed is iMCP's problem, so it doesn't count against the client.
            if error.status < 500 {
                if let wait = authority.tokenRetryAfter() { return tooManyRequests(wait, json: true) }
                authority.recordTokenFailure()
            }
            return Self.json(
                error.status,
                ["error": error.code, "error_description": error.description],
                extra: ["Cache-Control": "no-store", "Pragma": "no-cache"]
            )
        }
    }

    private func exchange(_ form: [String: String], host: String) -> Result<OAuthTokens, OAuthError> {
        do {
            guard let clientID = form["client_id"] else { throw OAuthError.invalidRequest("client_id is required.") }
            switch form["grant_type"] {
            case "authorization_code":
                guard let code = form["code"], let redirectURI = form["redirect_uri"],
                    let verifier = form["code_verifier"]
                else {
                    throw OAuthError.invalidRequest("code, redirect_uri, and code_verifier are required.")
                }
                return .success(
                    try authority.exchange(
                        code: code,
                        clientID: clientID,
                        redirectURI: redirectURI,
                        verifier: verifier,
                        resource: form["resource"],
                        host: host
                    )
                )
            case "refresh_token":
                guard let refresh = form["refresh_token"] else {
                    throw OAuthError.invalidRequest("refresh_token is required.")
                }
                return .success(
                    try authority.refresh(
                        refreshToken: refresh,
                        clientID: clientID,
                        resource: form["resource"],
                        host: host
                    )
                )
            default:
                throw OAuthError(
                    code: "unsupported_grant_type",
                    description: "Use authorization_code or refresh_token."
                )
            }
        } catch let error as OAuthError {
            return .failure(error)
        } catch {
            return .failure(.unavailable)
        }
    }

    // MARK: Responses

    private func methodNotAllowed(_ allow: String) -> ServedResponse {
        Self.json(405, ["error": "method_not_allowed"], extra: ["Allow": allow])
    }

    private func tooManyRequests(_ wait: Int, json isJSON: Bool) -> ServedResponse {
        let headers = ["Retry-After": String(wait), "Cache-Control": "no-store"]
        if isJSON {
            return Self.json(
                429,
                ["error": "temporarily_unavailable", "error_description": "Too many requests. Try again later."],
                extra: headers
            )
        }
        guard
            case .raw(_, var pageHeaders, let body) = Self.html(429, Self.page("Try again later", "Too many requests."))
        else {
            return Self.json(429, [:])
        }
        pageHeaders.merge(headers) { $1 }
        return .raw(status: 429, headers: pageHeaders, body: body)
    }

    static func json(_ status: Int, _ object: [String: Any], extra: [String: String] = [:]) -> ServedResponse {
        var headers = ["Content-Type": "application/json", "Cache-Control": "no-store"]
        headers.merge(extra) { $1 }
        let body =
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
        return .raw(status: status, headers: headers, body: body)
    }

    static func html(_ status: Int, _ page: String) -> ServedResponse {
        .raw(
            status: status,
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Cache-Control": "no-store",
                "Referrer-Policy": "no-referrer",
                "X-Content-Type-Options": "nosniff",
                "X-Frame-Options": "DENY",
                "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
            ],
            body: Data(page.utf8)
        )
    }

    static func errorPage(_ message: String) -> ServedResponse {
        html(400, page("Can't continue", "<p>\(escape(message))</p>"))
    }

    static func page(_ title: String, _ body: String, refresh: String? = nil) -> String {
        let meta = refresh.map { "<meta http-equiv=\"refresh\" content=\"1;url=\(escape($0))\">" } ?? ""
        return """
            <!doctype html><html lang="en"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">\(meta)
            <title>\(escape(title))</title>
            <style>body{font:16px -apple-system,system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem;color:#222}
            .note{color:#666;font-size:.9rem}@media(prefers-color-scheme:dark){body{background:#111;color:#eee}.note{color:#aaa}}</style>
            </head><body><h1>\(escape(title))</h1>\(body.hasPrefix("<") ? body : "<p>\(escape(body))</p>")</body></html>
            """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// A redirect to a registered URI, with parameters added to its query.
    static func redirect(to uri: String, parameters: [String: String?]) -> ServedResponse {
        let added = parameters.compactMap { key, value in value.map { (key, $0) } }
            .sorted { $0.0 < $1.0 }
            .map { "\(formEncode($0.0))=\(formEncode($0.1))" }
            .joined(separator: "&")
        let separator = uri.contains("?") ? "&" : "?"
        return .raw(
            status: 302,
            headers: [
                "Location": uri + separator + added, "Cache-Control": "no-store",
                "Referrer-Policy": "no-referrer",
            ],
            body: Data()
        )
    }

    // MARK: Forms

    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )

    static func formEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// Reads a query or form body. Returns `nil` if a name repeats or an escape isn't valid,
    /// because OAuth parameters must not repeat.
    static func parseForm(_ text: String) -> [String: String]? {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = decode(parts[0]), !name.isEmpty, result[name] == nil else { return nil }
            guard let value = parts.count > 1 ? decode(parts[1]) : "" else { return nil }
            result[name] = value
        }
        return result
    }

    private static func decode(_ part: Substring) -> String? {
        part.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}
