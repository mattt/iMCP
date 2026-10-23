import CryptoKit
import Network
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct HelperApp: App {
    @StateObject private var runtime = HelperRuntime()

    var body: some Scene {
        WindowGroup {
            HelperView(runtime: runtime)
                .task { runtime.start() }
        }
        .windowResizability(.contentSize)
    }
}

/// A compact window with the helper's status and, until it is paired, the pairing code.
struct HelperView: View {
    @ObservedObject var runtime: HelperRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(runtime.status.text).textSelection(.enabled)
            } icon: {
                Image(systemName: runtime.status.symbol).foregroundStyle(runtime.status.tint)
            }
            // Show the pairing controls once a client can connect, and hide them while the listener changes.
            if runtime.isListening {
                switch runtime.pairing {
                case .code(let code): codeSection(code)
                case .paired: pairedSection
                case nil: EmptyView()
                }
            }
            if runtime.canRetry {
                Button("Try Again") { runtime.retry() }
                    .buttonStyle(.bordered)
            }
        }
        .disabled(runtime.isChanging)
        .padding(20)
        .frame(width: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func codeSection(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("To pair iMCP with iMCP Helper, enter this code in iMCP.")
                .foregroundStyle(.secondary)
            // Not selectable, so copies go through the Copy Code button's restrictions.
            Text(code)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .accessibilityLabel(code.map(String.init).joined(separator: " "))
            Text(
                "The code works once. After \(HomeHelperPairing.failedPairingLimit) wrong attempts, a new code replaces it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Button("Copy Code") {
                    // Keep the code off other devices, and off the pasteboard after two minutes.
                    UIPasteboard.general.setItems(
                        [[UTType.utf8PlainText.identifier: code]],
                        options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Button("Get New Code") { runtime.pairAgain() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var pairedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paired with iMCP. To pair again, choose Pair Again, then enter the new code in iMCP.")
                .foregroundStyle(.secondary)
            Button("Pair Again") { runtime.pairAgain() }
                .buttonStyle(.bordered)
        }
    }
}

@MainActor
final class HelperRuntime: ObservableObject {
    enum Pairing: Equatable {
        /// The helper shows this one-time code.
        case code(String)
        /// The helper has a key from iMCP.
        case paired
    }

    struct Status {
        let text: String
        let symbol: String
        let tint: Color

        static let starting = Status(text: "Starting…", symbol: "hourglass", tint: .secondary)
        static let waitingForHomeKit = Status(
            text: "Waiting for HomeKit access…",
            symbol: "house",
            tint: .secondary
        )
        static func ready(homes: Int) -> Status {
            Status(
                text: homes == 1
                    ? "HomeKit is ready. 1 home is available." : "HomeKit is ready. \(homes) homes are available.",
                symbol: "checkmark.circle.fill",
                tint: .green
            )
        }
        static func failed(_ error: Error) -> Status {
            Status(
                text: "iMCP Helper failed: \(homeErrorMessage(error))",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
    }

    @Published private(set) var homeKitStatus = Status.starting
    /// Why the listener stopped, which the window shows instead of the HomeKit status.
    @Published private(set) var listenerFailure: Status?
    var status: Status { listenerFailure ?? homeKitStatus }
    @Published private(set) var pairing: Pairing?
    /// Whether the listener is ready and advertised.
    @Published private(set) var isListening = false
    /// Whether a listener change is running.
    @Published private(set) var isChanging = false
    @Published private(set) var canRetry = false

    /// A listener change. The runtime applies one at a time, in order.
    private enum Change {
        case start
        case pairAgain
        case paired(SymmetricKey, code: String)
        case tooManyFailedPairings(code: String)
    }

    private let changes: AsyncStream<Change>.Continuation
    private let backend = HomeKitBackend()
    private let keychain = HomeHelperPairing.Keychain.helper
    private var server: HelperServer?
    private var advertisement: HelperAdvertisement?
    private var homeKit: Task<Void, Never>?

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Change.self)
        changes = continuation
        Task { [weak self] in
            for await change in stream { await self?.apply(change) }
        }
    }

    func start() { changes.yield(.start) }

    func retry() {
        canRetry = false
        changes.yield(.start)
    }

    /// Deletes the key, ends every session, and shows a new code.
    func pairAgain() {
        guard isListening, !isChanging else { return }
        isChanging = true
        changes.yield(.pairAgain)
    }

    private func apply(_ change: Change) async {
        isChanging = true
        defer { isChanging = false }
        do {
            switch change {
            case .start:
                if !isListening {
                    if let key = try keychain.read() {
                        try await listen(.key(key))
                    } else {
                        try await listen(.code(HomeHelperPairing.generateCode()))
                        bringToFront()
                    }
                }
                loadHomeKit()
            case .pairAgain:
                keychain.delete()
                try await listen(.code(HomeHelperPairing.generateCode()))
            case .paired(let key, let code):
                // Ignore a pairing with a code that the window no longer shows.
                guard pairing == .code(code) else { return }
                try keychain.save(key)
                try await listen(.key(key))
            case .tooManyFailedPairings(let code):
                guard pairing == .code(code) else { return }
                try await listen(.code(HomeHelperPairing.generateCode()))
            }
        } catch {
            isListening = false
            listenerFailure = .failed(error)
            canRetry = true
        }
    }

    /// Listens with a credential and advertises the listener.
    private func listen(_ credential: HelperServer.Credential) async throws {
        isListening = false
        let port: NWEndpoint.Port
        if let server {
            port = try await server.restart(credential: credential)
        } else {
            let server = HelperServer(backend: backend, credential: credential) { [weak self] event in
                await self?.receive(event)
            }
            self.server = server
            port = try await server.start()
        }
        advertisement?.stop()
        let advertisement = HelperAdvertisement()
        self.advertisement = advertisement
        switch credential {
        case .code(let code):
            try await advertisement.start(port: port.rawValue, pairing: true)
            pairing = .code(code)
        case .key:
            try await advertisement.start(port: port.rawValue, pairing: false)
            pairing = .paired
        }
        listenerFailure = nil
        isListening = true
    }

    private func receive(_ event: HelperServer.Event) {
        switch event {
        case .paired(let key, let code): changes.yield(.paired(key, code: code))
        case .tooManyFailedPairings(let code): changes.yield(.tooManyFailedPairings(code: code))
        }
    }

    private func loadHomeKit() {
        guard homeKit == nil else { return }
        homeKit = Task {
            homeKitStatus = .waitingForHomeKit
            do {
                try await backend.store.ensureLoaded()
                homeKitStatus = .ready(homes: backend.store.homes.count)
            } catch {
                homeKitStatus = .failed(error)
                canRetry = true
                homeKit = nil
            }
            print(homeKitStatus.text)
            fflush(stdout)
        }
    }

    /// Brings the window to the front, so the pairing code is visible.
    /// UIKit on Mac Catalyst can't activate the app, so this asks AppKit's shared application.
    private func bringToFront() {
        guard
            let application = (NSClassFromString("NSApplication") as AnyObject?)?
                .perform(NSSelectorFromString("sharedApplication"))?
                .takeUnretainedValue() as? NSObject
        else { return }
        let activate = NSSelectorFromString("activate")
        if application.responds(to: activate) { application.perform(activate) }
    }
}
