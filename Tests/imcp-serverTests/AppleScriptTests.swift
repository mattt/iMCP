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

    /// A handler receives hostile text as a value: the script that would run it never does.
    func testHandlerParametersAreValuesNotScriptSource() async throws {
        let hostile = "\" & (do shell script \"touch /tmp/imcp-should-not-exist\") & \"\\"
        let echoed = try await NSAppleScript.execute(
            """
            on echo(valueOne, valueTwo)
                return valueOne & "|" & valueTwo
            end echo
            """,
            calling: NSAppleScript.Subroutine("echo", [.string(hostile), .string("a\nb")])
        )
        XCTAssertEqual(echoed.stringValue, hostile + "|a\nb")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/imcp-should-not-exist"))
    }

    func testSubroutineEventEncodesTypedParameters() throws {
        let code: FourCharCode = 0x694D_7367  // 'iMsg'
        let event = NSAppleScript.Subroutine(
            "SendItem",
            [.string("hello"), .boolean(true), .strings(["a", "b"]), .enumCode(code)]
        ).event()

        XCTAssertEqual(event.paramDescriptor(forKeyword: 0x736E_616D)?.stringValue, "senditem")
        let args = try XCTUnwrap(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
        XCTAssertEqual(args.numberOfItems, 4)
        XCTAssertEqual(args.atIndex(1)?.stringValue, "hello")
        XCTAssertEqual(args.atIndex(2)?.booleanValue, true)
        XCTAssertEqual(args.atIndex(3)?.numberOfItems, 2)
        XCTAssertEqual(args.atIndex(3)?.atIndex(1)?.stringValue, "a")
        XCTAssertEqual(args.atIndex(3)?.atIndex(2)?.stringValue, "b")
        XCTAssertEqual(args.atIndex(4)?.enumCodeValue, code)
    }

    func testBeforeSendingRunsImmediatelyBeforeTheScript() async throws {
        let marker = OSAllocatedUnfairLock(initialState: 0)
        let result = try await NSAppleScript.execute("return 7") {
            marker.withLock { $0 = 1 }
        }
        XCTAssertEqual(result.int32Value, 7)
        XCTAssertEqual(marker.withLock { $0 }, 1)

        struct Stop: Error {}
        do {
            _ = try await NSAppleScript.execute("error \"ran\" number 1") { throw Stop() }
            XCTFail("expected the hook's error")
        } catch {
            XCTAssertTrue(error is Stop, "\(error)")
        }
    }

    func testCancelledTasksSkipTheHook() async {
        let called = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NSAppleScript.execute("return 2") { called.withLock { $0 = true } }
                .int32Value
        }
        _ = try? await task.value
        XCTAssertFalse(called.withLock { $0 })
    }
}
