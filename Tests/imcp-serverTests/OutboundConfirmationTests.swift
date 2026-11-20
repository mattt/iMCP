import Foundation
import XCTest

final class OutboundConfirmationTests: XCTestCase {
    // MARK: - What the person sees

    func testDetailsAreShownOnOneShortenedLineEach() {
        let request = OutboundConfirmationRequest(
            action: "Send Message",
            clientName: "Evil\nTo: +1555\u{202E}",
            details: [.init(label: "To", value: "a\nb\tc " + String(repeating: "x", count: 700))],
            body: "line one\nline two"
        )
        XCTAssertEqual(request.clientName, "Evil To: +1555")
        XCTAssertFalse(request.details[0].value.contains("\n"))
        XCTAssertTrue(request.details[0].value.hasPrefix("a b c x"))
        XCTAssertEqual(request.details[0].value.count, 600)
        XCTAssertTrue(request.details[0].value.hasSuffix("…"))
        XCTAssertEqual(request.body, "line one\nline two", "the body is shown as it will be sent")
    }

    func testAnEmptyClientNameIsLeftOut() {
        XCTAssertNil(OutboundConfirmationRequest(action: "Send", clientName: " \n", details: []).clientName)
        XCTAssertNil(OutboundConfirmationRequest(action: "Send", clientName: nil, details: []).clientName)
    }

    // MARK: - Asking

    /// A window that answers when the test says so.
    @MainActor
    private final class FakeWindow {
        var answer: (@MainActor (Bool) -> Void)?
        private(set) var shown = 0
        private(set) var dismissed = 0

        func present(_ onAnswer: @escaping @MainActor (Bool) -> Void) -> @MainActor () -> Void {
            shown += 1
            answer = onAnswer
            return { self.dismissed += 1 }
        }
    }

    @MainActor
    func testApprovingAnswersApprovedAndDismissesTheWindow() async {
        let window = FakeWindow()
        let gate = OutboundConfirmation.Gate()
        let task = Task { @MainActor in
            await OutboundConfirmation.ask(timeout: .seconds(5), gate: gate, present: window.present)
        }
        await settle(until: { window.answer != nil })
        window.answer?(true)
        let result = await task.value
        XCTAssertEqual(result, .approved)
        XCTAssertEqual(window.dismissed, 1)
        XCTAssertFalse(gate.isOpen)
    }

    @MainActor
    func testDecliningAnswersDeclined() async {
        let window = FakeWindow()
        let gate = OutboundConfirmation.Gate()
        let task = Task { @MainActor in
            await OutboundConfirmation.ask(timeout: .seconds(5), gate: gate, present: window.present)
        }
        await settle(until: { window.answer != nil })
        window.answer?(false)
        let result = await task.value
        XCTAssertEqual(result, .declined)
    }

    @MainActor
    func testUnansweredConfirmationTimesOutWithoutApproval() async {
        let window = FakeWindow()
        let gate = OutboundConfirmation.Gate()
        let result = await OutboundConfirmation.ask(timeout: .milliseconds(50), gate: gate, present: window.present)
        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(window.dismissed, 1)
        XCTAssertFalse(gate.isOpen)
    }

    @MainActor
    func testOnlyTheFirstAnswerCounts() async {
        let window = FakeWindow()
        let gate = OutboundConfirmation.Gate()
        let task = Task { @MainActor in
            await OutboundConfirmation.ask(timeout: .seconds(5), gate: gate, present: window.present)
        }
        await settle(until: { window.answer != nil })
        window.answer?(false)
        window.answer?(true)
        let result = await task.value
        XCTAssertEqual(result, .declined)
    }

    @MainActor
    func testASecondConfirmationIsRefusedWhileOneIsOpen() async {
        let first = FakeWindow()
        let second = FakeWindow()
        let gate = OutboundConfirmation.Gate()
        let task = Task { @MainActor in
            await OutboundConfirmation.ask(timeout: .seconds(5), gate: gate, present: first.present)
        }
        await settle(until: { first.answer != nil })

        let busy = await OutboundConfirmation.ask(timeout: .seconds(5), gate: gate, present: second.present)
        XCTAssertEqual(busy, .busy)
        XCTAssertEqual(second.shown, 0, "a refused confirmation shows no window")

        first.answer?(true)
        _ = await task.value
        XCTAssertFalse(gate.isOpen)
    }

    @MainActor
    func testCancellingTheCallDismissesTheWindowWithoutApproval() async {
        let window = FakeWindow()
        let gate = OutboundConfirmation.Gate()
        let task = Task { @MainActor in
            await OutboundConfirmation.ask(timeout: .seconds(5), gate: gate, present: window.present)
        }
        await settle(until: { window.answer != nil })
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .declined)
        XCTAssertEqual(window.dismissed, 1)
    }

    // MARK: - Doing the action

    private struct FixedAnswer: OutboundConfirming {
        let answer: OutboundConfirmationAnswer
        func confirm(_ request: OutboundConfirmationRequest) async -> OutboundConfirmationAnswer { answer }
    }

    private let request = OutboundConfirmationRequest(action: "Send Message", clientName: nil, details: [])

    func testTheActionRunsOnlyAfterApproval() async throws {
        let counter = OSAllocatedCounter()
        let result = try await FixedAnswer(answer: .approved).approve(request) {
            counter.increment()
            return "sent"
        }
        XCTAssertEqual(result, "sent")
        XCTAssertEqual(counter.value, 1)
    }

    func testTheActionNeverRunsWithoutApproval() async {
        let cases: [(OutboundConfirmationAnswer, OutboundConfirmationError)] = [
            (.declined, .declined(action: "Send Message")),
            (.timedOut, .timedOut(action: "Send Message")),
            (.busy, .busy(action: "Send Message")),
        ]
        for (answer, expected) in cases {
            let counter = OSAllocatedCounter()
            do {
                _ = try await FixedAnswer(answer: answer).approve(request) { counter.increment() }
                XCTFail("ran after \(answer)")
            } catch {
                XCTAssertEqual(error as? OutboundConfirmationError, expected)
                XCTAssertTrue("\(error)".contains("Nothing was done"))
            }
            XCTAssertEqual(counter.value, 0)
        }
    }

    func testTheActionDoesNotRunWhenTheCallerIsCancelledBeforeApprovalReturns() async {
        // The caller is cancelled while the confirmation is still being decided.
        // Even though the answer is approved, the action must not run.
        let counter = OSAllocatedCounter()
        let confirmer = SlowConfirmer(answer: .approved, delay: .milliseconds(200))
        let task = Task {
            try await confirmer.approve(request) {
                counter.increment()
                return "sent"
            }
        }
        // Cancel while confirm is still waiting.
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("ran after cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(counter.value, 0, "a cancelled call must not send")
    }

    /// A confirmer that waits, cancellation-aware, then answers.
    private actor SlowConfirmer: OutboundConfirming {
        let answer: OutboundConfirmationAnswer
        let delay: Duration

        init(answer: OutboundConfirmationAnswer, delay: Duration) {
            self.answer = answer
            self.delay = delay
        }

        func confirm(_ request: OutboundConfirmationRequest) async -> OutboundConfirmationAnswer {
            try? await Task.sleep(for: delay)
            return answer
        }
    }

    @MainActor
    private func settle(until condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
