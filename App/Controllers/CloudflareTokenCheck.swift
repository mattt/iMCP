import Foundation

/// What Cloudflare says about an API token, in words that a person can act on.
enum CloudflareTokenVerification: Equatable, Sendable {
    /// The token works. `expiresOn` is Cloudflare's own date text, when the token has one.
    case valid(expiresOn: String?)
    /// Cloudflare knows the token but it cannot be used: disabled or expired.
    case notActive(String)
    /// Cloudflare did not accept the token. The text is Cloudflare's reason.
    case rejected(String)

    var isValid: Bool {
        if case .valid = self { true } else { false }
    }

    /// One short line for the set-up screen.
    var summary: String {
        switch self {
        case .valid(let expiresOn?): "Token is valid. It expires on \(expiresOn)."
        case .valid(nil): "Token is valid."
        case .notActive(let reason), .rejected(let reason): reason
        }
    }

    /// Reads the answer of `GET /user/tokens/verify`.
    ///
    /// Cloudflare answers `{"success":true,"result":{"id":"…","status":"active","expires_on":"…"}}`.
    /// `status` is `active`, `disabled` or `expired`. A token that Cloudflare rejects gets an error envelope.
    static func parse(data: Data, statusCode: Int) -> CloudflareTokenVerification {
        struct Envelope: Decodable {
            struct Failure: Decodable { let code: Int?, message: String? }
            struct Result: Decodable {
                let status: String?
                let expires_on: String?
            }
            let success: Bool?
            let errors: [Failure]?
            let result: Result?
        }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return .rejected("Cloudflare sent an answer that iMCP could not read (HTTP \(statusCode)).")
        }
        if envelope.success == true, (200 ..< 300).contains(statusCode), let result = envelope.result {
            switch result.status?.lowercased() {
            case "active":
                let expires = result.expires_on.flatMap { $0.isEmpty ? nil : $0 }
                return .valid(expiresOn: expires.map(Self.dateText))
            case "expired": return .notActive("This token has expired. Create a new one.")
            case "disabled": return .notActive("This token is disabled in Cloudflare. Turn it on or create a new one.")
            default:
                return .notActive("Cloudflare reports this token as \(result.status ?? "unknown"), not active.")
            }
        }
        if let message = envelope.errors?.first?.message, !message.isEmpty {
            return .rejected("Cloudflare did not accept this token: \(message)")
        }
        return .rejected("Cloudflare did not accept this token (HTTP \(statusCode)).")
    }

    /// The date part of Cloudflare's timestamp, for example `2027-01-31`.
    private static func dateText(_ timestamp: String) -> String {
        String(timestamp.prefix(10))
    }
}

extension CloudflareAPIClient {
    static let tokenVerifyURL = baseURL.appending(path: "user/tokens/verify")

    /// Asks Cloudflare whether the token is good. Throws only when the request itself could not be made.
    func verifyToken() async throws -> CloudflareTokenVerification {
        var request = URLRequest(url: Self.tokenVerifyURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw CloudflareError.invalidResponse }
        return CloudflareTokenVerification.parse(data: data, statusCode: http.statusCode)
    }
}

extension CloudflareChecklist {
    /// Cloudflare's page for creating a token. Cloudflare documents no link that fills in the
    /// permissions, so the screen lists them beside this link.
    static let apiTokensURL = URL(string: "https://dash.cloudflare.com/profile/api-tokens")!

    /// The permissions as one line each, for the token instructions.
    static var permissionLines: [String] {
        requiredPermissions.map { "\($0.scope) \u{2192} \($0.name) \u{2192} \($0.access)" }
    }
}
