import Foundation

@preconcurrency
protocol Service {
    @ToolBuilder var tools: [Tool] { get }

    var isActivated: Bool { get async }
    func activate() async throws

    /// Whether the service's write tools are on until the person chooses in Settings.
    ///
    /// Services that had write tools before the "Allow writes" setting existed keep them on,
    /// so an update changes nothing for the people using them.
    /// A service whose write tools are new turns this off.
    /// See `ServiceWrites`.
    var writesEnabledByDefault: Bool { get }
}

extension Service {
    var isActivated: Bool {
        get async {
            return true
        }
    }

    func activate() async throws {}

    var writesEnabledByDefault: Bool { true }

    func call(
        tool name: String,
        with arguments: [String: Value],
        defaults: UserDefaults = .standard
    ) async throws -> Value? {
        for tool in tools where tool.name == name {
            if tool.isWrite, !areWritesEnabled(defaults: defaults) { throw WritesDisabledError(tool: name) }
            return try await tool.callAsFunction(arguments)
        }

        return nil
    }
}

@resultBuilder
struct ToolBuilder {
    static func buildBlock(_ tools: Tool...) -> [Tool] {
        tools
    }
}
