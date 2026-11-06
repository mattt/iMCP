import XCTest

final class MobileOutboxTests: XCTestCase {
    private var directory: URL!
    private var outbox: MobileOutbox!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        outbox = try MobileOutbox(url: directory.appendingPathComponent("outbox.sqlite"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ id: String) -> MobileRecord {
        MobileRecord(kind: .workout, id: id, key: "running", start: Date(), end: nil, payload: Data("{}".utf8))
    }

    func testFirstPullFromACacheResetsState() async throws {
        try await outbox.enqueue([record("a")], syncedAt: [.health: Date()], state: ["anchor.workout": Data([1])])
        let pull = try await outbox.pull(cacheID: "cache-1")
        XCTAssertTrue(pull.reset)
        XCTAssertEqual(pull.batch.sequence, 0)
        let anchor = await outbox.state("anchor.workout")
        XCTAssertNil(anchor)
        let pending = await outbox.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testBatchesStayQueuedUntilAcknowledged() async throws {
        _ = try await outbox.pull(cacheID: "cache-1")
        try await outbox.enqueue([record("a")], syncedAt: [.health: Date()], state: ["anchor.workout": Data([1])])
        try await outbox.enqueue([record("b")], syncedAt: [.health: Date()])
        let first = try await outbox.pull(cacheID: "cache-1")
        XCTAssertFalse(first.reset)
        XCTAssertEqual(first.batch.records.map(\.id), ["a"])
        XCTAssertTrue(first.batch.hasMore)
        let again = try await outbox.pull(cacheID: "cache-1")
        XCTAssertEqual(again.batch, first.batch, "An unacknowledged batch is sent again.")
        try await outbox.ack(first.batch.sequence)
        let second = try await outbox.pull(cacheID: "cache-1")
        XCTAssertEqual(second.batch.records.map(\.id), ["b"])
        XCTAssertFalse(second.batch.hasMore)
        try await outbox.ack(second.batch.sequence)
        let empty = try await outbox.pull(cacheID: "cache-1")
        XCTAssertEqual(empty.batch.sequence, 0)
        let anchor = await outbox.state("anchor.workout")
        XCTAssertEqual(anchor, Data([1]))
    }

    func testANewCacheClearsTheQueueAndAnchors() async throws {
        _ = try await outbox.pull(cacheID: "cache-1")
        try await outbox.enqueue([record("a")], syncedAt: [:], state: ["anchor.workout": Data([1])])
        let pull = try await outbox.pull(cacheID: "cache-2")
        XCTAssertTrue(pull.reset)
        XCTAssertEqual(pull.batch.sequence, 0)
        let anchor = await outbox.state("anchor.workout")
        XCTAssertNil(anchor)
    }

    func testWritesFromBeforeAResetAreRejected() async throws {
        _ = try await outbox.pull(cacheID: "cache-1")
        let generation = await outbox.generation
        _ = try await outbox.pull(cacheID: "cache-2")
        do {
            try await outbox.enqueue(
                [record("late")],
                syncedAt: [.health: Date()],
                state: ["anchor.workout": Data([9])],
                generation: generation
            )
            XCTFail("A sync that started before the reset must not write.")
        } catch is MobileOutbox.Superseded {}
        let anchor = await outbox.state("anchor.workout")
        XCTAssertNil(anchor)
        let pending = await outbox.pendingCount
        XCTAssertEqual(pending, 0)
        let current = await outbox.generation
        try await outbox.enqueue([record("new")], syncedAt: [:], generation: current)
        let after = await outbox.pendingCount
        XCTAssertEqual(after, 1)
    }

    func testLargeChangesSplitIntoBoundedBatches() async throws {
        _ = try await outbox.pull(cacheID: "cache-1")
        let records = (0 ..< 1_201).map { record("r\($0)") }
        try await outbox.enqueue(records, syncedAt: [.health: Date()], replacing: [.workout])
        var received: [String] = []
        var batches = 0
        while true {
            let pull = try await outbox.pull(cacheID: "cache-1")
            guard pull.batch.sequence > 0 else { break }
            batches += 1
            XCTAssertLessThanOrEqual(pull.batch.records.count, MobileOutbox.batchSize)
            // Only the first part of a replacement replaces; later parts add to it.
            XCTAssertEqual(pull.batch.replacing, batches == 1 ? [.workout] : [])
            received += pull.batch.records.map(\.id)
            try await outbox.ack(pull.batch.sequence)
        }
        XCTAssertEqual(received, records.map(\.id))
        XCTAssertEqual(batches, 3)
    }

    func testDeleteAllForgetsTheCache() async throws {
        _ = try await outbox.pull(cacheID: "cache-1")
        try await outbox.enqueue([record("a")], syncedAt: [:])
        try await outbox.deleteAll()
        let pull = try await outbox.pull(cacheID: "cache-1")
        XCTAssertTrue(pull.reset)
    }
}

final class MobileAlarmRequestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOneTimeAlarmNeedsAFutureDate() throws {
        let request = try MobileAlarmRequest(
            tool: "alarms_create",
            MobileArguments([
                "title": "Flight", "fire_at": "2030-01-01T06:00:00Z", "id": "8F0C2B8E-6E1A-4D53-9C0B-6A5D1A3E2F10",
            ]),
            now: now
        )
        XCTAssertEqual(request.id.uuidString, "8F0C2B8E-6E1A-4D53-9C0B-6A5D1A3E2F10")
        XCTAssertEqual(request.schedule, .fixed(MobileArguments.parse("2030-01-01T06:00:00Z")!))
        XCTAssertThrowsError(
            try MobileAlarmRequest(
                tool: "alarms_create",
                MobileArguments(["title": "Past", "fire_at": "2020-01-01T06:00:00Z"]),
                now: now
            )
        )
    }

    func testWeeklyAlarmMapsWeekdaysToCalendarNumbers() throws {
        let request = try MobileAlarmRequest(
            tool: "alarms_create",
            MobileArguments(["title": "Gym", "hour": 6, "minute": 30, "weekdays": ["monday", "friday"]]),
            now: now
        )
        XCTAssertEqual(request.schedule, .relative(hour: 6, minute: 30, weekdays: [2, 6]))
        XCTAssertEqual(request.title, "Gym")
    }

    func testTimerUsesItsDuration() throws {
        let request = try MobileAlarmRequest(
            tool: "timers_create",
            MobileArguments(["title": "Tea", "duration_seconds": 180]),
            now: now
        )
        XCTAssertEqual(request.schedule, .timer(seconds: 180))
    }

    func testTitlesMustNotBeEmpty() {
        XCTAssertThrowsError(
            try MobileAlarmRequest(
                tool: "timers_create",
                MobileArguments(["title": "  ", "duration_seconds": 60]),
                now: now
            )
        )
    }
}
