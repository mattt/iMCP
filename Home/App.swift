import Network
import SwiftUI

@main
struct HomeApp: App {
    @StateObject private var runtime = HomeRuntime()

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 16) {
                Text("iMCP Home").font(.title)
                Text(runtime.status).textSelection(.enabled)
                if runtime.canRetry {
                    Button("Retry") { Task { await runtime.start() } }
                }
            }
            .padding(24)
            .frame(minWidth: 420, minHeight: 160)
            .task { await runtime.start() }
        }
    }
}

@MainActor
final class HomeRuntime: ObservableObject {
    @Published private(set) var canRetry = false
    @Published private(set) var status = "Starting HomeKit…"
    private let backend = HomeKitBackend()
    private var server: HelperServer?
    private var parentMonitor: DispatchSourceProcess?
    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        canRetry = false
        do {
            try monitorParent()
            let server = try self.server ?? HelperServer(backend: backend, port: requestedPort())
            self.server = server
            status = "Starting the local connection…"
            try await server.start()
            status = "Waiting for HomeKit access…"
            try await backend.store.ensureLoaded()
            status = "HomeKit is ready. \(backend.store.homes.count) homes available."
        } catch {
            status = "Home helper failed: \(homeErrorMessage(error))"
            started = false
            canRetry = true
        }
        print(status)
        fflush(stdout)
    }

    private func requestedPort() throws -> NWEndpoint.Port? {
        guard let index = CommandLine.arguments.firstIndex(of: "--port") else { return nil }
        guard CommandLine.arguments.indices.contains(index + 1),
            let number = UInt16(CommandLine.arguments[index + 1]), number > 0,
            let port = NWEndpoint.Port(rawValue: number)
        else {
            throw HomeError("--port requires a TCP port between 1 and 65535.")
        }
        return port
    }

    private func monitorParent() throws {
        guard parentMonitor == nil else { return }
        guard let index = CommandLine.arguments.firstIndex(of: "--parent-pid") else { return }
        guard CommandLine.arguments.indices.contains(index + 1),
            let pid = Int32(CommandLine.arguments[index + 1]), pid > 1
        else {
            throw HomeError("--parent-pid requires a valid process ID.")
        }
        #if targetEnvironment(macCatalyst)
            let monitor = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            monitor.setEventHandler { exit(0) }
            parentMonitor = monitor
            monitor.resume()
            // Close the race where the parent exits before the source is installed.
            if kill(pid, 0) == -1 && errno == ESRCH { exit(0) }
        #endif
    }
}
