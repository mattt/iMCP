import Logging
import ServiceLifecycle
import ServiceLifecycleTestKit
import XCTest

/// Regression tests for the `ServiceGroup` configuration used by `imcp-server`.
///
/// These tests guard against the fatal crash first diagnosed on 2026-04-23:
/// if `successTerminationBehavior` is left at its default of `.cancelGroup`, a
/// `Service.run()` that returns normally (as `MCPService.run()` does when the
/// Bonjour connection drops) causes `ServiceGroup` to throw
/// `ServiceGroupError.serviceFinishedUnexpectedly`, which becomes a Swift
/// top-level fatal error. See `CLI/main.swift` for the production configuration
/// this file mirrors.
final class ServiceGroupConfigurationTests: XCTestCase {

    /// When a service returns normally from `run()`, the `ServiceGroup` must
    /// exit cleanly rather than throwing. This is the primary regression the
    /// production fix addresses.
    func testServiceReturningNormallyExitsGroupCleanly() async throws {
        struct ImmediatelyReturningService: Service {
            func run() async throws {}
        }

        let group = ServiceGroup(
            configuration: .init(
                services: [
                    .init(
                        service: ImmediatelyReturningService(),
                        successTerminationBehavior: .gracefullyShutdownGroup,
                        failureTerminationBehavior: .gracefullyShutdownGroup
                    )
                ],
                logger: Logger(label: "test")
            )
        )

        try await group.run()
    }

    /// Demonstrates the pre-fix behavior: with the library default of
    /// `.cancelGroup`, a service returning from `run()` causes `ServiceGroup.run()`
    /// to throw. If this ever stops throwing — e.g. the library changes its
    /// default — the production fix may no longer be necessary.
    func testDefaultCancelGroupThrowsWhenServiceReturns() async {
        struct ImmediatelyReturningService: Service {
            func run() async throws {}
        }

        let group = ServiceGroup(
            configuration: .init(
                services: [ImmediatelyReturningService()],
                logger: Logger(label: "test")
            )
        )

        do {
            try await group.run()
            XCTFail("Expected ServiceGroup.run() to throw with default .cancelGroup behavior")
        } catch {
            // Expected — this is the original failure mode that the production
            // config avoids by using .gracefullyShutdownGroup.
        }
    }

    /// The reconnect loop in `MCPService.run()` uses
    /// `while !Task.isShuttingDownGracefully` to exit promptly when the group
    /// is shutting down. Verify the task-local mechanism works as expected.
    func testTaskIsShuttingDownGracefullyObservedAfterTrigger() async throws {
        await testGracefulShutdown { trigger in
            XCTAssertFalse(Task.isShuttingDownGracefully)
            trigger.triggerGracefulShutdown()
            XCTAssertTrue(Task.isShuttingDownGracefully)
        }
    }
}
