import Foundation
import MCP
import CryptoKit
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
    func testExpiredRequestLeavesThePendingListAndDeniesExactlyOnce() {
        let broker = makeBroker()
        open(broker, request("short", lifetime: 10))
        open(broker, request("long", lifetime: 60))
        clock.advance(11)
        XCTAssertEqual(broker.pending().map(\.id), ["long"])
        XCTAssertEqual(broker.pending().map(\.id), ["long"])
        XCTAssertEqual(outcomes.all, [.expired])
    }

    func testUnpairingADeviceRevokesItsAnswersAndLeavesTheRequestOpen() {
        final class Paired: @unchecked Sendable {
            private let lock = NSLock()
            private var ids: Set<String> = ["phone"]
            func contains(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
            func remove(_ id: String) { lock.withLock { _ = ids.remove(id) } }
        }
        let paired = Paired()
        let clock = self.clock
        let broker = ApprovalBroker(isPaired: { paired.contains($0) }, now: { clock.now })
        open(broker, request())
        paired.remove("phone")
        XCTAssertEqual(broker.receive(.init(id: "r1", decision: .approve), from: "phone"), .unpairedDevice)
        XCTAssertEqual(outcomes.all, [])
        // The request still ends as a denial when it expires.
        clock.advance(61)
        broker.expireDue()
        XCTAssertEqual(outcomes.all, [.expired])
    }

    func testOnlyOneOfTheMacAndThePhoneWinsARace() async {
        for round in 0 ..< 200 {
            let broker = makeBroker()
            let id = "race-\(round)"
            let phoneWins = Outcomes()
            broker.open(request(id)) { phoneWins.add($0) }
            async let phone: RemoteApprovalReceipt = Task.detached {
                broker.receive(.init(id: id, decision: .approve), from: "phone")
            }.value
            async let mac: Bool = Task.detached { broker.withdraw(id) }.value
            let (receipt, macWon) = await (phone, mac)
            // Exactly one side sees the request open.
            XCTAssertNotEqual(receipt == .accepted, macWon, "round \(round)")
            XCTAssertEqual(phoneWins.all.count, receipt == .accepted ? 1 : 0)
            XCTAssertFalse(broker.hasPending)
        }
    }

    func testWireFormatRoundTripsAndKeepsTheRequestUnchanged() throws {
        let original = RemoteApprovalSyncRequest(pending: [request()], ack: ["a", "b"])
        let data = try MobileCoding.encoder.encode(original)
        XCTAssertEqual(try MobileCoding.decoder.decode(RemoteApprovalSyncRequest.self, from: data), original)
        let answers = RemoteApprovalSyncResponse(answers: [.init(id: "r1", decision: .deny)])
        let reply = try MobileCoding.encoder.encode(answers)
        XCTAssertEqual(try MobileCoding.decoder.decode(RemoteApprovalSyncResponse.self, from: reply), answers)
    }

    func testPhoneInboxReportsAddedAndRemovedRequests() {
        let inbox = ApprovalInbox(now: { self.clock.now })
        XCTAssertEqual(
            inbox.sync(pending: [request("a"), request("b")], ack: []).added.map(\.id).sorted(),
            ["a", "b"]
        )
        let second = inbox.sync(pending: [request("b")], ack: [])
        XCTAssertEqual(second.added, [])
        XCTAssertEqual(second.removed, ["a"])
        XCTAssertEqual(inbox.visible().map(\.id), ["b"])
        // Answering a request that expired on the phone is refused.
        clock.advance(61)
        XCTAssertFalse(inbox.answer("b", .approve))
        XCTAssertEqual(inbox.visible(), [])
    }

    func testAnswerFromANotificationIsDeliveredEvenBeforeTheRequestLoads() {
        let inbox = ApprovalInbox(now: { self.clock.now })
        inbox.answerFromNotification("r1", .approve)
        XCTAssertTrue(inbox.hasUndeliveredAnswers)
        let result = inbox.sync(pending: [request()], ack: [])
        XCTAssertEqual(result.answers, [.init(id: "r1", decision: .approve)])
        // A request the phone already answered is not shown again.
        XCTAssertEqual(result.added, [])
        XCTAssertEqual(inbox.visible(), [])
    }

    func testMacSendsOpenRequestsToTheConnectedPhoneAndReadsItsAnswers() async throws {
        let pairings = MobileMemoryPairings()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = MobileService(
            cache: try MobileCache(
                url: directory.appendingPathComponent("cache.sqlite"),
                key: SymmetricKey(size: .bits256)
            ),
            pairings: pairings,
            advertise: false,
            pollInterval: .seconds(60)
        )
        let noPhone = await service.syncApprovals(pending: [request()], ack: [])
        XCTAssertNil(noPhone, "Nothing is connected")

        let link = ApprovalLink(answer: .init(id: "r1", decision: .approve))
        await service.attach(link)
        let reply = await service.syncApprovals(pending: [request()], ack: ["old"])
        XCTAssertEqual(reply?.device, "phone-1")
        XCTAssertEqual(reply?.answers, [.init(id: "r1", decision: .approve)])
        XCTAssertEqual(link.received?.pending.map(\.id), ["r1"])
        XCTAssertEqual(link.received?.ack, ["old"])
        await service.stop()
    }
}

private final class ApprovalLink: MobilePeerLink, @unchecked Sendable {
    let device = MobileDevice(id: "phone-1", name: "Test iPhone", pairedAt: Date())
    private let lock = NSLock()
    private var last: RemoteApprovalSyncRequest?
    private let answer: RemoteApprovalAnswer

    init(answer: RemoteApprovalAnswer) { self.answer = answer }

    var received: RemoteApprovalSyncRequest? { lock.withLock { last } }

    func call(_ tool: String, _ input: [String: Value]) async throws -> String {
        switch tool {
        case RemoteApprovalLink.syncTool:
            let request = try MobileCoding.decoder.decode(
                RemoteApprovalSyncRequest.self,
                from: JSONEncoder().encode(input)
            )
            lock.withLock { last = request }
            return String(
                decoding: try MobileCoding.encoder.encode(RemoteApprovalSyncResponse(answers: [answer])),
                as: UTF8.self
            )
        case MobileLink.pullTool:
            return String(
                decoding: try MobileCoding.encoder.encode(MobileBatch(sequence: 0, syncedAt: [:], records: [])),
                as: UTF8.self
            )
        default:
            return "{}"
        }
    }

    func close() async {}
}
