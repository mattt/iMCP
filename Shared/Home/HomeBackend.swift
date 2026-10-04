protocol HomeBackend: Sendable {
    func call(_ tool: String, _ input: [String: Value]) async throws -> Value
}
