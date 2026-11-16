import Foundation

/// How iMCP Helper shows itself, as far as HomeKit is known to care.
///
/// HomeKit refuses some calls with `HMErrorDomain` 80 or `HMFErrorDomain` 14
/// while the helper is hidden, minimized, or has no window.
/// See `HomeError.isPossibleWindowRefusal(_:)`.
struct HelperPresence: Equatable, Sendable {
    /// Whether the app is hidden (Hide iMCP Helper).
    var isHidden: Bool
    /// The helper's document windows that are on screen.
    var visibleWindows: Int
    /// The helper's document windows that are in the Dock.
    var minimizedWindows: Int

    enum Action: Equatable, Sendable {
        /// Show the hidden app without making it the active app.
        case unhide
        /// Bring a minimized window back to the screen.
        case restoreMinimizedWindow
        /// Open a window, because every one was closed.
        case openWindow
    }

    /// What to do so that HomeKit sees a window on screen.
    /// A window that is open behind other windows is enough, so this never asks for focus.
    var actions: [Action] {
        var actions: [Action] = []
        if isHidden { actions.append(.unhide) }
        if visibleWindows == 0 {
            actions.append(minimizedWindows > 0 ? .restoreMinimizedWindow : .openWindow)
        }
        return actions
    }
}

/// Puts iMCP Helper's window on screen before each HomeKit call.
struct WindowEnsuringBackend: HomeBackend {
    let base: any HomeBackend
    /// Shows the helper's window if it isn't on screen, and returns once it is or the attempt gave up.
    let ensureWindow: @Sendable () async -> Void

    func call(_ tool: String, _ input: [String: Value]) async throws -> Value {
        await ensureWindow()
        return try await base.call(tool, input)
    }
}
