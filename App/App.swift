import Sparkle
import SwiftUI

@main
struct App: SwiftUI.App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openSettings) private var openSettings
    @StateObject private var serverController = ServerController()
    @AppStorage("isEnabled") private var isEnabled = true
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    // `startingUpdater: true` makes this the sole owner of update checking
    // for the app's lifetime.
    // Without it (or without ever constructing an updater at all),
    // the SUFeedURL / SUPublicEDKey keys in Info.plist are inert
    // and installs never learn about newer releases,
    // no matter how long they run.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private func installMenuBar() {
        MenuBarController.shared.install(
            serverController: serverController,
            updater: updaterController.updater,
            openSettings: { [appDelegate] in appDelegate.shouldOpenSettings = true }
        )
    }

    var body: some Scene {
        @Bindable var appDelegate = appDelegate

        // The menu bar item is `MenuBarController`'s status item, because the system draws a `MenuBarExtra`
        // window with rounder corners than a native menu and an app can't change that. This never-inserted
        // scene only carries the app-level handlers below.
        MenuBarExtra("iMCP", systemImage: "circle", isInserted: .constant(false)) {
            EmptyView()
        }
        .onChange(of: isEnabled, initial: true) { _, isEnabled in
            installMenuBar()
            MenuBarController.shared.updateIcon(isOn: isEnabled)
            // The panel's content isn't kept alive while it is closed, so the server follows the setting here.
            Task { await serverController.setEnabled(isEnabled) }
        }
        .onChange(of: showMenuBarExtra) { _, showMenuBarExtra in
            appDelegate.isMenuBarExtraInserted = showMenuBarExtra
        }
        .onChange(of: appDelegate.isMenuBarExtraInserted, initial: true) { _, inserted in
            installMenuBar()
            MenuBarController.shared.setVisible(inserted)
        }
        .onChange(of: appDelegate.shouldOpenSettings, initial: true) { _, shouldOpenSettings in
            guard shouldOpenSettings else { return }
            appDelegate.shouldOpenSettings = false
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Settings {
            SettingsView(
                serverController: serverController,
                isMenuBarExtraInserted: appDelegate.isMenuBarExtraInserted
            )
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
    // System removal must not overwrite the user's saved preference.
    var isMenuBarExtraInserted =
        UserDefaults.standard.object(forKey: "showMenuBarExtra") as? Bool ?? true

    func applicationDidFinishLaunching(_ notification: Notification) {
        // An unset preference defaults to showing the menu bar item.
        if UserDefaults.standard.object(forKey: "showMenuBarExtra") as? Bool == false {
            shouldOpenSettings = true
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // iMCP Helper's Open iMCP button opens imcp://pair, which only opens the pairing window.
        guard urls.contains(where: HomeHelperPairing.isPairingURL) else { return }
        Task { await HomeService.shared.pairFromURL() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Reopening the app must work even when the menu bar item is absent.
        shouldOpenSettings = true
        return false
    }
}
