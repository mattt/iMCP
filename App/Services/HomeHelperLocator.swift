import Foundation
import ServiceManagement

/// Finds the iMCP Helper that goes with this iMCP and says what state its launch agent is in.
///
/// Apple doesn't allow the HomeKit entitlement in Developer ID builds,
/// so release builds of iMCP without a HomeKit-capable signature don't embed the helper.
/// A build that embeds it carries the helper in `Contents/Helpers`
/// and a launch agent plist in `Contents/Library/LaunchAgents`,
/// which iMCP registers with `SMAppService`.
enum HomeHelperLocator {
    /// Where the agent stands, as Settings shows it.
    enum State: Equatable, Sendable {
        /// This build of iMCP has no helper, or no agent plist for it.
        case notBundled
        /// The helper is there, and iMCP hasn't registered it.
        case notRegistered
        /// macOS wants the user to allow the helper in System Settings > General > Login Items & Extensions.
        case needsApproval
        /// The agent is registered. launchd starts the helper when iMCP connects.
        case registered
    }

    /// The embedded helper's location inside `bundleURL`.
    static func embeddedHelperURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(HomeHelperIdentity.embeddedHelperRelativePath, isDirectory: true)
    }

    /// The agent plist's location inside `bundleURL`.
    static func agentPlistURL(in bundleURL: URL, appBundleIdentifier: String) -> URL {
        bundleURL.appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(HomeHelperIdentity.agentPlistName(appBundleIdentifier: appBundleIdentifier))
    }

    /// The Info.plist of the app at `url`.
    private static func info(at url: URL) -> [String: Any]? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Whether the app at `url` declares itself as iMCP Helper.
    static func isHelper(at url: URL) -> Bool {
        info(at: url)?[HomeHelperIdentity.markerKey] as? Bool == true
    }

    /// The signing identifier that iMCP requires of the helper: the identifier its Info.plist declares.
    static func helperBundleIdentifier(at url: URL) -> String? {
        info(at: url)?["CFBundleIdentifier"] as? String
    }

    /// Maps what is bundled and what `SMAppService` reports to a state.
    /// An agent that was never registered reports `.notFound` even though its plist is in the bundle
    /// (seen on macOS 27), so whether the build carries the plist decides between the two.
    static func state(isBundled: Bool, status: SMAppService.Status) -> State {
        guard isBundled else { return .notBundled }
        switch status {
        case .enabled: return .registered
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    /// Whether the build carries the helper and its agent plist.
    static func isBundled(in bundleURL: URL, appBundleIdentifier: String) -> Bool {
        let fileManager = FileManager.default
        return isHelper(at: embeddedHelperURL(in: bundleURL))
            && fileManager.fileExists(
                atPath: agentPlistURL(in: bundleURL, appBundleIdentifier: appBundleIdentifier).path
            )
    }
}
