import AppKit
import Combine
import Darwin
import Foundation
import Network
import OSLog
import Security

private let log = Logger.server

// MARK: - Account & Models

/// Credentials extracted from a `cloudflared` `cert.pem` or entered from a Cloudflare API token.
struct CloudflareAccount: Codable, Equatable, Sendable {
    var accountID: String
    var zoneID: String?
    var apiToken: String

    /// Decodes a `cloudflared` `cert.pem` (or raw base64/JSON payload) into a ``CloudflareAccount``.
    static func parseCertPEM(_ pem: String) throws -> CloudflareAccount {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CloudflareError.invalidCertPEM("The cert.pem content is empty.")
        }

        // Accept raw JSON directly if pasted.
        if trimmed.hasPrefix("{"), let rawData = trimmed.data(using: .utf8),
            let decoded = try? decodeAccountJSON(rawData)
        {
            return decoded
        }

        let lines = trimmed.components(separatedBy: .newlines)
        let payloadLines = lines.filter { line in
            let item = line.trimmingCharacters(in: .whitespaces)
            return !item.isEmpty && !item.hasPrefix("-----BEGIN ") && !item.hasPrefix("-----END ")
        }
        let base64String = payloadLines.joined()
        guard let decodedData = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) else {
            throw CloudflareError.invalidCertPEM("Could not decode the base64 payload in cert.pem.")
        }
        return try decodeAccountJSON(decodedData)
    }

    static func parseCertPEM(data: Data) throws -> CloudflareAccount {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CloudflareError.invalidCertPEM("The cert.pem file is not valid UTF-8 text.")
        }
        return try parseCertPEM(text)
    }

    private static func decodeAccountJSON(_ data: Data) throws -> CloudflareAccount {
        struct RawPayload: Decodable {
            var accountID: String?
            var zoneID: String?
            var apiToken: String?
            var account_id: String?
            var zone_id: String?
            var api_token: String?
        }
        let raw: RawPayload
        do {
            raw = try JSONDecoder().decode(RawPayload.self, from: data)
        } catch {
            throw CloudflareError.invalidCertPEM("The cert.pem JSON payload is malformed.")
        }

        let accountID = (raw.accountID ?? raw.account_id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let apiToken = (raw.apiToken ?? raw.api_token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let zoneRaw = (raw.zoneID ?? raw.zone_id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !accountID.isEmpty, !apiToken.isEmpty else {
            throw CloudflareError.invalidCertPEM("cert.pem must include both accountID and apiToken.")
        }
        return CloudflareAccount(
            accountID: accountID,
            zoneID: zoneRaw.isEmpty ? nil : zoneRaw,
            apiToken: apiToken
        )
    }

    /// The `cert.pem` path inside iMCP's Application Support directory.
    static func containerCertURL(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL {
        URL.applicationSupportDirectory
            .appending(path: bundleIdentifier ?? LocalSocket.appBundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "cloudflared", directoryHint: .isDirectory)
            .appending(path: "cert.pem")
    }

    /// Candidate locations where `cert.pem` may already exist on this Mac.
    static func candidateCertURLs(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> [URL] {
        var candidates: [URL] = [
            containerCertURL(bundleIdentifier: bundleIdentifier),
            URL.applicationSupportDirectory
                .appending(path: "iMCP", directoryHint: .isDirectory)
                .appending(path: "cloudflared", directoryHint: .isDirectory)
                .appending(path: "cert.pem"),
        ]
        if let realHome = realHomeDirectoryURL() {
            candidates.append(realHome.appending(path: ".cloudflared/cert.pem"))
        }
        let currentHome = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cloudflared/cert.pem")
        if !candidates.contains(currentHome) {
            candidates.append(currentHome)
        }
        return candidates
    }

    /// Finds the first readable and valid `cert.pem` among the candidate URLs.
    static func discoverLocalCertAccount(searchURLs: [URL]? = nil) -> (url: URL, account: CloudflareAccount)? {
        let urls = searchURLs ?? candidateCertURLs()
        for url in urls {
            guard FileManager.default.isReadableFile(atPath: url.path),
                let data = try? Data(contentsOf: url),
                let account = try? parseCertPEM(data: data)
            else { continue }
            return (url, account)
        }
        return nil
    }

    private static func realHomeDirectoryURL() -> URL? {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
}

struct CloudflareZone: Codable, Equatable, Identifiable, Sendable {
    struct AccountRef: Codable, Equatable, Sendable {
        let id: String
        let name: String?
    }

    let id: String
    let name: String
    let status: String?
    let account: AccountRef?
}

struct CloudflareAccountInfo: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct CloudflareTunnelRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let status: String?
    let configSrc: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case configSrc = "config_src"
    }
}

struct CloudflareDNSRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let type: String
    let name: String
    let content: String
    let proxied: Bool?
}

struct CloudflareProvisionedTunnel: Equatable, Sendable {
    let tunnelID: String
    let tunnelName: String
    let hostname: String
    let runToken: String
}

// MARK: - Errors

enum CloudflareError: LocalizedError, Equatable, Sendable {
    case invalidCertPEM(String)
    case missingToken
    case missingAccountID
    case missingBinary
    case loginFailed(String)
    case processExited(Int32, String)
    case apiError(statusCode: Int, code: Int?, message: String)
    case conflictingDNSRecord(hostname: String, type: String)
    case invalidHostname
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidCertPEM(let reason):
            reason
        case .missingToken:
            "Enter a Cloudflare API token or log in with Cloudflare first."
        case .missingAccountID:
            "Couldn't determine your Cloudflare account ID from this token."
        case .missingBinary:
            "cloudflared wasn't found. Install it with `brew install cloudflared`."
        case .loginFailed(let reason):
            "Cloudflare login didn't finish: \(reason)"
        case .processExited(let status, let detail):
            detail.isEmpty
                ? "cloudflared stopped unexpectedly (exit code \(status))."
                : "cloudflared stopped (exit code \(status)): \(detail)"
        case .apiError(_, _, let message):
            "Cloudflare API error: \(message)"
        case .conflictingDNSRecord(let hostname, let type):
            "A \(type) DNS record already exists for \(hostname). Remove it or pick another hostname."
        case .invalidHostname:
            "Enter a valid subdomain or hostname for your Cloudflare domain."
        case .invalidResponse:
            "Cloudflare returned an unexpected response."
        }
    }
}

// MARK: - Cloudflare v4 REST API Client

/// Direct Cloudflare v4 REST API client built on URLSession.
struct CloudflareAPIClient: Sendable {
    typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let baseURL = URL(string: "https://api.cloudflare.com/client/v4")!

    let apiToken: String
    let transport: HTTPTransport

    init(
        apiToken: String,
        transport: @escaping HTTPTransport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.apiToken = apiToken
        self.transport = transport
    }

    // MARK: Zones & Accounts

    func listZones() async throws -> [CloudflareZone] {
        try await request(method: "GET", path: "zones", query: ["status": "active", "per_page": "50"])
    }

    func getZone(id: String) async throws -> CloudflareZone {
        let encoded = Self.pathComponent(id)
        return try await request(method: "GET", path: "zones/\(encoded)")
    }

    func listAccounts() async throws -> [CloudflareAccountInfo] {
        try await request(method: "GET", path: "accounts", query: ["per_page": "50"])
    }

    /// Discovers zones using `/zones`, falling back to `/zones/{zoneID}` when a cert.pem token
    /// is scoped to a single zone.
    func discoverZones(preferredZoneID: String? = nil) async throws -> [CloudflareZone] {
        do {
            let zones = try await listZones()
            if !zones.isEmpty { return zones }
        } catch {
            if let preferredZoneID, !preferredZoneID.isEmpty {
                return [try await getZone(id: preferredZoneID)]
            }
            throw error
        }
        if let preferredZoneID, !preferredZoneID.isEmpty {
            return [try await getZone(id: preferredZoneID)]
        }
        return []
    }

    // MARK: Tunnels

    func listTunnels(accountID: String, name: String) async throws -> [CloudflareTunnelRecord] {
        try await request(
            method: "GET",
            path: "accounts/\(Self.pathComponent(accountID))/cfd_tunnel",
            query: ["name": name, "is_deleted": "false"]
        )
    }

    func createTunnel(accountID: String, name: String) async throws -> CloudflareTunnelRecord {
        struct Body: Encodable {
            let name: String
            let config_src: String
        }
        return try await request(
            method: "POST",
            path: "accounts/\(Self.pathComponent(accountID))/cfd_tunnel",
            body: Body(name: name, config_src: "cloudflare")
        )
    }

    func configureTunnelIngress(
        accountID: String,
        tunnelID: String,
        hostname: String,
        serviceURL: String
    ) async throws {
        struct IngressRule: Encodable {
            let hostname: String?
            let service: String
        }
        struct Config: Encodable {
            let ingress: [IngressRule]
        }
        struct Body: Encodable {
            let config: Config
        }
        let _: EmptyResult? = try await requestOptional(
            method: "PUT",
            path: "accounts/\(Self.pathComponent(accountID))/cfd_tunnel/\(Self.pathComponent(tunnelID))/configurations",
            body: Body(
                config: Config(ingress: [
                    IngressRule(hostname: hostname, service: serviceURL),
                    IngressRule(hostname: nil, service: "http_status:404"),
                ])
            )
        )
    }

    func tunnelToken(accountID: String, tunnelID: String) async throws -> String {
        try await request(
            method: "GET",
            path: "accounts/\(Self.pathComponent(accountID))/cfd_tunnel/\(Self.pathComponent(tunnelID))/token"
        )
    }

    // MARK: DNS

    func listDNSRecords(zoneID: String, name: String) async throws -> [CloudflareDNSRecord] {
        try await request(
            method: "GET",
            path: "zones/\(Self.pathComponent(zoneID))/dns_records",
            query: ["name": name]
        )
    }

    func createDNSRecord(
        zoneID: String,
        type: String = "CNAME",
        name: String,
        content: String,
        proxied: Bool = true
    ) async throws -> CloudflareDNSRecord {
        struct Body: Encodable {
            let type: String
            let name: String
            let content: String
            let proxied: Bool
            let ttl: Int
        }
        return try await request(
            method: "POST",
            path: "zones/\(Self.pathComponent(zoneID))/dns_records",
            body: Body(type: type, name: name, content: content, proxied: proxied, ttl: 1)
        )
    }

    func updateDNSRecord(
        zoneID: String,
        recordID: String,
        type: String = "CNAME",
        name: String,
        content: String,
        proxied: Bool = true
    ) async throws -> CloudflareDNSRecord {
        struct Body: Encodable {
            let type: String
            let name: String
            let content: String
            let proxied: Bool
            let ttl: Int
        }
        return try await request(
            method: "PUT",
            path: "zones/\(Self.pathComponent(zoneID))/dns_records/\(Self.pathComponent(recordID))",
            body: Body(type: type, name: name, content: content, proxied: proxied, ttl: 1)
        )
    }

    @discardableResult
    func ensureProxiedCNAME(
        zoneID: String,
        hostname: String,
        tunnelID: String
    ) async throws -> CloudflareDNSRecord {
        let normalized = FunnelPolicy.normalizedHost(hostname)
        let target = "\(tunnelID).cfargotunnel.com"
        let existing = try await listDNSRecords(zoneID: zoneID, name: normalized)

        if let cname = existing.first(where: { $0.type.uppercased() == "CNAME" }) {
            if FunnelPolicy.normalizedHost(cname.content) == target, cname.proxied == true {
                return cname
            }
            return try await updateDNSRecord(
                zoneID: zoneID,
                recordID: cname.id,
                name: normalized,
                content: target,
                proxied: true
            )
        }
        if let conflict = existing.first {
            throw CloudflareError.conflictingDNSRecord(hostname: normalized, type: conflict.type)
        }
        return try await createDNSRecord(zoneID: zoneID, name: normalized, content: target, proxied: true)
    }

    // MARK: End-to-End Provisioning

    /// Creates or adopts the per-Mac tunnel, configures its ingress to `http://127.0.0.1:<localPort>`,
    /// ensures the proxied DNS CNAME record points to the tunnel, and returns the tunnel run token.
    func provisionTunnel(
        accountID: String,
        zoneID: String,
        hostname: String,
        tunnelName: String,
        localPort: UInt16
    ) async throws -> CloudflareProvisionedTunnel {
        let normalizedHost = FunnelPolicy.normalizedHost(hostname)
        guard !normalizedHost.isEmpty else { throw CloudflareError.invalidHostname }

        let existing = try await listTunnels(accountID: accountID, name: tunnelName)
        let tunnel: CloudflareTunnelRecord
        if let adopted = existing.first(where: { $0.name == tunnelName }) {
            tunnel = adopted
        } else {
            tunnel = try await createTunnel(accountID: accountID, name: tunnelName)
        }

        try await configureTunnelIngress(
            accountID: accountID,
            tunnelID: tunnel.id,
            hostname: normalizedHost,
            serviceURL: "http://127.0.0.1:\(localPort)"
        )
        try await ensureProxiedCNAME(zoneID: zoneID, hostname: normalizedHost, tunnelID: tunnel.id)
        let runToken = try await tunnelToken(accountID: accountID, tunnelID: tunnel.id)

        return CloudflareProvisionedTunnel(
            tunnelID: tunnel.id,
            tunnelName: tunnel.name,
            hostname: normalizedHost,
            runToken: runToken
        )
    }

    // MARK: Request Plumbing

    private struct EmptyBody: Encodable {}
    private struct EmptyResult: Decodable {}

    private struct Envelope<ResultType: Decodable>: Decodable {
        struct APIError: Decodable {
            let code: Int?
            let message: String?
        }

        let success: Bool
        let errors: [APIError]?
        let result: ResultType?
    }

    private func request<ResultType: Decodable>(
        method: String,
        path: String,
        query: [String: String] = [:]
    ) async throws -> ResultType {
        try await request(method: method, path: path, query: query, body: EmptyBody?.none)
    }

    private func request<ResultType: Decodable, Body: Encodable>(
        method: String,
        path: String,
        query: [String: String] = [:],
        body: Body?
    ) async throws -> ResultType {
        guard
            let result: ResultType = try await requestOptional(
                method: method,
                path: path,
                query: query,
                body: body
            )
        else {
            throw CloudflareError.invalidResponse
        }
        return result
    }

    private func requestOptional<ResultType: Decodable, Body: Encodable>(
        method: String,
        path: String,
        query: [String: String] = [:],
        body: Body?
    ) async throws -> ResultType? {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty {
            components?.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw CloudflareError.invalidResponse }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await transport(urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw CloudflareError.invalidResponse
        }

        if let envelope = try? JSONDecoder().decode(Envelope<ResultType>.self, from: data) {
            if envelope.success, (200 ..< 300).contains(http.statusCode) {
                return envelope.result
            }
            let firstError = envelope.errors?.first
            let message = firstError?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw CloudflareError.apiError(
                statusCode: http.statusCode,
                code: firstError?.code,
                message: message
            )
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            throw CloudflareError.apiError(
                statusCode: http.statusCode,
                code: nil,
                message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            )
        }
        throw CloudflareError.invalidResponse
    }

    private static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

// MARK: - Keychain Credential Storage

protocol CloudflareSecretStorage: Sendable {
    func load() throws -> CloudflareAccount?
    func save(_ account: CloudflareAccount) throws
    func clear() throws
}

final class InMemoryCloudflareSecretStorage: CloudflareSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var account: CloudflareAccount?

    init(account: CloudflareAccount? = nil) {
        self.account = account
    }

    func load() throws -> CloudflareAccount? {
        lock.withLock { account }
    }

    func save(_ account: CloudflareAccount) throws {
        lock.withLock { self.account = account }
    }

    func clear() throws {
        lock.withLock { account = nil }
    }
}

struct KeychainCloudflareSecretStorage: CloudflareSecretStorage {
    private var baseQuery: [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "\(Bundle.main.bundleIdentifier ?? LocalSocket.appBundleIdentifier).cloudflare",
            kSecAttrAccount: "cloudflare-account",
        ]
        if KeychainClientRecordStorage.usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = true
        }
        return query
    }

    func load() throws -> CloudflareAccount? {
        var query = baseQuery
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainClientRecordStorage.Error.status(status) }
        guard let data = result as? Data else {
            throw KeychainClientRecordStorage.Error.status(errSecDecode)
        }
        return try JSONDecoder().decode(CloudflareAccount.self, from: data)
    }

    func save(_ account: CloudflareAccount) throws {
        let data = try JSONEncoder().encode(account)
        let attributes: [CFString: Any] = [kSecValueData: data]
        var item = baseQuery
        var status = SecItemUpdate(item as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            item.merge(attributes) { $1 }
            if KeychainClientRecordStorage.usesDataProtectionKeychain {
                item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainClientRecordStorage.Error.status(status) }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainClientRecordStorage.Error.status(status)
        }
    }
}

// MARK: - cloudflared Process Runner

protocol CloudflareProcessHandle: AnyObject, Sendable {
    func terminate()
}

protocol CloudflareProcessRunner: Sendable {
    func findBinary() -> URL?
    func runBrowserLogin(origincertURL: URL) async throws -> CloudflareAccount
    func startTunnel(
        runToken: String,
        onExit: @escaping @Sendable (Int32, String) -> Void
    ) throws -> any CloudflareProcessHandle
}

final class SystemCloudflareProcessRunner: CloudflareProcessRunner, @unchecked Sendable {
    static let candidatePaths = [
        "/opt/homebrew/bin/cloudflared",
        "/usr/local/bin/cloudflared",
        "/usr/bin/cloudflared",
        "/opt/local/bin/cloudflared",
    ]

    func findBinary() -> URL? {
        for path in Self.candidatePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appending(path: "cloudflared")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    func runBrowserLogin(origincertURL: URL) async throws -> CloudflareAccount {
        guard let binary = findBinary() else {
            throw CloudflareError.missingBinary
        }

        let directory = origincertURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let process = Process()
        process.executableURL = binary
        process.arguments = ["tunnel", "--origincert", origincertURL.path, "login"]
        var env = ProcessInfo.processInfo.environment
        env["TUNNEL_ORIGIN_CERT"] = origincertURL.path
        env["NO_AUTOUPDATE"] = "true"
        process.environment = env

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { proc in
                    continuation.resume(returning: proc.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        let errText = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard status == 0 else {
            throw CloudflareError.loginFailed(errText.isEmpty ? "exit code \(status)" : lastLine(of: errText))
        }
        guard FileManager.default.isReadableFile(atPath: origincertURL.path) else {
            throw CloudflareError.loginFailed("cert.pem was not created at \(origincertURL.path).")
        }
        let data = try Data(contentsOf: origincertURL)
        return try CloudflareAccount.parseCertPEM(data: data)
    }

    func startTunnel(
        runToken: String,
        onExit: @escaping @Sendable (Int32, String) -> Void
    ) throws -> any CloudflareProcessHandle {
        guard let binary = findBinary() else {
            throw CloudflareError.missingBinary
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["tunnel", "--no-autoupdate", "run"]
        var env = ProcessInfo.processInfo.environment
        // Pass the run token via environment so it doesn't appear in process argument lists.
        env["TUNNEL_TOKEN"] = runToken
        env["NO_AUTOUPDATE"] = "true"
        process.environment = env

        let stderrPipe = Pipe()
        let outputLock = NSLock()
        var stderrTail = Data()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            outputLock.withLock {
                stderrTail.append(chunk)
                if stderrTail.count > 4096 {
                    stderrTail = stderrTail.suffix(4096)
                }
            }
        }
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        let handle = ProcessHandle(process: process)
        process.terminationHandler = { proc in
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let tail = outputLock.withLock { String(decoding: stderrTail, as: UTF8.self) }
            let summary = Self.lastLine(of: tail)
            if !handle.wasExplicitlyStopped {
                onExit(proc.terminationStatus, summary)
            }
        }
        try process.run()
        return handle
    }

    private static func lastLine(of text: String) -> String {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty } ?? ""
    }

    private func lastLine(of text: String) -> String {
        Self.lastLine(of: text)
    }

    private final class ProcessHandle: CloudflareProcessHandle, @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var stopped = false

        init(process: Process) {
            self.process = process
        }

        var wasExplicitlyStopped: Bool { lock.withLock { stopped } }

        func terminate() {
            lock.withLock { stopped = true }
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

// MARK: - CloudflareTunnelController

/// Manages Cloudflare Tunnel authentication, zone discovery, API provisioning, and `cloudflared` lifecycle.
@MainActor
final class CloudflareTunnelController: ObservableObject {
    enum State: Equatable, Sendable {
        case off
        case loggingIn
        case discoveringZones
        case ready
        case provisioning
        case connected(url: String, tunnelName: String, tunnelID: String)
        case failed(String)

        var activeURL: String? {
            if case .connected(let url, _, _) = self { url } else { nil }
        }
    }

    private enum DefaultsKey {
        static let enabled = "cloudflareTunnelEnabled"
        static let hostname = "cloudflareTunnelHostname"
        static let zoneID = "cloudflareTunnelZoneID"
        static let tunnelID = "cloudflareTunnelID"
        static let tunnelName = "cloudflareTunnelName"
    }

    @Published private(set) var state: State = .off
    @Published private(set) var account: CloudflareAccount?
    @Published private(set) var zones: [CloudflareZone] = []
    @Published var selectedZoneID: String {
        didSet {
            defaults.set(selectedZoneID, forKey: DefaultsKey.zoneID)
            updateDraftForSelectedZone(previousZoneID: oldValue)
        }
    }
    @Published var hostnameDraft: String = ""
    @Published private(set) var detectedCertURL: URL?
    @Published private(set) var isBinaryAvailable: Bool

    @Published private(set) var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: DefaultsKey.enabled)
        }
    }
    @Published private(set) var configuredHostname: String {
        didSet {
            defaults.set(configuredHostname, forKey: DefaultsKey.hostname)
        }
    }

    /// Notified whenever the desired public Cloudflare hostname becomes active or nil.
    var onActiveHostnameChanged: ((String?) -> Void)?

    /// The normalized hostname currently configured for public traffic when enabled.
    var activeHostname: String? {
        guard isEnabled, account != nil else { return nil }
        let normalized = FunnelPolicy.normalizedHost(configuredHostname)
        return normalized.isEmpty ? nil : normalized
    }

    let defaultTunnelName: String

    private let secretStorage: any CloudflareSecretStorage
    private let defaults: UserDefaults
    private let httpTransport: CloudflareAPIClient.HTTPTransport
    private let processRunner: any CloudflareProcessRunner
    private let containerCertURL: URL
    private let certSearchURLs: [URL]

    private var processHandle: (any CloudflareProcessHandle)?
    private var currentLoopbackPort: UInt16?
    private var connectTask: Task<Void, Never>?
    private var generation = 0
    private var tunnelStartedAt: Date?
    private var consecutiveRestarts = 0
    private var wakeObserver: (any NSObjectProtocol)?
    private var pathMonitor: NWPathMonitor?
    private var wasOnline = true

    init(
        secretStorage: any CloudflareSecretStorage = KeychainCloudflareSecretStorage(),
        defaults: UserDefaults = .standard,
        httpTransport: @escaping CloudflareAPIClient.HTTPTransport = { try await URLSession.shared.data(for: $0) },
        processRunner: any CloudflareProcessRunner = SystemCloudflareProcessRunner(),
        containerCertURL: URL = CloudflareAccount.containerCertURL(),
        certSearchURLs: [URL]? = nil,
        computerName: String? = Host.current().localizedName
    ) {
        self.secretStorage = secretStorage
        self.defaults = defaults
        self.httpTransport = httpTransport
        self.processRunner = processRunner
        self.containerCertURL = containerCertURL
        self.certSearchURLs = certSearchURLs ?? CloudflareAccount.candidateCertURLs()
        self.defaultTunnelName = Self.defaultTunnelName(computerName: computerName)

        let savedHostname = defaults.string(forKey: DefaultsKey.hostname) ?? ""
        self.isEnabled = defaults.bool(forKey: DefaultsKey.enabled)
        self.configuredHostname = savedHostname
        self.selectedZoneID = defaults.string(forKey: DefaultsKey.zoneID) ?? ""
        self.hostnameDraft = savedHostname
        self.isBinaryAvailable = processRunner.findBinary() != nil

        restoreInitialState()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnectAfterWake() }
        }
        // A tunnel that failed while the network was down starts again when it comes back.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cameBack = online && !self.wasOnline
                self.wasOnline = online
                if cameBack { self.reconnectAfterNetworkReturns() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "imcp.cloudflare.path"))
        pathMonitor = monitor
    }

    /// Whether the tunnel is meant to be up but isn't, and isn't already starting.
    private var needsReconnect: Bool {
        guard isEnabled, account != nil, processHandle == nil else { return false }
        if case .failed = state { return true }
        return false
    }

    private func reconnectAfterNetworkReturns() {
        guard needsReconnect else { return }
        log.notice("Network is back, reconnecting Cloudflare Tunnel")
        consecutiveRestarts = 0
        reconnectNow()
    }

    /// Zone discovery comes first when it never finished, since `connect` waits for it.
    private func reconnectNow() {
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            if self.zones.isEmpty {
                await self.refreshZones()
            } else if let port = self.currentLoopbackPort {
                await self.connect(localPort: port)
            }
        }
    }

    /// After discovery or provisioning failed (offline at launch, a dropped connection),
    /// tries again with the same growing delays as a tunnel that exited.
    private func retryAfterFailure() {
        guard isEnabled, account != nil, processHandle == nil else { return }
        let delay = Self.restartDelays[min(consecutiveRestarts, Self.restartDelays.count - 1)]
        consecutiveRestarts += 1
        log.notice("Retrying Cloudflare Tunnel in \(delay, privacy: .public) seconds")
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.needsReconnect else { return }
            self.reconnectNow()
        }
    }

    /// After the Mac wakes, a tunnel that failed while it slept shouldn't wait out its delay.
    private func reconnectAfterWake() {
        guard isEnabled, processHandle == nil, currentLoopbackPort != nil else { return }
        log.notice("Reconnecting Cloudflare Tunnel after wake")
        consecutiveRestarts = 0
        reconnectNow()
    }

    // MARK: Naming Helpers

    static func defaultTunnelName(computerName: String?) -> String {
        let slug = RemoteAccessServer.sanitizedHostname(computerName ?? "mac") ?? "mac"
        var name = "imcp-\(slug)"
        if name.count > 63 {
            name = String(name.prefix(63))
            while name.hasSuffix("-") { name.removeLast() }
        }
        return name
    }

    static func resolvedHostname(input: String, zoneName: String) -> String? {
        var cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.hasPrefix("https://") {
            cleaned.removeFirst("https://".count)
        } else if cleaned.hasPrefix("http://") {
            cleaned.removeFirst("http://".count)
        }
        if let slash = cleaned.firstIndex(of: "/") {
            cleaned = String(cleaned[..<slash])
        }
        cleaned = FunnelPolicy.normalizedHost(cleaned)
        let zone = FunnelPolicy.normalizedHost(zoneName)
        guard !cleaned.isEmpty, !zone.isEmpty else { return nil }
        if cleaned == zone || cleaned.hasSuffix(".\(zone)") {
            return cleaned
        }
        return "\(cleaned).\(zone)"
    }

    var selectedZone: CloudflareZone? {
        zones.first(where: { $0.id == selectedZoneID }) ?? zones.first
    }

    // MARK: Startup & Discovery

    func refreshEnvironment() {
        isBinaryAvailable = processRunner.findBinary() != nil
        detectedCertURL = CloudflareAccount.discoverLocalCertAccount(searchURLs: certSearchURLs)?.url
    }

    private func restoreInitialState() {
        refreshEnvironment()
        if let saved = try? secretStorage.load() {
            account = saved
            state = .ready
            Task { [weak self] in
                await self?.refreshZones()
            }
        } else if let discovered = CloudflareAccount.discoverLocalCertAccount(searchURLs: certSearchURLs) {
            detectedCertURL = discovered.url
            account = discovered.account
            try? secretStorage.save(discovered.account)
            state = .ready
            Task { [weak self] in
                await self?.refreshZones()
            }
        } else {
            state = .off
        }
    }

    // MARK: Authentication

    /// Launches `cloudflared tunnel login` so the user can authorize a zone in their browser.
    func logInWithBrowser() async {
        refreshEnvironment()
        state = .loggingIn
        do {
            let newAccount = try await processRunner.runBrowserLogin(origincertURL: containerCertURL)
            try saveAndActivateAccount(newAccount)
            await refreshZones()
        } catch is CancellationError {
            state = account == nil ? .off : .ready
        } catch {
            log.error("Cloudflare browser login failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Imports credentials from a `cert.pem` file chosen by the user or detected on disk.
    func importCertPEM(from url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            let parsed = try CloudflareAccount.parseCertPEM(data: data)
            try saveAndActivateAccount(parsed)
            await refreshZones()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Imports the detected local `cert.pem` file if present.
    func useDetectedCert() async {
        refreshEnvironment()
        guard let detectedCertURL else {
            state = .failed("No cert.pem file was found.")
            return
        }
        await importCertPEM(from: detectedCertURL)
    }

    /// Authenticates with either pasted `cert.pem` text or a raw Cloudflare API Token.
    func logIn(credentialInput: String) async {
        let trimmed = credentialInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .failed(CloudflareError.missingToken.localizedDescription)
            return
        }

        if trimmed.contains("-----BEGIN ") || trimmed.hasPrefix("{") {
            do {
                let parsed = try CloudflareAccount.parseCertPEM(trimmed)
                try saveAndActivateAccount(parsed)
                await refreshZones()
            } catch {
                state = .failed(error.localizedDescription)
            }
            return
        }

        // Try base64 cert.pem payload without headers first; fall back to raw API token.
        if let parsed = try? CloudflareAccount.parseCertPEM(trimmed) {
            do {
                try saveAndActivateAccount(parsed)
                await refreshZones()
            } catch {
                state = .failed(error.localizedDescription)
            }
            return
        }

        state = .discoveringZones
        let client = CloudflareAPIClient(apiToken: trimmed, transport: httpTransport)
        do {
            let discoveredZones = try await client.discoverZones()
            var accountID = discoveredZones.compactMap(\.account?.id).first
            if accountID == nil {
                accountID = try? await client.listAccounts().first?.id
            }
            guard let accountID, !accountID.isEmpty else {
                throw CloudflareError.missingAccountID
            }
            let newAccount = CloudflareAccount(
                accountID: accountID,
                zoneID: discoveredZones.first?.id,
                apiToken: trimmed
            )
            try saveAndActivateAccount(newAccount)
            applyDiscoveredZones(discoveredZones)
            state = .ready
        } catch {
            log.error("Cloudflare API token login failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    func refreshZones() async {
        guard let account else {
            zones = []
            state = .off
            return
        }
        let previousState = state
        if case .connected = previousState {
            // Keep connected status visible during a background zone refresh.
        } else {
            state = .discoveringZones
        }
        let client = CloudflareAPIClient(apiToken: account.apiToken, transport: httpTransport)
        do {
            let discovered = try await client.discoverZones(preferredZoneID: account.zoneID)
            applyDiscoveredZones(discovered)
            if case .connected = previousState {
                state = previousState
            } else {
                state = .ready
            }
            if isEnabled, let port = currentLoopbackPort, case .ready = state {
                await connect(localPort: port)
            }
        } catch {
            log.error("Cloudflare zone discovery failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
            retryAfterFailure()
        }
    }

    func logOut() {
        disconnect()
        try? secretStorage.clear()
        defaults.removeObject(forKey: DefaultsKey.hostname)
        defaults.removeObject(forKey: DefaultsKey.zoneID)
        defaults.removeObject(forKey: DefaultsKey.tunnelID)
        defaults.removeObject(forKey: DefaultsKey.tunnelName)
        account = nil
        zones = []
        selectedZoneID = ""
        configuredHostname = ""
        hostnameDraft = ""
        state = .off
    }

    // MARK: Tunnel Provisioning & Lifecycle

    /// Provisions the tunnel + DNS record for the drafted hostname and enables Cloudflare public access.
    func provisionAndConnect() async {
        guard account != nil else {
            state = .failed(CloudflareError.missingToken.localizedDescription)
            return
        }
        guard let zone = selectedZone else {
            state = .failed("Select a Cloudflare domain first.")
            return
        }
        guard let resolved = Self.resolvedHostname(input: hostnameDraft, zoneName: zone.name) else {
            state = .failed(CloudflareError.invalidHostname.localizedDescription)
            return
        }

        hostnameDraft = resolved
        let changed = configuredHostname != resolved || !isEnabled
        configuredHostname = resolved
        isEnabled = true

        if changed {
            onActiveHostnameChanged?(activeHostname)
        }
        if let port = currentLoopbackPort {
            await connect(localPort: port)
        } else {
            state = .provisioning
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            Task {
                await provisionAndConnect()
            }
        } else {
            disconnect()
        }
    }

    func disconnect() {
        generation += 1
        consecutiveRestarts = 0
        connectTask?.cancel()
        connectTask = nil
        stopProcess()
        let wasEnabled = isEnabled
        isEnabled = false
        if wasEnabled {
            onActiveHostnameChanged?(nil)
        }
        state = account == nil ? .off : .ready
    }

    /// Stops only the child `cloudflared` process without turning off the saved preference, e.g. on app quit.
    func stopRunningProcess() {
        generation += 1
        connectTask?.cancel()
        connectTask = nil
        stopProcess()
        currentLoopbackPort = nil
    }

    /// Called by `ServerController` when the shared `RemoteAccessServer` loopback listener changes state.
    func handleLoopbackPortChange(_ port: UInt16?) {
        currentLoopbackPort = port
        guard isEnabled else {
            stopProcess()
            return
        }
        guard let port else {
            generation += 1
            connectTask?.cancel()
            connectTask = nil
            stopProcess()
            state = account == nil ? .off : .ready
            return
        }
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            await self?.connect(localPort: port)
        }
    }

    func reportLoopbackFailure(_ message: String) {
        guard isEnabled else { return }
        stopProcess()
        state = .failed(message)
    }

    private func connect(localPort: UInt16) async {
        guard isEnabled, let account else { return }
        let zone = zoneForActiveHostname() ?? selectedZone
        guard let zone else {
            // Wait for zone discovery if it hasn't completed yet.
            if zones.isEmpty { return }
            state = .failed("Select a Cloudflare domain first.")
            return
        }

        let targetHost: String
        if let active = activeHostname {
            targetHost = active
        } else if let resolved = Self.resolvedHostname(input: hostnameDraft, zoneName: zone.name) {
            configuredHostname = resolved
            targetHost = resolved
        } else {
            state = .failed(CloudflareError.invalidHostname.localizedDescription)
            return
        }

        let accountID = zone.account?.id ?? account.accountID
        guard !accountID.isEmpty else {
            state = .failed(CloudflareError.missingAccountID.localizedDescription)
            return
        }

        generation += 1
        let current = generation
        stopProcess()
        state = .provisioning

        let client = CloudflareAPIClient(apiToken: account.apiToken, transport: httpTransport)
        do {
            let provisioned = try await client.provisionTunnel(
                accountID: accountID,
                zoneID: zone.id,
                hostname: targetHost,
                tunnelName: defaultTunnelName,
                localPort: localPort
            )
            guard current == generation, !Task.isCancelled, isEnabled else { return }

            defaults.set(provisioned.tunnelID, forKey: DefaultsKey.tunnelID)
            defaults.set(provisioned.tunnelName, forKey: DefaultsKey.tunnelName)

            let handle = try processRunner.startTunnel(runToken: provisioned.runToken) { [weak self] status, detail in
                Task { @MainActor [weak self] in
                    guard let self, current == self.generation, self.isEnabled else { return }
                    self.processHandle = nil
                    log.error(
                        "cloudflared exited with status \(status, privacy: .public): \(detail, privacy: .public)"
                    )
                    self.restartAfterExit(status: status, detail: detail, localPort: localPort, generation: current)
                }
            }
            processHandle = handle
            tunnelStartedAt = Date()
            let publicURL = FunnelPolicy.publicURL(host: provisioned.hostname)
            state = .connected(
                url: publicURL,
                tunnelName: provisioned.tunnelName,
                tunnelID: provisioned.tunnelID
            )
            log.notice("Cloudflare Tunnel connected at \(publicURL, privacy: .public)")
        } catch is CancellationError {
            return
        } catch {
            guard current == generation else { return }
            log.error("Cloudflare Tunnel provisioning failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
            retryAfterFailure()
        }
    }

    // MARK: Private Helpers

    private func saveAndActivateAccount(_ newAccount: CloudflareAccount) throws {
        try secretStorage.save(newAccount)
        account = newAccount
    }

    private func applyDiscoveredZones(_ discovered: [CloudflareZone]) {
        zones = discovered
        if selectedZoneID.isEmpty || !discovered.contains(where: { $0.id == selectedZoneID }) {
            if let preferred = account?.zoneID, discovered.contains(where: { $0.id == preferred }) {
                selectedZoneID = preferred
            } else if let first = discovered.first {
                selectedZoneID = first.id
            }
        }
        if hostnameDraft.isEmpty, let zone = selectedZone {
            hostnameDraft = "imcp.\(zone.name)"
            if configuredHostname.isEmpty {
                configuredHostname = hostnameDraft
            }
        }
    }

    private func updateDraftForSelectedZone(previousZoneID: String) {
        guard let newZone = zones.first(where: { $0.id == selectedZoneID }) else { return }
        if hostnameDraft.isEmpty {
            hostnameDraft = "imcp.\(newZone.name)"
            return
        }
        if let oldZone = zones.first(where: { $0.id == previousZoneID }),
            oldZone.id != newZone.id
        {
            let normalizedDraft = FunnelPolicy.normalizedHost(hostnameDraft)
            let oldSuffix = ".\(FunnelPolicy.normalizedHost(oldZone.name))"
            if normalizedDraft.hasSuffix(oldSuffix) {
                let prefix = String(normalizedDraft.dropLast(oldSuffix.count))
                hostnameDraft = "\(prefix).\(FunnelPolicy.normalizedHost(newZone.name))"
            } else if normalizedDraft == FunnelPolicy.normalizedHost(oldZone.name) {
                hostnameDraft = "imcp.\(FunnelPolicy.normalizedHost(newZone.name))"
            }
        }
    }

    private func zoneForActiveHostname() -> CloudflareZone? {
        let host = FunnelPolicy.normalizedHost(configuredHostname)
        if !host.isEmpty,
            let matched = zones.first(where: { zone in
                let zoneName = FunnelPolicy.normalizedHost(zone.name)
                return host == zoneName || host.hasSuffix(".\(zoneName)")
            })
        {
            return matched
        }
        return selectedZone
    }

    private func stopProcess() {
        processHandle?.terminate()
        processHandle = nil
    }

    /// Seconds to wait before each restart after `cloudflared` exits on its own.
    static let restartDelays: [Double] = [2, 5, 15, 30, 60]
    /// A tunnel that ran this long counts as healthy, so the next exit starts the delays over.
    static let stableSeconds: TimeInterval = 120

    /// Starts the tunnel again after `cloudflared` exited without being asked to,
    /// with growing delays that stop growing at the last one, and shows the failure only while it can't reconnect.
    private func restartAfterExit(status: Int32, detail: String, localPort: UInt16, generation current: Int) {
        if let started = tunnelStartedAt, Date().timeIntervalSince(started) >= Self.stableSeconds {
            consecutiveRestarts = 0
        }
        let attempt = consecutiveRestarts
        consecutiveRestarts += 1
        state = .failed(CloudflareError.processExited(status, detail).localizedDescription)
        // Keep trying: the last delay repeats until the tunnel stays up or someone turns it off.
        let delay = Self.restartDelays[min(attempt, Self.restartDelays.count - 1)]
        log.notice("Restarting Cloudflare Tunnel in \(delay, privacy: .public) seconds")
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.isEnabled, current == self.generation else { return }
            await self.connect(localPort: localPort)
        }
    }
}
