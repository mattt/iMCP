import Network
import SwiftUI
import UIKit

@main
struct HelperApp: App {
    @StateObject private var runtime = HelperRuntime()

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 16) {
                Text("iMCP Helper").font(.title)
                Text(runtime.status).textSelection(.enabled)
                if let code = runtime.pairingCode {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pairing code").font(.headline)
                        Text(code).font(.title2.monospaced()).textSelection(.enabled)
                        Text("Enter this code in iMCP to turn on Home. A new code disconnects iMCP until you enter it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Copy") { UIPasteboard.general.string = code }
                            Button("New Code") { Task { await runtime.replacePairingCode() } }
                        }
                    }
                }
                HStack {
                    if runtime.canRetry {
                        Button("Retry") { Task { await runtime.start() } }
                    }
                    Button("Quit") { exit(0) }
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
    @Published private(set) var pairingCode: String?
    private let backend = HomeKitBackend()
    private let keychain = HomeHelperPairing.Keychain(service: "iMCP Helper pairing code")
    private var server: HelperServer?
    private var advertisement: HelperAdvertisement?
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
            let code = try pairingCode ?? storedOrNewPairingCode()
            pairingCode = code
            let server = self.server ?? HelperServer(backend: backend, code: code)
            self.server = server
            status = "Starting the local connection…"
            try await advertise(port: server.start())
            status = "Waiting for HomeKit access…"
            try await backend.store.ensureLoaded()
            status = "HomeKit is ready. \(backend.store.homes.count) homes available."
        } catch {
            fail(error)
        }
    }

    /// Makes a new pairing code and ends the sessions that use the old one.
    func replacePairingCode() async {
        do {
            let code = try HomeHelperPairing.generateCode()
            try keychain.save(code)
            pairingCode = code
            guard let server else { return }
            try await advertise(port: server.restart(code: code))
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        status = "iMCP Helper failed: \(homeErrorMessage(error))"
        started = false
        canRetry = true
    }

    private func storedOrNewPairingCode() throws -> String {
        if let code = try keychain.read(), HomeHelperPairing.normalize(code) != nil { return code }
        let code = try HomeHelperPairing.generateCode()
        try keychain.save(code)
        return code
    }

    /// Advertises the listener's port, replacing any earlier advertisement.
    private func advertise(port: NWEndpoint.Port) async throws {
        advertisement?.stop()
        let advertisement = HelperAdvertisement()
        self.advertisement = advertisement
        try await advertisement.start(port: port.rawValue)
    }
}
