import OSLog
import SwiftUI
import UIKit

@main
struct HelperApp: App {
    @UIApplicationDelegateAdaptor(HelperAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            HelperView(runtime: .shared)
                .task { HelperRuntime.shared.start() }
        }
        .windowResizability(.contentSize)
    }
}

/// Starts the XPC listener when the process launches.
/// launchd starts the helper on iMCP's first XPC message, possibly in the background,
/// and the window, which used to start everything, can appear much later or not at all.
final class HelperAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Task { @MainActor in HelperRuntime.shared.start() }
        return true
    }
}

/// A compact window with the helper's status.
/// HomeKit has refused calls while the helper had no window on screen,
/// so the window is also part of how the helper works.
struct HelperView: View {
    @ObservedObject var runtime: HelperRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(runtime.status.text).textSelection(.enabled)
            } icon: {
                Image(systemName: runtime.status.symbol).foregroundStyle(runtime.status.tint)
            }
            Text("iMCP starts and stops this app. Keep the window open, behind other windows if you like.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if runtime.canRetry {
                Button("Try Again") { runtime.retry() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            // The window fits its content, so it has nothing to zoom or show in full screen.
            for scene in UIApplication.shared.connectedScenes {
                (scene as? UIWindowScene)?.sizeRestrictions?.allowsFullScreen = false
            }
        }
    }
}

@MainActor
final class HelperRuntime: ObservableObject {
    static let shared = HelperRuntime()

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
    /// Why the XPC listener stopped, which the window shows instead of the HomeKit status.
    @Published private(set) var listenerFailure: Status?
    var status: Status { listenerFailure ?? homeKitStatus }
    @Published private(set) var canRetry = false

    /// The backend that XPC calls reach.
    private let backend = HomeKitBackend()
    private var listener: HelperXPCListener?
    private var homeKitLoad: Task<Void, Never>?
    /// What `status()` over XPC reports.
    private let published = HelperPublishedStatus()

    func start() {
        if listener == nil {
            do {
                let listener = try HelperXPCListener(backend: backend, status: published)
                listener.resume()
                self.listener = listener
                listenerFailure = nil
            } catch {
                listenerFailure = .failed(error)
                canRetry = true
            }
        }
        loadHomeKit()
        bringToFront()
    }

    func retry() {
        canRetry = false
        start()
    }

    private func loadHomeKit() {
        guard homeKitLoad == nil else { return }
        homeKitLoad = Task {
            homeKitStatus = .waitingForHomeKit
            published.set(ready: false, detail: "Waiting for HomeKit access.")
            do {
                try await backend.store.ensureLoaded()
                homeKitStatus = .ready
                published.set(ready: true, detail: nil)
            } catch {
                homeKitStatus = .failed(error)
                published.set(ready: false, detail: homeErrorMessage(error))
                canRetry = true
                homeKitLoad = nil
            }
            print(homeKitStatus.text)
            fflush(stdout)
        }
    }

    /// Brings the window to the front, so a HomeKit permission prompt is visible.
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
