import XCTest

/// Tests for the limits on connection approval requests.
final class ConnectionApprovalsTests: XCTestCase {
    private typealias Queue = ApprovalQueue<String, Int>

    private let start = ContinuousClock.Instant.now
    private let policy = ApprovalPolicy(
        maximumUnapprovedConnections: 4,
        maximumOpenDialogs: 2,
        maximumWaitingConnections: 3,
        expiry: .seconds(120),
        denialCooldown: .seconds(30)
    )

    private func enqueue(
        _ queue: inout Queue,
        key: String,
        cooldownKey: String? = nil,
        waiter: Int,
        after offset: Duration = .zero
    ) -> Queue.Admission {
        queue.enqueue(
            key: key,
            cooldownKey: cooldownKey ?? key,
            request: key,
            id: waiter,
            waiter: waiter,
            now: start.advanced(by: offset)
        )
    }

    // MARK: - Admission

    func testRejectsConnectionsWhileDisabled() {
        XCTAssertEqual(
            ConnectionAdmission.decide(isEnabled: false, unapprovedCount: 0, policy: policy),
            .reject(.disabled)
        )
        XCTAssertEqual(ConnectionAdmission.decide(isEnabled: true, unapprovedCount: 0, policy: policy), .accept)
    }

    func testRejectsConnectionsBeyondUnapprovedLimit() {
        XCTAssertEqual(ConnectionAdmission.decide(isEnabled: true, unapprovedCount: 3, policy: policy), .accept)
        XCTAssertEqual(
            ConnectionAdmission.decide(isEnabled: true, unapprovedCount: 4, policy: policy),
            .reject(.tooManyUnapproved)
        )
    }

    // MARK: - Dialogs

    func testQueuesRequestsBeyondOpenDialogLimit() {
        var queue = Queue(policy: policy)
        XCTAssertEqual(enqueue(&queue, key: "a", waiter: 1), .show(deadline: start + .seconds(120)))
        XCTAssertEqual(enqueue(&queue, key: "b", waiter: 2), .show(deadline: start + .seconds(120)))
        XCTAssertEqual(
            enqueue(&queue, key: "c", waiter: 3, after: .seconds(1)),
            .queued(deadline: start + .seconds(121))
        )
        XCTAssertEqual(queue.shownCount, 2)

        let resolution = queue.resolve(key: "a", approved: true, now: start + .seconds(2))
        XCTAssertEqual(resolution.removed.map(\.key), ["a"])
        XCTAssertEqual(resolution.removed.first?.waiters.map(\.waiter), [1])
        XCTAssertEqual(resolution.promoted.map(\.key), ["c"])
        XCTAssertEqual(queue.shownCount, 2)
    }

    func testCoalescesRequestsWithSameKey() {
        var queue = Queue(policy: policy)
        XCTAssertEqual(enqueue(&queue, key: "a", waiter: 1), .show(deadline: start + .seconds(120)))
        XCTAssertEqual(enqueue(&queue, key: "a", waiter: 2), .coalesced)
        XCTAssertEqual(queue.entries.count, 1)

        let resolution = queue.resolve(key: "a", approved: false, now: start)
        XCTAssertEqual(resolution.removed.first?.waiters.map(\.waiter), [1, 2])
    }

    func testRejectsConnectionsBeyondWaitingLimit() {
        var queue = Queue(policy: policy)
        _ = enqueue(&queue, key: "a", waiter: 1)
        _ = enqueue(&queue, key: "a", waiter: 2)
        _ = enqueue(&queue, key: "b", waiter: 3)
        XCTAssertEqual(queue.waitingCount, 3)

        XCTAssertEqual(enqueue(&queue, key: "a", waiter: 4), .rejected(.tooManyWaiting))
        XCTAssertEqual(enqueue(&queue, key: "c", waiter: 5), .rejected(.tooManyWaiting))
        XCTAssertEqual(queue.waitingCount, 3)
    }

    // MARK: - Cooldown

    func testDenialStartsCooldown() {
        var queue = Queue(policy: policy)
        _ = enqueue(&queue, key: "connection:1", cooldownKey: "credential:a", waiter: 1)
        _ = queue.resolve(key: "connection:1", approved: false, now: start)

        XCTAssertEqual(
            enqueue(&queue, key: "connection:2", cooldownKey: "credential:a", waiter: 2, after: .seconds(29)),
            .rejected(.coolingDown)
        )
        XCTAssertEqual(
            enqueue(&queue, key: "connection:3", cooldownKey: "credential:b", waiter: 3, after: .seconds(29)),
            .show(deadline: start + .seconds(149))
        )
        XCTAssertEqual(
            enqueue(&queue, key: "connection:4", cooldownKey: "credential:a", waiter: 4, after: .seconds(30)),
            .show(deadline: start + .seconds(150))
        )
    }

    func testRequestWithoutCooldownKeyHasNoCooldown() {
        var queue = Queue(policy: policy)
        for (offset, waiter) in [(Duration.zero, 1), (.seconds(1), 2)] {
            XCTAssertEqual(
                queue.enqueue(
                    key: "connection:\(waiter)",
                    cooldownKey: nil,
                    request: "connection:\(waiter)",
                    id: waiter,
                    waiter: waiter,
                    now: start.advanced(by: offset)
                ),
                .show(deadline: start + offset + .seconds(120))
            )
            _ = queue.resolve(key: "connection:\(waiter)", approved: false, now: start.advanced(by: offset))
        }

        _ = enqueue(&queue, key: "connection:3", waiter: 3, after: .seconds(2))
        _ = queue.expire(now: start + .seconds(122))
        XCTAssertEqual(
            enqueue(&queue, key: "connection:3", waiter: 4, after: .seconds(123)),
            .rejected(.coolingDown),
            "A request with a cooldown key still cools down after it expires"
        )
    }

    func testApprovalDoesNotStartCooldown() {
        var queue = Queue(policy: policy)
        _ = enqueue(&queue, key: "a", waiter: 1)
        _ = queue.resolve(key: "a", approved: true, now: start)

        XCTAssertEqual(enqueue(&queue, key: "a", waiter: 2), .show(deadline: start + .seconds(120)))
    }

    // MARK: - Expiry

    func testExpiryDeniesOpenAndQueuedRequests() {
        var queue = Queue(policy: ApprovalPolicy(maximumOpenDialogs: 1, expiry: .seconds(120)))
        _ = enqueue(&queue, key: "a", waiter: 1)
        XCTAssertEqual(
            enqueue(&queue, key: "b", waiter: 2, after: .seconds(60)),
            .queued(deadline: start + .seconds(180))
        )

        XCTAssertTrue(queue.expire(now: start + .seconds(119)).removed.isEmpty)

        let first = queue.expire(now: start + .seconds(120))
        XCTAssertEqual(first.removed.map(\.key), ["a"])
        XCTAssertEqual(first.promoted.map(\.key), ["b"])

        // An expired request counts as a denial.
        XCTAssertEqual(enqueue(&queue, key: "a", waiter: 3, after: .seconds(121)), .rejected(.coolingDown))

        let second = queue.expire(now: start + .seconds(180))
        XCTAssertEqual(second.removed.map(\.key), ["b"])
        XCTAssertTrue(queue.entries.isEmpty)

        // A decision on an expired dialog has nothing left to resolve.
        XCTAssertTrue(queue.resolve(key: "b", approved: true, now: start + .seconds(181)).removed.isEmpty)
    }

    // MARK: - Cancellation

    func testCancelRemovesWaiterAndEmptyRequest() {
        var queue = Queue(policy: ApprovalPolicy(maximumOpenDialogs: 1))
        _ = enqueue(&queue, key: "a", waiter: 1)
        _ = enqueue(&queue, key: "a", waiter: 2)
        _ = enqueue(&queue, key: "b", waiter: 3)

        let first = queue.cancel(id: 1)
        XCTAssertEqual(first.waiter, 1)
        XCTAssertTrue(first.resolution.removed.isEmpty)

        let second = queue.cancel(id: 2)
        XCTAssertEqual(second.waiter, 2)
        XCTAssertEqual(second.resolution.removed.map(\.key), ["a"])
        XCTAssertEqual(second.resolution.promoted.map(\.key), ["b"])

        XCTAssertNil(queue.cancel(id: 2).waiter)

        // A closed connection isn't a denial.
        XCTAssertEqual(enqueue(&queue, key: "a", waiter: 4), .queued(deadline: start + .seconds(120)))
    }
}
