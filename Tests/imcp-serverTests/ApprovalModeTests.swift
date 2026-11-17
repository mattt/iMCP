import Foundation
import MCP
import XCTest

/// Tests the four global approval modes, concurrent confirmation queuing,
/// double-prompt prevention for `messages_send`, and agent setup instructions.
final class ApprovalModeTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ApprovalModeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Test Doubles

    private final class FakeService: Service, @unchecked Sendable {
        let writesEnabledByDefault: Bool
        let readCounter = OSAllocatedCounter()
        let writeCounter = OSAllocatedCounter()
        let unmarkedCounter = OSAllocatedCounter()
        let lastClientName = OSAllocatedLock<String?>(initialState: nil)
        let lastAlreadyConfirmed = OSAllocatedLock<Bool>(initialState: false)

        init(writesEnabledByDefault: Bool = true) {
            self.writesEnabledByDefault = writesEnabledByDefault
        }

        var tools: [Tool] {
            Tool(
                name: "fake_read",
                description: "Read test data.",
                inputSchema: .object(properties: ["query": .string()], additionalProperties: false),
                annotations: .init(title: "Fetch Fake Data", readOnlyHint: true, openWorldHint: false)
            ) { _ in
                self.readCounter.increment()
                self.lastClientName.set(ToolCallContext.clientName)
                self.lastAlreadyConfirmed.set(ToolCallContext.alreadyConfirmedByGlobalGate)
                return "read-ok"
            }
            Tool(
                name: "fake_write",
                description: "Write test data.",
                inputSchema: .object(properties: ["value": .string()], additionalProperties: false),
                annotations: .init(title: "Update Fake Data", readOnlyHint: false, destructiveHint: true)
            ) { _ in
                self.writeCounter.increment()
                self.lastClientName.set(ToolCallContext.clientName)
                self.lastAlreadyConfirmed.set(ToolCallContext.alreadyConfirmedByGlobalGate)
                return "write-ok"
            }
            Tool(
                name: "fake_unmarked",
                description: "Tool without readOnlyHint.",
                inputSchema: .object(properties: [:], additionalProperties: false),
                annotations: .init(openWorldHint: false)
            ) { _ in
                self.unmarkedCounter.increment()
                self.lastClientName.set(ToolCallContext.clientName)
                self.lastAlreadyConfirmed.set(ToolCallContext.alreadyConfirmedByGlobalGate)
                return "unmarked-ok"
            }
        }

        func tool(named name: String) -> Tool {
            tools.first { $0.name == name }!
        }
    }

    private final class OSAllocatedLock<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value

        init(initialState: Value) {
            self.storage = initialState
        }

        var value: Value { lock.withLock { storage } }

        func set(_ newValue: Value) {
            lock.withLock { storage = newValue }
        }
    }

    private final class RecordingConfirmer: OutboundConfirming, @unchecked Sendable {
        private let answer: OutboundConfirmationAnswer
        private let lock = NSLock()
        private var recorded: [OutboundConfirmationRequest] = []

        init(_ answer: OutboundConfirmationAnswer) {
            self.answer = answer
        }

        var requests: [OutboundConfirmationRequest] { lock.withLock { recorded } }

        func confirm(_ request: OutboundConfirmationRequest) async -> OutboundConfirmationAnswer {
            lock.withLock { recorded.append(request) }
            return answer
        }
    }

    /// Confirmer whose answers are controlled manually so tests can observe serialization of parallel calls.
    private final class ControlledConfirmer: OutboundConfirming, @unchecked Sendable {
        private struct PendingPrompt {
            let request: OutboundConfirmationRequest
            let continuation: CheckedContinuation<OutboundConfirmationAnswer, Never>
        }

        private let lock = NSLock()
        private var pending: [PendingPrompt] = []
        private var activeCount = 0
        private var maxActiveCount = 0
        private var observedOrder: [String] = []

        var activePromptCount: Int { lock.withLock { activeCount } }
        var peakConcurrentPrompts: Int { lock.withLock { maxActiveCount } }
        var promptActionsInOrder: [String] { lock.withLock { observedOrder } }
        var pendingCount: Int { lock.withLock { pending.count } }

        func confirm(_ request: OutboundConfirmationRequest) async -> OutboundConfirmationAnswer {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    activeCount += 1
                    maxActiveCount = max(maxActiveCount, activeCount)
                    observedOrder.append(request.action)
                    pending.append(PendingPrompt(request: request, continuation: continuation))
                }
            }
        }

        func resolveNext(with answer: OutboundConfirmationAnswer) -> Bool {
            let item: PendingPrompt? = lock.withLock {
                guard !pending.isEmpty else { return nil }
                activeCount -= 1
                return pending.removeFirst()
            }
            guard let item else { return false }
            item.continuation.resume(returning: answer)
            return true
        }
    }

    // MARK: - Model & Persistence

    func testDefaultsToAskWritesOnlyAndPersistsSelection() throws {
        XCTAssertEqual(ApprovalMode.current(defaults: defaults), .askWritesOnly)

        for mode in ApprovalMode.allCases {
            ApprovalMode.setCurrent(mode, defaults: defaults)
            XCTAssertEqual(ApprovalMode.current(defaults: defaults), mode)

            let encoded = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(ApprovalMode.self, from: encoded)
            XCTAssertEqual(decoded, mode)
        }

        defaults.set("unexpectedMode", forKey: ApprovalMode.defaultsKey)
        XCTAssertEqual(ApprovalMode.current(defaults: defaults), .askWritesOnly)
    }

    func testModeClassificationAndDisplayTitles() {
        XCTAssertEqual(
            ApprovalMode.allCases.map(\.title),
            [
                "Ask for Everything",
                "Ask for Writes Only",
                "Ask in Agent (Full Access in iMCP)",
                "Allow Everything",
            ]
        )

        XCTAssertTrue(ApprovalMode.askEverything.requiresConfirmation(isWrite: false))
        XCTAssertTrue(ApprovalMode.askEverything.requiresConfirmation(isWrite: true))

        XCTAssertFalse(ApprovalMode.askWritesOnly.requiresConfirmation(isWrite: false))
        XCTAssertTrue(ApprovalMode.askWritesOnly.requiresConfirmation(isWrite: true))

        XCTAssertFalse(ApprovalMode.agentManaged.requiresConfirmation(isWrite: false))
        XCTAssertFalse(ApprovalMode.agentManaged.requiresConfirmation(isWrite: true))

        XCTAssertFalse(ApprovalMode.allowEverything.requiresConfirmation(isWrite: false))
        XCTAssertFalse(ApprovalMode.allowEverything.requiresConfirmation(isWrite: true))
    }

    // MARK: - Mode 1: Ask for Everything

    func testAskEverythingPromptsForBothReadsAndWrites() async throws {
        ApprovalMode.setCurrent(.askEverything, defaults: defaults)
        let service = FakeService(writesEnabledByDefault: true)
        let confirmer = RecordingConfirmer(.approved)

        let readResult = try await ToolCallApproval.execute(
            tool: service.tool(named: "fake_read"),
            in: service,
            serviceName: "Fake",
            arguments: ["query": "hello"],
            clientName: "Claude Desktop",
            defaults: defaults,
            confirmer: confirmer,
            queue: ToolConfirmationQueue()
        )
        XCTAssertEqual(readResult, "read-ok")
        XCTAssertEqual(service.readCounter.value, 1)
        XCTAssertEqual(service.lastClientName.value, "Claude Desktop")
        XCTAssertTrue(service.lastAlreadyConfirmed.value)

        let writeResult = try await ToolCallApproval.execute(
            tool: service.tool(named: "fake_write"),
            in: service,
            serviceName: "Fake",
            arguments: ["value": "updated"],
            clientName: "Claude Desktop",
            defaults: defaults,
            confirmer: confirmer,
            queue: ToolConfirmationQueue()
        )
        XCTAssertEqual(writeResult, "write-ok")
        XCTAssertEqual(service.writeCounter.value, 1)
        XCTAssertEqual(confirmer.requests.count, 2)
        XCTAssertEqual(confirmer.requests.map(\.action), ["Fetch Fake Data", "Update Fake Data"])
    }

    func testAskEverythingDeclineOrTimeoutBlocksExecution() async {
        ApprovalMode.setCurrent(.askEverything, defaults: defaults)
        let service = FakeService(writesEnabledByDefault: true)

        for (answer, expected) in [
            (OutboundConfirmationAnswer.declined, OutboundConfirmationError.declined(action: "Fetch Fake Data")),
            (.timedOut, .timedOut(action: "Fetch Fake Data")),
            (.busy, .busy(action: "Fetch Fake Data")),
        ] {
            let confirmer = RecordingConfirmer(answer)
            do {
                _ = try await ToolCallApproval.execute(
                    tool: service.tool(named: "fake_read"),
                    in: service,
                    serviceName: "Fake",
                    arguments: [:],
                    clientName: "Claude Code",
                    defaults: defaults,
                    confirmer: confirmer,
                    queue: ToolConfirmationQueue()
                )
                XCTFail("Expected \(expected) to throw")
            } catch {
                XCTAssertEqual(error as? OutboundConfirmationError, expected)
            }
        }

        XCTAssertEqual(service.readCounter.value, 0)
    }

    // MARK: - Mode 2: Ask for Writes Only

    func testAskWritesOnlyRunsReadsImmediatelyAndPromptsForWrites() async throws {
        ApprovalMode.setCurrent(.askWritesOnly, defaults: defaults)
        let service = FakeService(writesEnabledByDefault: true)
        let confirmer = RecordingConfirmer(.approved)

        let readResult = try await ToolCallApproval.execute(
            tool: service.tool(named: "fake_read"),
            in: service,
            serviceName: "Fake",
            arguments: [:],
            clientName: "Claude Desktop",
            defaults: defaults,
            confirmer: confirmer,
            queue: ToolConfirmationQueue()
        )
        XCTAssertEqual(readResult, "read-ok")
        XCTAssertEqual(confirmer.requests.count, 0)
        XCTAssertFalse(service.lastAlreadyConfirmed.value)

        let writeResult = try await ToolCallApproval.execute(
            tool: service.tool(named: "fake_write"),
            in: service,
            serviceName: "Fake",
            arguments: [:],
            clientName: "Claude Desktop",
            defaults: defaults,
            confirmer: confirmer,
            queue: ToolConfirmationQueue()
        )
        XCTAssertEqual(writeResult, "write-ok")
        XCTAssertEqual(confirmer.requests.count, 1)
        XCTAssertTrue(service.lastAlreadyConfirmed.value)

        let unmarkedResult = try await ToolCallApproval.execute(
            tool: service.tool(named: "fake_unmarked"),
            in: service,
            serviceName: "Fake",
            arguments: [:],
            clientName: "Claude Desktop",
            defaults: defaults,
            confirmer: confirmer,
            queue: ToolConfirmationQueue()
        )
        XCTAssertEqual(unmarkedResult, "unmarked-ok")
        XCTAssertEqual(confirmer.requests.count, 2)
    }

    func testWritesDisabledInServiceSettingsRejectsBeforePromptingInAskModes() async {
        for mode in [ApprovalMode.askEverything, .askWritesOnly] {
            ApprovalMode.setCurrent(mode, defaults: defaults)
            let service = FakeService(writesEnabledByDefault: false)
            let confirmer = RecordingConfirmer(.approved)

            do {
                _ = try await ToolCallApproval.execute(
                    tool: service.tool(named: "fake_write"),
                    in: service,
                    serviceName: "Fake",
                    arguments: [:],
                    clientName: "Claude Desktop",
                    defaults: defaults,
                    confirmer: confirmer,
                    queue: ToolConfirmationQueue()
                )
                XCTFail("Expected WritesDisabledError for \(mode)")
            } catch {
                XCTAssertEqual(error as? WritesDisabledError, WritesDisabledError(tool: "fake_write"))
            }
            XCTAssertTrue(confirmer.requests.isEmpty)
            XCTAssertEqual(service.writeCounter.value, 0)
        }
    }

    // MARK: - Modes 3 & 4: Agent-Managed and Allow Everything

    func testFullAccessModesAllowWritesAndSkipConfirmationPopups() async throws {
        for mode in [ApprovalMode.agentManaged, .allowEverything] {
            let service = FakeService(writesEnabledByDefault: false)
            ServiceWrites.setEnabled(false, serviceID: service.serviceID, defaults: defaults)
            ApprovalMode.setCurrent(mode, defaults: defaults)

            XCTAssertTrue(service.areWritesEnabled(defaults: defaults))
            XCTAssertEqual(
                Set(service.listedTools(defaults: defaults).map(\.name)),
                ["fake_read", "fake_write", "fake_unmarked"]
            )

            let confirmer = RecordingConfirmer(.declined)
            let readResult = try await ToolCallApproval.execute(
                tool: service.tool(named: "fake_read"),
                in: service,
                serviceName: "Fake",
                arguments: [:],
                clientName: "Duet",
                defaults: defaults,
                confirmer: confirmer,
                queue: ToolConfirmationQueue()
            )
            let writeResult = try await ToolCallApproval.execute(
                tool: service.tool(named: "fake_write"),
                in: service,
                serviceName: "Fake",
                arguments: [:],
                clientName: "Duet",
                defaults: defaults,
                confirmer: confirmer,
                queue: ToolConfirmationQueue()
            )

            XCTAssertEqual(readResult, "read-ok")
            XCTAssertEqual(writeResult, "write-ok")
            XCTAssertTrue(confirmer.requests.isEmpty)

            let macConfirmer = MacOutboundConfirmer(defaultsSuiteName: suiteName)
            let macAnswer = await macConfirmer.confirm(
                OutboundConfirmationRequest(action: "Send Message", clientName: "Duet", details: [])
            )
            XCTAssertEqual(macAnswer, .approved)
        }

        // Switching back to a prompting mode preserves the stored per-service toggle state.
        ApprovalMode.setCurrent(.askWritesOnly, defaults: defaults)
        let service = FakeService(writesEnabledByDefault: false)
        XCTAssertFalse(service.areWritesEnabled(defaults: defaults))
    }

    // MARK: - Messages Double-Prompt Prevention

    func testMessagesSendDoesNotDoublePromptWhenAlreadyConfirmedByGlobalGate() async throws {
        let innerConfirmer = RecordingConfirmer(.declined)
        let request = MessageService.SendRequest(
            destination: .recipient("+15551234567", .iMessage),
            text: "On my way"
        )
        let identity = MessageService.SendIdentity(
            conversation: "handle:+15551234567",
            service: "imessage",
            text: "On my way"
        )
        let confirmation = OutboundConfirmationRequest(action: "Send Message", clientName: "Claude Code", details: [])
        let deliveredCount = OSAllocatedCounter()

        // When ToolCallContext.alreadyConfirmedByGlobalGate is true, inner confirmer is skipped.
        let result = try await ToolCallContext.$alreadyConfirmedByGlobalGate.withValue(true) {
            try await MessageService.send(
                request,
                identity: identity,
                confirmation: confirmation,
                confirmer: innerConfirmer,
                deliver: { _ in
                    deliveredCount.increment()
                    return nil
                },
                locate: { _, _ in nil },
                inFlight: MessageService.InFlightSends()
            )
        }
        XCTAssertEqual(deliveredCount.value, 1)
        XCTAssertTrue(innerConfirmer.requests.isEmpty)
        XCTAssertEqual(result["@type"], "SendAction")

        // Without the flag, MessageService.send still uses its own confirmer.
        do {
            _ = try await MessageService.send(
                request,
                identity: identity,
                confirmation: confirmation,
                confirmer: innerConfirmer,
                deliver: { _ in
                    XCTFail("Should not deliver when declined")
                    return nil
                },
                locate: { _, _ in nil },
                inFlight: MessageService.InFlightSends()
            )
            XCTFail("Expected declined error")
        } catch {
            XCTAssertEqual(error as? OutboundConfirmationError, .declined(action: "Send Message"))
        }
        XCTAssertEqual(innerConfirmer.requests.count, 1)
    }

    // MARK: - Concurrent Tool Confirmation Queuing

    func testParallelToolCallsQueueCleanlyWithoutBusyFailures() async throws {
        ApprovalMode.setCurrent(.askEverything, defaults: defaults)
        let service = FakeService(writesEnabledByDefault: true)
        let confirmer = ControlledConfirmer()
        let queue = ToolConfirmationQueue()

        let task1 = Task {
            try await ToolCallApproval.execute(
                tool: service.tool(named: "fake_read"),
                in: service,
                serviceName: "Fake",
                arguments: [:],
                clientName: "Claude Code",
                defaults: defaults,
                confirmer: confirmer,
                queue: queue
            )
        }
        await settle(until: { confirmer.pendingCount == 1 })

        let task2 = Task {
            try await ToolCallApproval.execute(
                tool: service.tool(named: "fake_write"),
                in: service,
                serviceName: "Fake",
                arguments: [:],
                clientName: "Claude Code",
                defaults: defaults,
                confirmer: confirmer,
                queue: queue
            )
        }
        await settleAsync(until: { await queue.queuedCount == 1 })

        let task3 = Task {
            try await ToolCallApproval.execute(
                tool: service.tool(named: "fake_unmarked"),
                in: service,
                serviceName: "Fake",
                arguments: [:],
                clientName: "Claude Code",
                defaults: defaults,
                confirmer: confirmer,
                queue: queue
            )
        }
        await settleAsync(until: { await queue.queuedCount == 2 })

        // Only task 1 should be active on screen while tasks 2 and 3 wait in the queue.
        XCTAssertEqual(confirmer.activePromptCount, 1)
        XCTAssertEqual(confirmer.peakConcurrentPrompts, 1)
        XCTAssertEqual(confirmer.promptActionsInOrder, ["Fetch Fake Data"])

        XCTAssertTrue(confirmer.resolveNext(with: .approved))
        let result1 = try await task1.value
        XCTAssertEqual(result1, "read-ok")

        await settle(until: { confirmer.pendingCount == 1 })
        XCTAssertEqual(confirmer.peakConcurrentPrompts, 1)
        XCTAssertEqual(confirmer.promptActionsInOrder, ["Fetch Fake Data", "Update Fake Data"])

        // Decline the second call while keeping the third queued.
        XCTAssertTrue(confirmer.resolveNext(with: .declined))
        do {
            _ = try await task2.value
            XCTFail("Expected second call to be declined")
        } catch {
            XCTAssertEqual(error as? OutboundConfirmationError, .declined(action: "Update Fake Data"))
        }

        await settle(until: { confirmer.pendingCount == 1 })
        XCTAssertEqual(confirmer.peakConcurrentPrompts, 1)
        XCTAssertEqual(
            confirmer.promptActionsInOrder,
            ["Fetch Fake Data", "Update Fake Data", "Run fake_unmarked"]
        )

        XCTAssertTrue(confirmer.resolveNext(with: .approved))
        let result3 = try await task3.value
        XCTAssertEqual(result3, "unmarked-ok")

        XCTAssertEqual(service.readCounter.value, 1)
        XCTAssertEqual(service.writeCounter.value, 0)
        XCTAssertEqual(service.unmarkedCounter.value, 1)
    }

    func testCancellingQueuedToolCallDoesNotPresentConfirmation() async throws {
        ApprovalMode.setCurrent(.askEverything, defaults: defaults)
        let service = FakeService(writesEnabledByDefault: true)
        let confirmer = ControlledConfirmer()
        let queue = ToolConfirmationQueue()

        let first = Task {
            try await ToolCallApproval.execute(
                tool: service.tool(named: "fake_read"),
                in: service,
                serviceName: "Fake",
                arguments: [:],
                clientName: "Muse",
                defaults: defaults,
                confirmer: confirmer,
                queue: queue
            )
        }
        await settle(until: { confirmer.pendingCount == 1 })

        let cancelledTask = Task {
            try await ToolCallApproval.execute(
                tool: service.tool(named: "fake_write"),
                in: service,
                serviceName: "Fake",
                arguments: [:],
                clientName: "Muse",
                defaults: defaults,
                confirmer: confirmer,
                queue: queue
            )
        }
        await settleAsync(until: { await queue.queuedCount == 1 })
        cancelledTask.cancel()

        do {
            _ = try await cancelledTask.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }

        XCTAssertTrue(confirmer.resolveNext(with: .approved))
        let firstValue = try await first.value
        XCTAssertEqual(firstValue, "read-ok")
        XCTAssertEqual(confirmer.promptActionsInOrder, ["Fetch Fake Data"])
        XCTAssertEqual(service.writeCounter.value, 0)
    }

    // MARK: - Confirmation Request Formatting

    func testConfirmationRequestFormatsMessagesAndFallbackTitle() {
        let messagesTool = Tool(
            name: "messages_send",
            description: "Send a message.",
            inputSchema: .object(properties: [:]),
            annotations: .init(title: "Send Message", readOnlyHint: false)
        ) { _ in "ok" }

        let messageRequest = ToolCallApproval.confirmationRequest(
            tool: messagesTool,
            serviceName: "Messages",
            arguments: [
                "recipient": "+15551234567",
                "service": "iMessage",
                "text": "See you at 5",
            ],
            clientName: "Claude Desktop"
        )
        XCTAssertEqual(messageRequest.action, "Send Message")
        XCTAssertEqual(messageRequest.clientName, "Claude Desktop")
        XCTAssertEqual(messageRequest.body, "See you at 5")
        XCTAssertEqual(
            messageRequest.details.map(\.label),
            ["Service", "Tool", "Access", "recipient", "service"]
        )

        let untitledTool = Tool(
            name: "home_accessories_set",
            description: "Control Home.",
            inputSchema: .object(properties: [:]),
            annotations: .init(readOnlyHint: false)
        ) { _ in "ok" }

        let untitledRequest = ToolCallApproval.confirmationRequest(
            tool: untitledTool,
            serviceName: "Home",
            arguments: ["power": true],
            clientName: nil
        )
        XCTAssertEqual(untitledRequest.action, "Run home_accessories_set")
        XCTAssertEqual(untitledRequest.details.map(\.label), ["Service", "Tool", "Access", "power"])
        XCTAssertEqual(untitledRequest.details.last?.value, "true")
    }

    // MARK: - Agent Setup Instructions

    func testAgentInstructionsCoverAllFiveAgentsInModesThreeAndFour() {
        XCTAssertTrue(ApprovalMode.askEverything.agentInstructions.isEmpty)
        XCTAssertTrue(ApprovalMode.askWritesOnly.agentInstructions.isEmpty)

        let expectedAgents = ["Claude Desktop", "Claude Code", "claude.ai", "Duet", "Muse"]
        for mode in [ApprovalMode.agentManaged, .allowEverything] {
            XCTAssertTrue(mode.showsAgentConfigurationHelp)
            XCTAssertNotNil(mode.agentInstructionsHeading)
            XCTAssertEqual(mode.agentInstructions.map(\.agentName), expectedAgents)
            for item in mode.agentInstructions {
                XCTAssertFalse(item.instructions.isEmpty)
                XCTAssertFalse(item.instructions.contains("—"))
                XCTAssertFalse(item.instructions.contains(";"))
            }
        }
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func settleAsync(until condition: () async -> Bool) async {
        for _ in 0 ..< 200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
