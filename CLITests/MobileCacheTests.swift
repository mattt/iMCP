import CryptoKit
import XCTest

final class MobileCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCache(key: SymmetricKey = SymmetricKey(size: .bits256)) throws -> MobileCache {
        try MobileCache(url: directory.appendingPathComponent("cache.sqlite"), key: key)
    }

    private func sleep(_ id: String, day: Int, value: String = "asleepCore") -> MobileRecord {
        let start = Date(timeIntervalSince1970: 1_767_225_600 + Double(day) * 86_400)
        return MobileRecord(
            kind: .healthSample,
            id: id,
            key: "sleepAnalysis",
            start: start,
            end: start.addingTimeInterval(3_600),
            payload: try! JSONSerialization.data(withJSONObject: [
                "id": id, "value": value, "marker": "PLAINTEXT-\(id)",
            ])
        )
    }

    func testRoundTripStoresPayloadsEncrypted() async throws {
        let cache = try makeCache()
        let collected = Date(timeIntervalSince1970: 1_767_400_000)
        try await cache.apply(
            MobileBatch(
                sequence: 1,
                syncedAt: ["health": collected],
                records: [sleep("a", day: 0), sleep("b", day: 1)]
            )
        )
        let rows = try await cache.records(.healthSample, key: "sleepAnalysis", limit: 10)
        XCTAssertEqual(rows.map(\.id), ["b", "a"])
        XCTAssertEqual(rows.first?.payload.objectValue?["marker"], "PLAINTEXT-b")
        let syncedAt = await cache.syncedAt(.health)
        XCTAssertEqual(syncedAt, collected)
        await cache.close()

        let bytes = try Data(contentsOf: directory.appendingPathComponent("cache.sqlite"))
        XCTAssertNil(bytes.range(of: Data("PLAINTEXT".utf8)), "Payloads must not be stored in plaintext.")
    }

    func testAnotherKeyCannotReadPayloads() async throws {
        let cache = try makeCache()
        try await cache.apply(MobileBatch(sequence: 1, syncedAt: [:], records: [sleep("a", day: 0)]))
        await cache.close()
        let other = try makeCache()
        do {
            _ = try await other.records(.healthSample, key: "sleepAnalysis", limit: 10)
            XCTFail("A different key must not decrypt the cache.")
        } catch {}
    }

    func testAnchoredMergeAppliesUpdatesAndDeletions() async throws {
        let cache = try makeCache()
        try await cache.apply(
            MobileBatch(
                sequence: 1,
                syncedAt: [:],
                records: [sleep("a", day: 0), sleep("b", day: 1), sleep("c", day: 2)]
            )
        )
        try await cache.apply(
            MobileBatch(
                sequence: 2,
                syncedAt: [:],
                records: [.deletion(kind: .healthSample, id: "b"), sleep("c", day: 2, value: "awake")]
            )
        )
        // A replayed batch must not change the result.
        try await cache.apply(
            MobileBatch(sequence: 2, syncedAt: [:], records: [.deletion(kind: .healthSample, id: "b")])
        )
        let rows = try await cache.records(.healthSample, key: "sleepAnalysis", limit: 10)
        XCTAssertEqual(rows.map(\.id), ["c", "a"])
        XCTAssertEqual(rows.first?.payload.objectValue?["value"], "awake")
    }

    func testReplacingAKindDropsRecordsTheSnapshotOmits() async throws {
        let cache = try makeCache()
        func alarm(_ id: String) -> MobileRecord {
            MobileRecord(kind: .alarm, id: id, key: nil, start: nil, end: nil, payload: Data("{}".utf8))
        }
        try await cache.apply(MobileBatch(sequence: 1, syncedAt: [:], records: [alarm("x"), alarm("y")]))
        try await cache.apply(
            MobileBatch(sequence: 2, syncedAt: [:], records: [alarm("y")], replacing: [.alarm])
        )
        let rows = try await cache.records(.alarm, limit: 10)
        XCTAssertEqual(rows.map(\.id), ["y"])
    }

    func testDateWindowAndLimit() async throws {
        let cache = try makeCache()
        try await cache.apply(
            MobileBatch(sequence: 1, syncedAt: [:], records: (0 ..< 5).map { sleep("d\($0)", day: $0) })
        )
        let start = Date(timeIntervalSince1970: 1_767_225_600 + 86_400)
        let end = Date(timeIntervalSince1970: 1_767_225_600 + 3 * 86_400)
        let window = try await cache.records(.healthSample, key: "sleepAnalysis", start: start, end: end, limit: 10)
        XCTAssertEqual(window.map(\.id), ["d2", "d1"])
        let oldest = try await cache.records(.healthSample, limit: 2, ascending: true)
        XCTAssertEqual(oldest.map(\.id), ["d0", "d1"])
    }

    func testIntervalsEndingAtTheStartAreExcluded() async throws {
        let cache = try makeCache()
        let midnight = Date(timeIntervalSince1970: 1_767_225_600)
        func day(_ offset: Int) -> MobileRecord {
            let start = midnight.addingTimeInterval(Double(offset) * 86_400)
            return MobileRecord(
                kind: .healthStatistic,
                id: "steps-\(offset)",
                key: "stepCount",
                start: start,
                end: start.addingTimeInterval(86_400),
                payload: Data(#"{"sum":1000}"#.utf8)
            )
        }
        let reading = MobileRecord(
            kind: .healthStatistic,
            id: "point",
            key: "stepCount",
            start: midnight.addingTimeInterval(86_400),
            end: nil,
            payload: Data(#"{"sum":1}"#.utf8)
        )
        try await cache.apply(MobileBatch(sequence: 1, syncedAt: [:], records: [day(0), day(1), day(2), reading]))
        let rows = try await cache.records(
            .healthStatistic,
            key: "stepCount",
            start: midnight.addingTimeInterval(86_400),
            end: midnight.addingTimeInterval(2 * 86_400),
            ascending: true
        )
        XCTAssertEqual(rows.map(\.id), ["point", "steps-1"])
    }

    func testDeleteAllRemovesRecordsAndSyncState() async throws {
        let cache = try makeCache()
        try await cache.apply(MobileBatch(sequence: 1, syncedAt: ["health": Date()], records: [sleep("a", day: 0)]))
        try await cache.deleteAll()
        let rows = try await cache.records(.healthSample, limit: 10)
        let syncedAt = await cache.syncedAt(.health)
        XCTAssertEqual(rows.count, 0)
        XCTAssertNil(syncedAt)
    }

    func testStaleThresholdPerDomain() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func stale(_ domain: MobileDomain, _ age: TimeInterval?) -> Bool {
            let value = MobileEnvelope.make(
                domain: domain,
                source: .cache,
                syncedAt: age.map { now.addingTimeInterval(-$0) },
                now: now,
                results: []
            )
            return value.objectValue?["stale"] == .bool(true)
        }
        XCTAssertTrue(stale(.health, nil))
        XCTAssertFalse(stale(.health, 60))
        XCTAssertTrue(stale(.health, MobileEnvelope.staleAfter[.health]! + 1))
        XCTAssertFalse(stale(.finance, MobileEnvelope.staleAfter[.health]! + 1))
        XCTAssertTrue(stale(.alarms, MobileEnvelope.staleAfter[.alarms]! + 1))
    }

    func testLiveEnvelopeIsNeverStale() {
        let now = Date()
        let value = MobileEnvelope.make(domain: .health, source: .live, syncedAt: now, now: now, results: [])
        XCTAssertEqual(value.objectValue?["source"], "live")
        XCTAssertEqual(value.objectValue?["stale"], false)
        XCTAssertNotNil(value.objectValue?["synced_at"]?.stringValue)
    }
}

final class MobileServiceOfflineTests: XCTestCase {
    private func makeService() throws -> (MobileService, MobileCache, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = try MobileCache(
            url: directory.appendingPathComponent("cache.sqlite"),
            key: SymmetricKey(size: .bits256)
        )
        return (MobileService(cache: cache, reconnectGrace: .milliseconds(50)), cache, directory)
    }

    func testOfflineReadsAnswerFromTheCacheWithSyncTime() async throws {
        let (service, cache, directory) = try makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        let syncedAt = Date().addingTimeInterval(-60)
        try await cache.apply(
            MobileBatch(
                sequence: 1,
                syncedAt: ["health": syncedAt],
                records: [
                    MobileRecord(
                        kind: .workout,
                        id: "w1",
                        key: "running",
                        start: syncedAt.addingTimeInterval(-3_600),
                        end: syncedAt.addingTimeInterval(-1_800),
                        payload: Data(#"{"id":"w1","activity_type":"running"}"#.utf8)
                    )
                ]
            )
        )
        let value = try await service.call("workouts_fetch", [:])
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["source"], "cache")
        XCTAssertEqual(object["stale"], false)
        XCTAssertNotNil(object["synced_at"]?.stringValue)
        XCTAssertEqual(object["results"]?.arrayValue?.count, 1)
    }

    func testEmptyHealthResultsMentionDeniedAccess() async throws {
        let (service, _, directory) = try makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = try await service.call("health_fetch", ["type": "sleepAnalysis"])
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["stale"], true)
        XCTAssertEqual(object["synced_at"], .null)
        XCTAssertTrue(object["note"]?.stringValue?.contains("denied") == true)
    }

    func testWritesNeedTheiOSApp() async throws {
        let (service, _, directory) = try makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await service.call("timers_create", ["title": "Tea", "duration_seconds": 180])
            XCTFail("Creating a timer must need a live connection.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("iPhone or iPad"))
        }
    }

    func testOfflineCallsValidateArguments() async throws {
        let (service, _, directory) = try makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await service.call("workouts_fetch", ["limit": "ten"])
            XCTFail("Mistyped arguments must be rejected.")
        } catch {}
    }

    func testStatusReportsPairingAndSyncState() async throws {
        let (service, _, directory) = try makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = try await service.call("mobile_status", [:])
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["connected"], false)
        XCTAssertNotNil(object["services"]?.objectValue?["health"])
        XCTAssertEqual(object["services"]?.objectValue?["health"]?.objectValue?["stale"], true)
    }
}
