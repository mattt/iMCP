import XCTest

final class OnboardingGateTests: XCTestCase {
    func testFirstLaunchOpensAutomatically() {
        XCTAssertTrue(
            OnboardingGate.shouldOpenAutomatically(
                hasSeenOnboarding: false,
                hasTrustedClient: false,
                hasConnectedBefore: false,
                hasServiceOnBeyondDefaults: false
            )
        )
    }

    func testAfterFinishLaterItDoesNotOpenAutomatically() {
        // Finish Later records the same seen flag as Done.
        XCTAssertFalse(
            OnboardingGate.shouldOpenAutomatically(
                hasSeenOnboarding: true,
                hasTrustedClient: false,
                hasConnectedBefore: false,
                hasServiceOnBeyondDefaults: false
            )
        )
    }

    func testAfterDoneItDoesNotOpenAutomatically() {
        XCTAssertFalse(
            OnboardingGate.shouldOpenAutomatically(
                hasSeenOnboarding: true,
                hasTrustedClient: true,
                hasConnectedBefore: true,
                hasServiceOnBeyondDefaults: true
            )
        )
    }

    func testExistingInstallWithTrustedClientDoesNotOpenAutomatically() {
        XCTAssertFalse(
            OnboardingGate.shouldOpenAutomatically(
                hasSeenOnboarding: false,
                hasTrustedClient: true,
                hasConnectedBefore: false,
                hasServiceOnBeyondDefaults: false
            )
        )
    }

    func testExistingInstallWithPastConnectionOrServiceOnDoesNotOpenAutomatically() {
        XCTAssertFalse(
            OnboardingGate.shouldOpenAutomatically(
                hasSeenOnboarding: false,
                hasTrustedClient: false,
                hasConnectedBefore: true,
                hasServiceOnBeyondDefaults: false
            )
        )
        XCTAssertFalse(
            OnboardingGate.shouldOpenAutomatically(
                hasSeenOnboarding: false,
                hasTrustedClient: false,
                hasConnectedBefore: false,
                hasServiceOnBeyondDefaults: true
            )
        )
    }
}
