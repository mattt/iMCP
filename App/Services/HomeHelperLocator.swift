import Foundation

/// Chooses the iMCP Helper app that serves the Home tools.
///
/// Apple doesn't allow the HomeKit entitlement in Developer ID builds,
/// so release builds of iMCP don't include the helper;
/// developers build and sign it with `Scripts/install-helper.sh`.
/// Self-built helpers have their own bundle IDs,
/// so an app counts as the helper only if its Info.plist
/// sets `iMCPHelper` to true.
enum HomeHelperLocator {
    static let markerKey = "iMCPHelper"
    static let defaultBundleIdentifier = "co.dododo.iMCP.Helper"

    /// Where iMCP looks for the helper without asking.
    /// `Scripts/install-helper.sh` installs it in `/Applications` by default.
    /// The sandbox can't read other folders, such as `~/Applications`,
    /// until the user chooses the helper in an open panel.
    static let installLocations = [URL(fileURLWithPath: "/Applications/iMCP Helper.app")]

    /// Whether the app at `url` declares itself as iMCP Helper.
    static func isHelper(at url: URL) -> Bool {
        info(at: url)?[markerKey] as? Bool == true
    }

    /// The protocol version that the helper at `url` declares,
    /// or nil for a helper from before pairing.
    /// Throws if its Info.plist can't be read,
    /// which the sandbox can cause outside `/Applications`.
    static func protocolVersion(at url: URL) throws -> Int? {
        guard let info = info(at: url) else {
            throw HomeError(
                "iMCP can't read the Info.plist of iMCP Helper at \(url.path). Choose the helper again in Settings > Home, then retry."
            )
        }
        return info[HomeHelperPairing.protocolVersionInfoKey] as? Int
    }

    private static func info(at url: URL) -> [String: Any]? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Whether a running app is the helper that iMCP should use.
    /// When a helper is resolved, only an app at its path matches,
    /// without reading its Info.plist, which the sandbox may deny outside `/Applications`;
    /// another build that is running elsewhere doesn't stand in for it.
    /// With no resolved helper, an app named iMCP Helper matches if it has the marker,
    /// so other running apps' Info.plist files aren't read.
    static func isRunningHelper(
        bundleURL: URL?,
        localizedName: String?,
        helper: URL?,
        isHelper: (URL) -> Bool
    ) -> Bool {
        guard let bundleURL else { return false }
        if let helper {
            return bundleURL.standardizedFileURL.path == helper.standardizedFileURL.path
        }
        return localizedName == "iMCP Helper" && isHelper(bundleURL)
    }

    /// The first candidate that is a helper:
    /// the user's choice, then the install locations,
    /// then the app registered for the default bundle ID,
    /// then the copy embedded in a development build.
    static func resolve(
        chosen: URL?,
        installed: [URL],
        registered: URL?,
        embedded: URL?,
        isHelper: (URL) -> Bool
    ) -> URL? {
        let candidates = [chosen] + installed.map(Optional.some) + [registered, embedded]
        return candidates.compactMap { $0 }.first(where: isHelper)
    }
}
