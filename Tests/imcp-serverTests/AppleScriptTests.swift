import Foundation
import XCTest
import os

/// These scripts send no Apple events to other apps.
final class AppleScriptTests: XCTestCase {
    @MainActor
    func testScriptsRunOffTheMainThread() async throws {
        // Hold the serial queue. A script that ran on the main actor
        // would finish anyway; a script on the queue waits.
        let release = DispatchSemaphore(value: 0)
        NSAppleScript.executionQueue.async { release.wait() }

        let finished = OSAllocatedUnfairLock(initialState: false)
        let script = Task { @MainActor in
            defer { finished.withLock { $0 = true } }
            return try await NSAppleScript.execute("return 1 + 1").int32Value
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(finished.withLock { $0 }, "the script did not wait for the queue")

        release.signal()
        let sum = try await script.value
        XCTAssertEqual(sum, 2)
    }

    func testCancelledTasksRunNoScript() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NSAppleScript.execute("return 2").int32Value
        }
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testCancellingAQueuedScriptStopsItBeforeItRuns() async throws {
        // Hold the serial queue, so that the script waits until after it is cancelled.
        let release = DispatchSemaphore(value: 0)
        NSAppleScript.executionQueue.async { release.wait() }

        let queued = Task { try await NSAppleScript.execute("return 2").int32Value }
        try await Task.sleep(for: .milliseconds(50))
        queued.cancel()
        release.signal()

        do {
            let result = try await queued.value
            XCTFail("the queued script ran and returned \(result)")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testScriptErrorsKeepTheirNumberAndMessage() async {
        do {
            _ = try await NSAppleScript.execute("error \"Not allowed.\" number -1743")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(
                error as? NSAppleScript.ExecutionError,
                NSAppleScript.ExecutionError(number: -1743, message: "Not allowed.")
            )
        }

        do {
            _ = try await NSAppleScript.execute("return (")
            XCTFail("expected a compile error")
        } catch {
            XCTAssertNotNil((error as? NSAppleScript.ExecutionError)?.number)
        }
    }
}
