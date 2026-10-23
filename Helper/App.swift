import Network
import OSLog
import SwiftUI

@main
struct HelperApp: App {
    @StateObject private var runtime = HelperRuntime()

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 16) {
                Text("iMCP Helper").font(.title)
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
final class HelperRuntime: ObservableObject {
    @Published private(set) var canRetry = false
    @Published private(set) var status = "Starting HomeKit…"
    private let backend = HomeKitBackend()
    private let log = Logger.service("helper")
    private var server: HelperServer?
    private var parentMonitor: DispatchSourceProcess?
    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        canRetry = false
        defer {
            print(status)
            fflush(stdout)
        }
        do {
            try monitorParent()
            // iMCP passes the port and a new secret in the environment.
            // Without the secret, no client can prove that iMCP launched this helper.
            let environment = ProcessInfo.processInfo.environment
            guard let port = try requestedPort(environment),
                let secret = environment[HomeHelperSecret.secretEnvironmentKey], !secret.isEmpty
            else {
                status =
                    "iMCP Helper accepts connections only when iMCP launches it. Quit iMCP Helper, then turn Home on in iMCP."
                return
            }
            let server = self.server ?? HelperServer(backend: backend, port: port, secret: secret)
            self.server = server
            status = "Starting the local connection…"
            do { try await server.start() } catch {
                // Another process may hold the port and have received iMCP's secret.
                // Exit instead of listening later with that secret,
                // so iMCP launches a new helper with a new port and secret.
                log.error("iMCP Helper couldn't listen on its port: \(homeErrorMessage(error), privacy: .public)")
                exit(1)
            }
            status = "Waiting for HomeKit access…"
            try await backend.store.ensureLoaded()
            status = "HomeKit is ready. \(backend.store.homes.count) homes available."
        } catch {
            status = "iMCP Helper failed: \(homeErrorMessage(error))"
            started = false
            canRetry = true
        }
    }

    private func requestedPort(_ environment: [String: String]) throws -> NWEndpoint.Port? {
        guard let value = environment[HomeHelperSecret.portEnvironmentKey] else { return nil }
        guard let number = UInt16(value), number > 0, let port = NWEndpoint.Port(rawValue: number) else {
            throw HomeError("\(HomeHelperSecret.portEnvironmentKey) requires a TCP port between 1 and 65535.")
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
