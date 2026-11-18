import Foundation
import MCP
import Ontology
import Security

/// The XPC interface that iMCP Helper exports to iMCP.
///
/// The helper is a per-user launchd agent that iMCP registers with `SMAppService`.
/// It owns HomeKit, which native macOS apps can't use.
/// Each call carries JSON in `Data`, so the interface stays two methods
/// however many Home tools there are, and the tool definitions stay in `HomeTools`.
/// Both ends validate the other's code signature, so no pairing code or shared key exists.
@objc(HomeHelperXPC)
protocol HomeHelperXPC {
    /// Replies with a JSON-encoded `HomeXPCStatus`.
    func status(reply: @escaping @Sendable (Data) -> Void)
    /// Takes a JSON-encoded `HomeXPCRequest` and replies with a JSON-encoded `HomeXPCResponse`.
    /// A failed tool call is a response with `error`, not an XPC error,
    /// so an XPC error always means that the connection failed.
    func callTool(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

struct HomeXPCRequest: Codable, Equatable, Sendable {
    var tool: String
    var arguments: [String: Value]
}

struct HomeXPCResponse: Codable, Equatable, Sendable {
    /// The tool's result as JSON text.
    var result: String?
    /// The error message when the call failed.
    var error: String?

    static func success(_ result: String) -> Self { .init(result: result, error: nil) }
    static func failure(_ message: String) -> Self { .init(result: nil, error: message) }
}

struct HomeXPCStatus: Codable, Equatable, Sendable {
    var protocolVersion: Int
    /// Whether HomeKit finished loading its homes.
    var homeKitReady: Bool
    /// Why HomeKit isn't ready, or whether it is still loading.
    var detail: String?
}

/// Names, versions, and code signing requirements that iMCP and iMCP Helper agree on.
/// Everything derives from the app's bundle identifier,
/// so a build with its own identifiers finds its own helper and not the upstream one.
enum HomeHelperIdentity {
    /// The version of the XPC interface. The helper reports it in its status.
    static let protocolVersion = 4
    /// The Info.plist key that marks an app as iMCP Helper.
    static let markerKey = "iMCPHelper"

    /// The bundle identifier of iMCP, which the helper uses when it can't tell otherwise.
    static let defaultAppBundleIdentifier = "co.dododo.iMCP"

    /// Where a build of iMCP embeds the helper, relative to the app bundle.
    static let embeddedHelperRelativePath = "Contents/Helpers/iMCP Helper.app"

    /// The bundle identifier of the iMCP that goes with a helper.
    /// Each build names its helper after its app, such as `co.dododo.iMCP` and `co.dododo.iMCP.Helper`.
    static func appBundleIdentifier(helperBundleIdentifier: String?) -> String {
        guard let helperBundleIdentifier else { return defaultAppBundleIdentifier }
        let suffix = ".helper"
        guard helperBundleIdentifier.count > suffix.count,
            helperBundleIdentifier.lowercased().hasSuffix(suffix)
        else { return defaultAppBundleIdentifier }
        return String(helperBundleIdentifier.dropLast(suffix.count))
    }

    /// The Mach service that the helper's launchd agent registers.
    static func machServiceName(appBundleIdentifier: String) -> String { appBundleIdentifier + ".home-xpc" }

    /// The agent's launchd label.
    static func agentLabel(appBundleIdentifier: String) -> String { appBundleIdentifier + ".home-helper" }

    /// The file name of the agent's plist in `Contents/Library/LaunchAgents`.
    static func agentPlistName(appBundleIdentifier: String) -> String {
        agentLabel(appBundleIdentifier: appBundleIdentifier) + ".plist"
    }

    // MARK: - Code signing

    /// A signing identifier that is safe to put between quotes in a requirement.
    static func isValidIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty
            && identifier.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
            }
    }

    /// Team identifiers are ten uppercase letters and digits.
    static func isValidTeamIdentifier(_ team: String) -> Bool {
        team.count == 10 && team.unicodeScalars.allSatisfy { ("A" ... "Z").contains($0) || ("0" ... "9").contains($0) }
    }

    /// The requirement for the process on the other end: signed by Apple-issued certificates of `team`,
    /// with exactly the signing identifier `identifier`.
    /// Returns nil unless both are well formed, so a caller can't be tricked into a looser requirement.
    static func requirement(identifier: String, team: String) -> String? {
        guard isValidIdentifier(identifier), isValidTeamIdentifier(team) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// What iMCP requires of the helper.
    static func helperRequirement(helperBundleIdentifier: String, team: String) -> String? {
        requirement(identifier: helperBundleIdentifier, team: team)
    }

    /// What the helper requires of a client: iMCP, signed by the helper's own team.
    static func clientRequirement(helperBundleIdentifier: String, team: String) -> String? {
        requirement(identifier: appBundleIdentifier(helperBundleIdentifier: helperBundleIdentifier), team: team)
    }

    /// The team identifier that signed this process, or nil when it is unsigned or ad hoc signed.
    static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let dictionary = information as? [String: Any]
        else { return nil }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return team.flatMap { isValidTeamIdentifier($0) ? $0 : nil }
    }
}

/// Runs a `HomeXPCRequest` against the Home tools, as the helper does for each XPC call.
struct HomeToolDispatcher: Sendable {
    let backend: any HomeBackend

    func perform(_ data: Data) async -> HomeXPCResponse {
        do {
            let request = try JSONDecoder().decode(HomeXPCRequest.self, from: data)
            let tools = HomeTools.tools(backend: backend)
            guard let tool = tools.first(where: { $0.name == request.tool }) else {
                throw HomeError("Unknown Home tool: \(request.tool)")
            }
            try HomeInput.validate(request.arguments, schema: tool.inputSchema)
            let value = try await tool.callAsFunction(request.arguments)
            let encoder = JSONEncoder()
            encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] = TimeZone.current
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return .success(String(decoding: try encoder.encode(value), as: UTF8.self))
        } catch {
            return .failure("\(error)")
        }
    }
}
