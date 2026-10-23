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
    @State private var isConfirmingPairAgain = false

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
        .frame(width: 380, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            // The window fits its content, so it has nothing to zoom or show in full screen.
            for scene in UIApplication.shared.connectedScenes {
                (scene as? UIWindowScene)?.sizeRestrictions?.allowsFullScreen = false
            }
        }
        .alert("Pair iMCP again?", isPresented: $isConfirmingPairAgain) {
            Button("Pair Again", role: .destructive) { runtime.pairAgain() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("iMCP can't use Home until you enter the new code.")
        }
    }

    private func codeSection(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter this code in iMCP to pair.")
            // Not selectable, so copies go through the Copy Code button's restrictions.
            Text(code)
                .font(.largeTitle.monospaced().weight(.semibold))
                .accessibilityLabel(Self.spokenCode(code))
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Copy the code.")
                Text(
                    runtime.canOpenIMCP
                        ? "2. Open the pairing window in iMCP."
                        : "2. In iMCP, open Settings > Services > Home, and click Pair…"
                )
                .fixedSize(horizontal: false, vertical: true)
                Text("3. Paste the code, then click Pair.")
            }
            Text(
                "This code works once. After \(HomeHelperPairing.failedPairingLimit) wrong codes, iMCP Helper shows a new one."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Get New Code") { runtime.pairAgain() }
                    .buttonStyle(.bordered)
                Spacer()
                if runtime.canOpenIMCP {
                    Button("Open iMCP…") { runtime.openIMCP() }
                        .buttonStyle(.bordered)
                }
                Button("Copy Code") {
                    // Keep the code off other devices, and off the pasteboard after two minutes.
                    UIPasteboard.general.setItems(
                        [[UTType.utf8PlainText.identifier: code]],
                        options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { runtime.findIMCP() }
    }

    private var pairedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Paired with iMCP.")
            } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
            Button("Pair Again…") { isConfirmingPairAgain = true }
                .buttonStyle(.bordered)
        }
    }

    /// The code as VoiceOver reads it: each group's characters, with a pause between the groups.
    static func spokenCode(_ code: String) -> String {
        code.split(separator: "-").map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", ")
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
        static let ready = Status(text: "HomeKit is ready.", symbol: "checkmark.circle.fill", tint: .green)
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
    /// Whether the window can open iMCP's pairing window.
    @Published private(set) var canOpenIMCP = false

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
    /// The change that failed, which Try Again repeats.
    private var failedChange: Change?

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
        changes.yield(failedChange ?? .start)
        failedChange = nil
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
                try await showNewCode()
            case .paired(let key, let code):
                // Ignore a pairing with a code that the window no longer shows.
                // `storeKey(_:code:)` already saved the key.
                guard pairing == .code(code) else { return }
                try await listen(.key(key))
            case .tooManyFailedPairings(let code):
                guard pairing == .code(code) else { return }
                try await showNewCode()
            }
        } catch {
            isListening = false
            listenerFailure = .failed(error)
            // A replacement whose code check passed is retried without the check,
            // which fails now that the code is cleared.
            if case .tooManyFailedPairings = change {
                failedChange = .pairAgain
            } else {
                failedChange = change
            }
            canRetry = true
        }
    }

    /// Replaces the code or key with a new code.
    /// Clears the shown code first, so `storeKey(_:code:)` refuses a key from a pairing with the old code,
    /// then deletes any key that such a pairing stored before.
    private func showNewCode() async throws {
        pairing = nil
        isListening = false
        do {
            try keychain.delete()
        } catch {
            // Don't show a new code while the old key would still work after a relaunch.
            await server?.stop()
            throw error
        }
        try await listen(.code(HomeHelperPairing.generateCode()))
    }

    /// Saves a key from pairing, if the window still shows the code that it came with.
    private func storeKey(_ key: SymmetricKey, code: String) throws {
        guard pairing == .code(code) else { throw HomeError("The pairing code was replaced.") }
        try keychain.save(key)
    }

    /// Listens with a credential and advertises the listener.
    private func listen(_ credential: HelperServer.Credential) async throws {
        isListening = false
        let port: NWEndpoint.Port
        if let server {
            port = try await server.restart(credential: credential)
        } else {
            let server = HelperServer(
                backend: backend,
                credential: credential,
                storeKey: { [weak self] key, code in
                    guard let self else { throw HomeError("iMCP Helper stopped.") }
                    try await self.storeKey(key, code: code)
                },
                onEvent: { [weak self] event in await self?.receive(event) }
            )
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
                homeKitStatus = .ready
            } catch {
                homeKitStatus = .failed(error)
                canRetry = true
                homeKit = nil
            }
            print(homeKitStatus.text)
            fflush(stdout)
        }
    }

    /// Finds iMCP by its bundle identifier.
    func findIMCP() {
        canOpenIMCP = Self.iMCPURL() != nil
    }

    /// Opens iMCP's pairing window.
    /// Opens the URL with iMCP itself, found by its bundle identifier,
    /// not with whichever app claims the scheme,
    /// so another app can't show a fake pairing window and capture the code.
    /// UIKit on Mac Catalyst can't do this, so it uses AppKit's shared workspace.
    func openIMCP() {
        guard
            let workspace = Self.workspace,
            let application = Self.iMCPURL(),
            let configurationClass = NSClassFromString("NSWorkspaceOpenConfiguration") as? NSObject.Type
        else {
            canOpenIMCP = false
            return
        }
        let open = NSSelectorFromString("openURLs:withApplicationAtURL:configuration:completionHandler:")
        guard workspace.responds(to: open) else {
            canOpenIMCP = false
            return
        }
        // With cooperative activation, iMCP comes forward only if the helper yields to it.
        if let shared = Self.sharedApplication {
            if let running = Self.runningIMCP() {
                shared.perform(NSSelectorFromString("yieldActivationToApplication:"), with: running)
            } else {
                shared.perform(
                    NSSelectorFromString("yieldActivationToApplicationWithBundleIdentifier:"),
                    with: HomeHelperPairing.appBundleIdentifier
                )
            }
        }
        typealias Open = @convention(c) (NSObject, Selector, NSArray, NSURL, NSObject, AnyObject?) -> Void
        unsafeBitCast(workspace.method(for: open), to: Open.self)(
            workspace,
            open,
            [HomeHelperPairing.appPairingURL] as NSArray,
            application as NSURL,
            configurationClass.init(),
            nil
        )
    }

    private static var sharedApplication: NSObject? {
        (NSClassFromString("NSApplication") as AnyObject?)?
            .perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? NSObject
    }

    private static var workspace: NSObject? {
        (NSClassFromString("NSWorkspace") as AnyObject?)?
            .perform(NSSelectorFromString("sharedWorkspace"))?
            .takeUnretainedValue() as? NSObject
    }

    /// The running iMCP, if any.
    private static func runningIMCP() -> NSObject? {
        let applications =
            (NSClassFromString("NSRunningApplication") as AnyObject?)?
            .perform(
                NSSelectorFromString("runningApplicationsWithBundleIdentifier:"),
                with: HomeHelperPairing.appBundleIdentifier
            )?
            .takeUnretainedValue() as? [NSObject]
        return applications?.first
    }

    /// The copy of iMCP to open: the running one, or else the one that LaunchServices finds,
    /// but only if it can open the pairing URL.
    /// An older iMCP doesn't declare the scheme, and LaunchServices refuses to open the URL with it.
    private static func iMCPURL() -> URL? {
        guard let workspace else { return nil }
        let running = runningIMCP()?.perform(NSSelectorFromString("bundleURL"))?.takeUnretainedValue() as? URL
        let installed =
            workspace.perform(
                NSSelectorFromString("URLForApplicationWithBundleIdentifier:"),
                with: HomeHelperPairing.appBundleIdentifier
            )?
            .takeUnretainedValue() as? URL
        guard let candidate = running ?? installed else { return nil }
        let handlers =
            workspace.perform(
                NSSelectorFromString("URLsForApplicationsToOpenURL:"),
                with: HomeHelperPairing.appPairingURL
            )?
            .takeUnretainedValue() as? [URL] ?? []
        guard handlers.contains(where: { $0.standardizedFileURL == candidate.standardizedFileURL }) else { return nil }
        return candidate
    }

    /// Brings the window to the front, so the pairing code is visible.
    /// UIKit on Mac Catalyst can't activate the app, so this asks AppKit's shared application.
    private func bringToFront() {
        guard let application = Self.sharedApplication else { return }
        let activate = NSSelectorFromString("activate")
        if application.responds(to: activate) { application.perform(activate) }
    }
}
