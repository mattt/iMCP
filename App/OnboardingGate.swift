import Foundation

/// Whether the setup wizard should open on its own at launch.
///
/// It opens automatically only at the first launch.
/// Once a person has seen it, by finishing or by choosing Finish Later,
/// it never opens on its own again; "Set Up iMCP…" in the menu still opens it.
/// An install that was already set up before the wizard existed counts as seen:
/// a trusted client, a past connection, or a service on beyond the defaults
/// (Maps, and Utilities where it is listed) each show that setup already happened.
enum OnboardingGate {
    static func shouldOpenAutomatically(
        hasSeenOnboarding: Bool,
        hasTrustedClient: Bool,
        hasConnectedBefore: Bool,
        hasServiceOnBeyondDefaults: Bool
    ) -> Bool {
        !hasSeenOnboarding && !hasTrustedClient && !hasConnectedBefore && !hasServiceOnBeyondDefaults
    }
}
