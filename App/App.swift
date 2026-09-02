import MenuBarExtraAccess
import Sparkle
import SwiftUI

@main
struct App: SwiftUI.App {
    @StateObject private var serverController = ServerController()
    @AppStorage("isEnabled") private var isEnabled = true
    @State private var isMenuPresented = false

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
        MenuBarExtra("iMCP", image: #"MenuIcon-\#(isEnabled ? "On" : "Off")"#) {
            ContentView(
                serverManager: serverController,
                isEnabled: $isEnabled,
                isMenuPresented: $isMenuPresented,
                updater: updaterController.updater
            )
        }
        .menuBarExtraStyle(.window)
        .menuBarExtraAccess(isPresented: $isMenuPresented)

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
