import AppKit
import Foundation
import SwiftUI
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

final class OnboardingLookupTests: XCTestCase {
    func testFastResultWins() async {
        let value = await OnboardingLookup.result(within: .seconds(5)) { "here" }
        XCTAssertEqual(value, "here")
    }

    func testErrorGivesNil() async {
        let value: String? = await OnboardingLookup.result(within: .seconds(5)) {
            throw CancellationError()
        }
        XCTAssertNil(value)
    }

    func testDeadlineEndsLookupThatIgnoresCancellation() async {
        let start = ContinuousClock.now
        let value: String? = await OnboardingLookup.result(within: .milliseconds(50)) {
            // Wait one second without checking for cancellation.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { continuation.resume() }
            }
            return "late result"
        }
        XCTAssertNil(value)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
    }

    func testDeadlineCancelsLookup() async {
        let cancelled = expectation(description: "The lookup sees cancellation")
        let value: String? = await OnboardingLookup.result(within: .milliseconds(50)) {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                cancelled.fulfill()
            }
            return "late result"
        }
        XCTAssertNil(value)
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testCallerCancellationEndsLookup() async {
        let task = Task {
            await OnboardingLookup.result(within: .seconds(10)) {
                try await Task.sleep(for: .seconds(10))
                return "late result"
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        task.cancel()
        let value = await task.value
        XCTAssertNil(value)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
    }
}

@MainActor
final class OnboardingWindowControllerTests: XCTestCase {
    func testCloseButtonRecordsSeen() throws {
        let controller = OnboardingWindowController()
        var seenCount = 0
        controller.show(Text("Setup"), onSeen: { seenCount += 1 })
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.isVisible)

        let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
        closeButton.performClick(nil)

        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(seenCount, 1)
    }

    func testFinishRecordsSeenOnce() {
        let controller = OnboardingWindowController()
        var seenCount = 0
        controller.show(Text("Setup"), onSeen: { seenCount += 1 })
        controller.close()
        controller.close()
        XCTAssertEqual(seenCount, 1)
    }

    func testReopenedWindowRecordsSeenAgain() throws {
        let controller = OnboardingWindowController()
        var seenCount = 0
        controller.show(Text("Setup"), onSeen: { seenCount += 1 })
        controller.close()
        controller.show(Text("Setup"), onSeen: { seenCount += 1 })
        try XCTUnwrap(controller.window).performClose(nil)
        XCTAssertEqual(seenCount, 2)
    }
}
