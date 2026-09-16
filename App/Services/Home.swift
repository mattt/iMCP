final class HomeService: Service {
    static let shared = HomeService()
    private let backend = HomeProxyBackend()
    var tools: [Tool] { return HomeTools.tools(backend: backend) }
    var isActivated: Bool { get async { await backend.isActivated } }
    func activate() async throws { try await backend.activate() }
}
