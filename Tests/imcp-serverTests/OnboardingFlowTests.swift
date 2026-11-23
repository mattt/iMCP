// Copyright (c) 2025-2026 Oliver Ames. All rights reserved.
// Licensed under the MIT License.

// Adapted from Ping Warden's OnboardingFlowTests.

import XCTest

final class OnboardingNavigatorTests: XCTestCase {
    func testFirstRunHasASingleWelcomeThenFiveDots() {
        var nav = OnboardingNavigator(mode: .firstRun, progress: OnboardingProgress())
        XCTAssertEqual(nav.step, .welcome)
        XCTAssertEqual(
            nav.pageSteps,
            [.services, .remoteAccess, .connectApps, .iPhone, .done],
            "Local only needs no setup screen, so it has no dot"
        )
        XCTAssertNil(nav.pageIndex, "the Welcome keeps its own layout without dots")
        XCTAssertFalse(nav.canGoBack, "Welcome closes with Not Now")
        nav.advance()
        XCTAssertEqual(nav.step, .services)
        XCTAssertEqual(nav.pageIndex, 0)
        XCTAssertTrue(nav.canGoBack)
    }

    func testContinueWalksTheStepsInOrder() {
        var nav = OnboardingNavigator(mode: .firstRun, progress: OnboardingProgress())
        var seen: [OnboardingStep] = [nav.step]
        for _ in 0 ..< 5 {
            nav.advance()
            seen.append(nav.step)
        }
        XCTAssertEqual(seen, [.welcome, .services, .remoteAccess, .connectApps, .iPhone, .done])
        nav.advance()
        XCTAssertEqual(nav.step, .done, "Done is the end")
    }

    func testAChosenWayGetsItsOwnSetupScreen() {
        for choice in [RemoteChoice.tailscale, .funnel, .cloudflare] {
            var nav = OnboardingNavigator(mode: .firstRun, progress: OnboardingProgress())
            nav.advance()
            nav.advance()
            XCTAssertEqual(nav.step, .remoteAccess)
            nav.setRemoteChoice(choice)
            XCTAssertEqual(
                nav.pageSteps,
                [.services, .remoteAccess, .remoteSetup, .connectApps, .iPhone, .done],
                "\(choice) gets a dot for its setup"
            )
            nav.advance()
            XCTAssertEqual(nav.step, .remoteSetup, "\(choice)")
            nav.advance()
            XCTAssertEqual(nav.step, .connectApps)
            nav.goBack()
            XCTAssertEqual(nav.step, .remoteSetup)
            nav.goBack()
            XCTAssertEqual(nav.step, .remoteAccess)
        }
    }

    func testChangingBackToLocalOnlySkipsTheSetupScreen() {
        var nav = OnboardingNavigator(mode: .firstRun, progress: OnboardingProgress())
        nav.advance()
        nav.advance()
        nav.setRemoteChoice(.cloudflare)
        nav.setRemoteChoice(.local)
        nav.advance()
        XCTAssertEqual(nav.step, .connectApps)
        nav.goBack()
        XCTAssertEqual(nav.step, .remoteAccess, "Back never lands on a screen that was skipped")
    }

    func testBackRetracesTheScreensShown() {
        var nav = OnboardingNavigator(mode: .firstRun, progress: OnboardingProgress())
        nav.advance()
        nav.advance()
        nav.advance()
        XCTAssertEqual(nav.step, .connectApps, "the agents come after the remote access they need")
        nav.goBack()
        XCTAssertEqual(nav.step, .remoteAccess)
        nav.goBack()
        XCTAssertEqual(nav.step, .services)
        nav.goBack()
        XCTAssertEqual(nav.step, .welcome)
        XCTAssertFalse(nav.canGoBack)
    }

    func testFinishSetupResumesAtTheFirstIncompleteStep() {
        var progress = OnboardingProgress()
        XCTAssertEqual(OnboardingNavigator(mode: .finishSetup, progress: progress).step, .services)
        progress.hasServices = true
        XCTAssertEqual(OnboardingNavigator(mode: .finishSetup, progress: progress).step, .remoteAccess)
        progress.hasRemoteAccess = true
        let nav = OnboardingNavigator(mode: .finishSetup, progress: progress)
        XCTAssertEqual(nav.step, .connectApps)
        XCTAssertFalse(nav.canGoBack, "Set Up iMCP does not replay the welcome")
        XCTAssertEqual(nav.pageSteps, [.connectApps, .iPhone, .done])
        XCTAssertEqual(nav.pageIndex, 0)
    }

    func testFinishSetupWithEverythingDoneOpensOnDone() {
        let all = OnboardingProgress(
            hasServices: true,
            hasConnectedApp: true,
            hasRemoteAccess: true,
            hasPairedDevice: true
        )
        let nav = OnboardingNavigator(mode: .finishSetup, progress: all)
        XCTAssertEqual(nav.step, .done)
        XCTAssertEqual(nav.pageSteps, [.done])
        XCTAssertFalse(nav.canGoBack)
    }

    func testSkippedStepIsNotRevisitedByGoingBack() {
        var nav = OnboardingNavigator(mode: .firstRun, progress: OnboardingProgress())
        nav.advance()
        nav.advance()
        XCTAssertEqual(nav.step, .remoteAccess)
        XCTAssertTrue(nav.step.isOptional)
        nav.advance()
        nav.advance()
        XCTAssertEqual(nav.step, .iPhone)
        nav.show(.done)
        XCTAssertEqual(nav.step, .done)
        XCTAssertFalse(nav.canGoBack, "Done ends the flow, as in Ping Warden")
    }

    func testOnlyTheRemoteScreensAndIPhoneAreOptional() {
        XCTAssertEqual(OnboardingStep.allCases.filter(\.isOptional), [.remoteAccess, .remoteSetup, .iPhone])
    }
}

final class RemoteChoiceTests: XCTestCase {
    func testLocalOnlyIsTheDefault() {
        XCTAssertEqual(RemoteChoice.current(.init(tailscale: false, funnel: false, cloudflare: false)), .local)
        XCTAssertEqual(RemoteChoice.allCases, [.local, .tailscale, .funnel, .cloudflare], "simplest first")
    }

    func testExistingSetupsArePreselectedAndTurnNothingOff() {
        XCTAssertEqual(RemoteChoice.current(.init(tailscale: true, funnel: false, cloudflare: false)), .tailscale)
        XCTAssertEqual(RemoteChoice.current(.init(tailscale: true, funnel: true, cloudflare: false)), .funnel)
        XCTAssertEqual(RemoteChoice.current(.init(tailscale: false, funnel: false, cloudflare: true)), .cloudflare)
        XCTAssertEqual(
            RemoteChoice.current(.init(tailscale: true, funnel: true, cloudflare: true)),
            .cloudflare,
            "a person with both keeps seeing the more involved one"
        )
    }

    func testEveryChoiceRoundTripsThroughItsSwitches() {
        for choice in RemoteChoice.allCases {
            XCTAssertEqual(RemoteChoice.current(choice.switches), choice)
        }
    }

    func testOnlyCloudflareIsAdvanced() {
        XCTAssertEqual(RemoteChoice.allCases.filter(\.isAdvanced), [.cloudflare])
    }
}
