import Foundation

struct HomeError: LocalizedError, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    var description: String { message }
}

extension HomeError {
    /// Returns the error for a HomeKit call that HomeKit may have refused
    /// because iMCP Helper had no window on screen.
    ///
    /// The message keeps HomeKit's description, domain, and code,
    /// and suggests showing iMCP Helper's window as a possible workaround.
    static func possibleWindowRefusal(_ error: NSError) -> HomeError {
        HomeError(
            "\(error.localizedDescription) (\(error.domain) \(error.code)) HomeKit sometimes refuses this call while iMCP Helper has no window on screen. Showing iMCP Helper's window and retrying may help; the window can stay behind other windows."
        )
    }

    /// Returns whether HomeKit's error matches a refusal
    /// that may depend on whether the app has a window on screen.
    ///
    /// HomeKit reports these refusals as `HMErrorDomain` code 80
    /// ("Missing entitlement for API.")
    /// or as code 14 in the private `HMFErrorDomain` ("Request not handled.").
    /// In some tests, HomeKit refused characteristic reads, accessory identification,
    /// and scene action edits while the app was hidden,
    /// its window was minimized, or its window was closed,
    /// and allowed them while the window was open behind other windows.
    /// Other tests didn't reproduce the refusal, so the cause isn't confirmed.
    /// The domains are matched by name,
    /// because `HMFErrorDomain` is private
    /// and native macOS targets can't use HomeKit's `HMErrorDomain` constant.
    static func isPossibleWindowRefusal(_ error: NSError) -> Bool {
        switch (error.domain, error.code) {
        case ("HMErrorDomain", 80), ("HMFErrorDomain", 14): return true
        default: return false
        }
    }
}
