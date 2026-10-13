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

    /// The places where `Scripts/install-helper.sh` installs the helper, in order.
    static func installLocations(home: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/iMCP Helper.app"),
            home.appendingPathComponent("Applications/iMCP Helper.app"),
        ]
    }

    /// Whether the app at `url` declares itself as iMCP Helper.
    static func isHelper(at url: URL) -> Bool {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return info[markerKey] as? Bool == true
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
