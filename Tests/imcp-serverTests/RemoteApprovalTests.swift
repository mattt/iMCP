import XCTest

final class RemoteApprovalTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000)
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
    }

    private final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [RemoteApprovalOutcome] = []
        var all: [RemoteApprovalOutcome] { lock.withLock { values } }
        func add(_ outcome: RemoteApprovalOutcome) { lock.withLock { values.append(outcome) } }
    }

    private let clock = Clock()
    private let outcomes = Outcomes()

    private func makeBroker() -> ApprovalBroker {
        let clock = self.clock
        return ApprovalBroker(isPaired: { $0 == "phone" }, now: { clock.now })
    }

    private func request(_ id: String = "r1", lifetime: TimeInterval = 60) -> RemoteApprovalRequest {
        RemoteApprovalRequest(
            id: id,
            kind: .send,
            title: "Send Message",
            details: ["To: +1 555 0100"],
            body: "Hello",
            expiresAt: clock.now.addingTimeInterval(lifetime)
        )
    }

    private func open(_ broker: ApprovalBroker, _ request: RemoteApprovalRequest) {
        let outcomes = self.outcomes
        broker.open(request) { outcomes.add($0) }
    }

    func testFirstAnswerWinsWhenThePhoneAnswersFirst() {
        let broker = makeBroker()
        open(broker, request())
        XCTAssertEqual(broker.receive(.init(id: "r1", decision: .approve), from: "phone"), .accepted)
        XCTAssertEqual(outcomes.all, [.approved])
        // The Mac's own answer comes second and finds nothing to withdraw.
        XCTAssertFalse(broker.withdraw("r1"))
    }

    func testFirstAnswerWinsWhenTheMacAnswersFirst() {
        let broker = makeBroker()
        open(broker, request())
        XCTAssertTrue(broker.withdraw("r1"))
        XCTAssertEqual(broker.receive(.init(id: "r1", decision: .approve), from: "phone"), .unknownRequest)
        XCTAssertEqual(outcomes.all, [])
    }

    func testAnswerAfterExpiryIsIgnoredAndExpiryDenies() {
        let broker = makeBroker()
        open(broker, request(lifetime: 30))
        clock.advance(31)
        XCTAssertEqual(broker.receive(.init(id: "r1", decision: .approve), from: "phone"), .unknownRequest)
        XCTAssertEqual(outcomes.all, [.expired])
        XCTAssertFalse(outcomes.all.contains(.approved))
        XCTAssertEqual(outcomes.all.map(\.isApproved), [false])
    }

    func testUnknownAndReplayedIDsAreRejected() {
        let broker = makeBroker()
        open(broker, request())
        XCTAssertEqual(broker.receive(.init(id: "other", decision: .approve), from: "phone"), .unknownRequest)
        XCTAssertEqual(broker.receive(.init(id: "r1", decision: .deny), from: "phone"), .accepted)
        // The same answer again, or the opposite one, has nothing left to resolve.
        XCTAssertEqual(broker.receive(.init(id: "r1", decision: .deny), from: "phone"), .unknownRequest)
        XCTAssertEqual(broker.receive(.init(id: "r1", decision: .approve), from: "phone"), .unknownRequest)
        XCTAssertEqual(outcomes.all, [.denied])
    }

    func testAnswerFromUnpairedDeviceIsRejectedAndLeavesTheRequestOpen() {
        let broker = makeBroker()
        open(broker, request())
        XCTAssertEqual(broker.receive(.init(id: "r1", decision: .approve), from: "stranger"), .unpairedDevice)
        XCTAssertEqual(outcomes.all, [])
        XCTAssertEqual(broker.pending().map(\.id), ["r1"])
    }

    func testPhoneKeepsAnAnswerUntilTheMacAcknowledgesIt() {
        let inbox = ApprovalInbox(now: { self.clock.now })
        _ = inbox.sync(pending: [request()], ack: [])
        XCTAssertTrue(inbox.answer("r1", .approve))
        XCTAssertFalse(inbox.answer("r1", .deny), "An answer works once")
        XCTAssertEqual(inbox.visible(), [])
        // The Mac didn't get the first reply, so the answer is offered again.
        XCTAssertEqual(inbox.sync(pending: [request()], ack: []).answers, [.init(id: "r1", decision: .approve)])
        XCTAssertEqual(inbox.sync(pending: [], ack: ["r1"]).answers, [])
        XCTAssertFalse(inbox.hasUndeliveredAnswers)
    }

    @MainActor
    func testPhoneAnswerClosesTheMacWindowAndWorksOnce() {
        var bindings = PhoneApprovalBindings()
        let id = bindings.register("key")
        var resolved: [RemoteApprovalOutcome] = []
        var closed = 0
        XCTAssertTrue(
            bindings.answer(
                key: "key",
                id: id,
                outcome: .approved,
                resolve: { resolved.append($0) },
                closeWindow: { closed += 1 }
            )
        )
        XCTAssertEqual(resolved, [.approved])
        XCTAssertEqual(closed, 1)
        XCTAssertFalse(
            bindings.answer(
                key: "key",
                id: id,
                outcome: .approved,
                resolve: { resolved.append($0) },
                closeWindow: { closed += 1 }
            )
        )
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(closed, 1)
    }

    @MainActor
    func testLateAnswerForAnEarlierRequestCannotResolveALaterOneWithTheSameKey() {
        var bindings = PhoneApprovalBindings()
        let first = bindings.register("key")
        let second = bindings.register("key")
        var resolved: [RemoteApprovalOutcome] = []
        var closed = 0
        XCTAssertFalse(
            bindings.answer(
                key: "key",
                id: first,
                outcome: .approved,
                resolve: { resolved.append($0) },
                closeWindow: { closed += 1 }
            )
        )
        XCTAssertEqual(resolved, [])
        XCTAssertEqual(closed, 0, "A stale answer must not close the newer window")
        // A request the Mac already withdrew can't be answered either.
        XCTAssertEqual(bindings.remove("key"), second)
        XCTAssertFalse(
            bindings.answer(
                key: "key",
                id: second,
                outcome: .approved,
                resolve: { resolved.append($0) },
                closeWindow: { closed += 1 }
            )
        )
        XCTAssertEqual(resolved, [])
    }
}
