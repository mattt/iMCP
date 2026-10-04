@preconcurrency
protocol Service {
    @ToolBuilder var tools: [Tool] { get }

    var isActivated: Bool { get async }
    func activate() async throws
}

extension Service {
    var isActivated: Bool {
        get async {
            return true
        }
    }

    func activate() async throws {}

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
