import Network
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct HelperApp: App {
    @StateObject private var runtime = HelperRuntime()

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 16) {
                Text("iMCP Helper").font(.title)
                Text(runtime.status).textSelection(.enabled)
                // Show the code once a client can use it, and hide New Code while the listener changes.
                if let code = runtime.pairingCode, runtime.isListening {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pairing code").font(.headline)
                        // Not selectable, so copies go through the Copy button's restrictions.
                        Text(code).font(.title2.monospaced())
                        Text("Enter this code in iMCP to turn on Home. A new code disconnects iMCP until you enter it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Copy") {
                                // Keep the code off other devices, and off the pasteboard after two minutes.
                                UIPasteboard.general.setItems(
                                    [[UTType.utf8PlainText.identifier: code]],
                                    options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
                                )
                            }
                            Button("New Code") { Task { await runtime.replacePairingCode() } }
                                .disabled(runtime.isReplacingCode)
                        }
                    }
                }
                HStack {
                    if runtime.canRetry {
                        Button("Retry") { Task { await runtime.start() } }
                            .disabled(runtime.isReplacingCode)
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
    /// Whether the listener is ready and advertised.
    @Published private(set) var isListening = false
    @Published private(set) var isReplacingCode = false
    private let backend = HomeKitBackend()
    private let keychain = HomeHelperPairing.Keychain(service: "iMCP Helper pairing code")
    private var server: HelperServer?
    private var advertisement: HelperAdvertisement?
    private var started = false

    func start() async {
        guard !started, !isReplacingCode else { return }
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
            isListening = false
            try await advertise(port: server.start())
            isListening = true
            status = "Waiting for HomeKit access…"
            try await backend.store.ensureLoaded()
            status = "HomeKit is ready. \(backend.store.homes.count) homes available."
        } catch {
            fail(error)
        }
    }

    /// Makes a new pairing code and ends the sessions that use the old one.
    func replacePairingCode() async {
        guard isListening, !isReplacingCode, let server else { return }
        isReplacingCode = true
        isListening = false
        defer { isReplacingCode = false }
        do {
            let code = try HomeHelperPairing.generateCode()
            try keychain.save(code)
            pairingCode = code
            try await advertise(port: server.restart(code: code))
            isListening = true
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
