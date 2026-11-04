import Foundation
import XCTest

/// These scripts send no Apple events to other apps.
final class AppleScriptTests: XCTestCase {
    func testScriptsRunOffTheMainThread() async throws {
        let sum = try await NSAppleScript.execute("return 1 + 1")
        XCTAssertEqual(sum.int32Value, 2)
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
        // The queue runs one script at a time, so the second waits behind the first.
        let blocker = Task { try await NSAppleScript.execute("delay 0.5\nreturn 1").int32Value }
        try await Task.sleep(for: .milliseconds(100))
        let queued = Task { try await NSAppleScript.execute("return 2").int32Value }
        try await Task.sleep(for: .milliseconds(50))
        queued.cancel()

        do {
            let result = try await queued.value
            XCTFail("the queued script ran and returned \(result)")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let blocked = try await blocker.value
        XCTAssertEqual(blocked, 1)
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
