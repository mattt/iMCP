@preconcurrency
protocol Service {
    @ToolBuilder var tools: [Tool] { get }

    var isActivated: Bool { get async }
    func activate() async throws

    /// Whether clients are offered a tool of the service, which the service's own setting can withhold.
    ///
    /// A tool that isn't listed is still one of `tools`,
    /// so that a client that remembers it gets the service's reason for refusing it.
    func isToolListed(_ name: String) -> Bool
}

extension Service {
    var isActivated: Bool {
        get async {
            return true
        }
    }

    func activate() async throws {}

    func isToolListed(_ name: String) -> Bool { true }

    func call(tool name: String, with arguments: [String: Value]) async throws -> Value? {
        for tool in tools where tool.name == name {
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
