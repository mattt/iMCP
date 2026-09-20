import Sparkle
import SwiftUI

@main
struct App: SwiftUI.App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openSettings) private var openSettings
    @StateObject private var serverController = ServerController()
    @AppStorage("isEnabled") private var isEnabled = true
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    // `startingUpdater: true` makes this the sole owner of update checking for
    // the app's lifetime. Without it (or without ever constructing an updater
    // at all), the SUFeedURL / SUPublicEDKey keys in Info.plist are inert and
    // installs never learn about newer releases, no matter how long they run.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        // The binding lets removal hide the item without terminating the server.
        MenuBarExtra(
            "iMCP",
            image: #"MenuIcon-\#(isEnabled ? "On" : "Off")"#,
            isInserted: $showMenuBarExtra
        ) {
            ContentView(
                serverManager: serverController,
                isEnabled: $isEnabled,
                updater: updaterController.updater
            )
        }
        .menuBarExtraStyle(.window)
        .onChange(of: appDelegate.shouldOpenSettings) { _, shouldOpenSettings in
            guard shouldOpenSettings else { return }
            appDelegate.shouldOpenSettings = false
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Settings {
            SettingsView(serverController: serverController)
        }

        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}

@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shouldOpenSettings = false

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Reopening the app must work even when the menu bar item is absent.
        shouldOpenSettings = true
        return false
    }
}
