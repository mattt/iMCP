import Foundation

/// The per-service setting that decides whether clients can use a service's tools that change things.
///
/// A tool changes things unless it says that it only reads (`readOnlyHint` is `true`),
/// which is how MCP reads an annotation that is missing.
/// Each service that has such tools gets one "Allow writes" setting in iMCP's Settings.
/// Deleting is a write, so the same setting covers it.
/// While the setting is off, the service's write tools aren't listed to clients and calls to them are refused.
/// The per-tool switches in Settings apply on top of it.
enum ServiceWrites {
    /// The `UserDefaults` key of a service's setting.
    static func settingKey(forService serviceID: String) -> String {
        "writesEnabled.\(serviceID)"
    }

    /// The Notes-only setting that this one replaces.
    static let legacyNotesKey = "notesWritesEnabled"
    static let notesServiceID = "NotesService"

    /// Whether a service's write tools are on, using `defaultValue` until the person chooses.
    static func isEnabled(
        serviceID: String,
        defaultValue: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: settingKey(forService: serviceID)) as? Bool ?? defaultValue
    }

    static func setEnabled(
        _ isEnabled: Bool,
        serviceID: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(isEnabled, forKey: settingKey(forService: serviceID))
    }

    /// Moves the Notes-only setting to the Notes service's own setting.
    ///
    /// A choice made under the new key is kept, and the old key is removed either way.
    static func migrateLegacySettings(defaults: UserDefaults = .standard) {
        guard let legacy = defaults.object(forKey: legacyNotesKey) as? Bool else { return }
        let key = settingKey(forService: notesServiceID)
        if defaults.object(forKey: key) == nil {
            defaults.set(legacy, forKey: key)
        }
        defaults.removeObject(forKey: legacyNotesKey)
    }
}

extension Tool {
    /// Whether the tool can change anything, rather than only read.
    var isWrite: Bool { annotations.readOnlyHint != true }
}

extension Service {
    /// The name that identifies the service in settings.
    var serviceID: String { String(describing: type(of: self)) }

    /// The tools of the service that change things.
    var writeToolNames: Set<String> {
        Set(tools.filter(\.isWrite).map(\.name))
    }

    /// Whether the service has a write tool, and so has an "Allow writes" setting.
    var hasWriteTools: Bool {
        tools.contains(where: \.isWrite)
    }

    func areWritesEnabled(defaults: UserDefaults = .standard) -> Bool {
        ServiceWrites.isEnabled(
            serviceID: serviceID,
            defaultValue: writesEnabledByDefault,
            defaults: defaults
        )
    }

    /// The tools that clients are offered: all of them, or only those that read while writes are off.
    func listedTools(defaults: UserDefaults = .standard) -> [Tool] {
        let all = tools
        if areWritesEnabled(defaults: defaults) { return all }
        return all.filter { !$0.isWrite }
    }

    func isToolListed(_ name: String, defaults: UserDefaults = .standard) -> Bool {
        listedTools(defaults: defaults).contains { $0.name == name }
    }
}

/// A write tool was called while its service's "Allow writes" setting is off.
struct WritesDisabledError: LocalizedError, CustomStringConvertible, Equatable {
    let tool: String

    var description: String {
        "\(tool) changes things, and \"Allow writes\" is off for its service in iMCP's settings. Nothing was changed. Ask the person to turn it on in the service's settings if they want this."
    }

    var errorDescription: String? { description }
}
