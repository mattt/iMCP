import OSLog
import UIKit

/// Keeps iMCP Helper's window on screen while HomeKit calls run.
///
/// HomeKit has refused calls while the helper was hidden, minimized, or had no window,
/// and allowed them while a window was open, even behind other windows.
/// The cause isn't confirmed, so this restores only what a user could have taken away,
/// without activating the app or taking focus.
/// UIKit on Mac Catalyst can't see the AppKit state, so this reads and changes it
/// through the Objective-C runtime, like the rest of the helper's AppKit calls.
@MainActor
enum HelperWindow {
    private static let log = Logger.service("helper.window")

    /// Restores whatever hides the window, and waits briefly for a new window to appear.
    static func ensureOnScreen() async {
        let actions = presence().actions
        guard !actions.isEmpty else { return }
        log.info("Showing the helper's window: \(String(describing: actions), privacy: .public)")
        for action in actions {
            switch action {
            case .unhide: _ = application?.perform(NSSelectorFromString("unhideWithoutActivation"))
            case .restoreMinimizedWindow:
                for window in windows where flag(window, "isMiniaturized") {
                    _ = window.perform(NSSelectorFromString("deminiaturize:"), with: nil)
                }
            case .openWindow:
                // Reuses the closed window's session, so the helper doesn't collect windows.
                UIApplication.shared.requestSceneSessionActivation(
                    UIApplication.shared.openSessions.first,
                    userActivity: nil,
                    options: nil
                ) { error in
                    log.error("Can't open the helper's window: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        // A scene or window needs a moment before HomeKit sees it.
        for _ in 0 ..< 10 where presence().visibleWindows == 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func presence() -> HelperPresence {
        // Only windows that can be the main window count: the helper also has utility windows.
        let documents = windows.filter { flag($0, "canBecomeMainWindow") }
        return HelperPresence(
            isHidden: application.map { flag($0, "isHidden") } ?? false,
            visibleWindows: documents.filter { flag($0, "isVisible") && !flag($0, "isMiniaturized") }.count,
            minimizedWindows: documents.filter { flag($0, "isMiniaturized") }.count
        )
    }

    private static var application: NSObject? {
        (NSClassFromString("NSApplication") as AnyObject?)?
            .perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? NSObject
    }

    private static var windows: [NSObject] {
        application?.value(forKey: "windows") as? [NSObject] ?? []
    }

    private static func flag(_ object: NSObject, _ key: String) -> Bool {
        (object.value(forKey: key) as? NSNumber)?.boolValue ?? false
    }
}
