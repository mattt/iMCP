import AppKit
import Foundation
import MCP
import SwiftUI
import os
import XCTest

final class MessagesTests: XCTestCase {
    private typealias SendRequest = MessageService.SendRequest
    private typealias SendError = MessageService.SendError
    private typealias OutgoingMessage = MessageService.OutgoingMessage

    // MARK: - Arguments

    func testRecipientsAreNormalizedPhoneNumbersOrEmailAddresses() {
        XCTAssertEqual(SendRequest.normalizedRecipient("+1 (555) 123-4567"), "+15551234567")
        XCTAssertEqual(SendRequest.normalizedRecipient(" 555.123.4567 "), "5551234567")
        XCTAssertEqual(SendRequest.normalizedRecipient("12345"), "12345")
        XCTAssertEqual(SendRequest.normalizedRecipient("jane@example.com"), "jane@example.com")

        XCTAssertNil(SendRequest.normalizedRecipient(""))
        XCTAssertNil(SendRequest.normalizedRecipient("Jane Appleseed"))
        XCTAssertNil(SendRequest.normalizedRecipient("12"))
        XCTAssertNil(SendRequest.normalizedRecipient("1234567890123456"))
        XCTAssertNil(SendRequest.normalizedRecipient("555-CALL-NOW"))
        XCTAssertNil(SendRequest.normalizedRecipient("1+5551234567"))
        XCTAssertNil(SendRequest.normalizedRecipient("jane@example"))
        XCTAssertNil(SendRequest.normalizedRecipient("jane @example.com"))
    }

    func testRecipientDefaultsToIMessage() throws {
        let request = try SendRequest(arguments: ["recipient": "+1 555 123 4567", "text": "Hi"])
        XCTAssertEqual(request.destination, .recipient("+15551234567", .iMessage))
        XCTAssertEqual(request.text, "Hi")
    }

    func testServiceIsMatchedWithoutRegardToCase() throws {
        let sms = try SendRequest(arguments: ["recipient": "5551234567", "text": "Hi", "service": "sms"])
        XCTAssertEqual(sms.destination, .recipient("5551234567", .SMS))

        let rcs = try SendRequest(arguments: ["recipient": "5551234567", "text": "Hi", "service": "RCS"])
        XCTAssertEqual(rcs.destination, .recipient("5551234567", .RCS))

        let null = try SendRequest(arguments: ["recipient": "5551234567", "text": "Hi", "service": .null])
        XCTAssertEqual(null.destination, .recipient("5551234567", .iMessage))
    }

    func testTextIsKeptExactly() throws {
        let text = "  Line one\nLine \"two\" & \\three\\  "
        let request = try SendRequest(arguments: ["recipient": "5551234567", "text": .string(text)])
        XCTAssertEqual(request.text, text)
    }

    func testChatIDIsKept() throws {
        let request = try SendRequest(arguments: ["chatId": "any;+;chat123456", "text": "Hi"])
        XCTAssertEqual(request.destination, .chat("any;+;chat123456"))
    }

    // MARK: - Confirmation details

    func testRecipientTargetShowsTheHandleAndService() throws {
        let request = SendRequest(destination: .recipient("+15551234567", .SMS), text: "Hi")
        XCTAssertEqual(
            try MessageService.resolvedTarget(for: request, chat: nil),
            .init(recipient: "+15551234567", conversationID: nil, service: "SMS")
        )
    }

    func testChatTargetShowsItsParticipantsAndService() throws {
        let request = SendRequest(destination: .chat("any;+;chat123456"), text: "Hi")
        let chat = MessageService.ChatDetails(
            displayName: "Book Club",
            participants: ["+15551234567", "jane@example.com"],
            service: "iMessage"
        )
        XCTAssertEqual(
            try MessageService.resolvedTarget(for: request, chat: chat),
            .init(
                recipient: "Book Club (+15551234567, jane@example.com)",
                conversationID: "any;+;chat123456",
                service: "iMessage"
            )
        )
    }

    func testUnresolvedChatsAreBlockedBeforeConfirmation() {
        let request = SendRequest(destination: .chat("any;+;chat123456"), text: "Hi")
        let unresolved: [MessageService.ChatDetails?] = [
            nil,
            .init(displayName: "Book Club", participants: [], service: "iMessage"),
            .init(displayName: nil, participants: ["+15551234567"], service: nil),
            .init(displayName: nil, participants: ["+15551234567"], service: ""),
        ]
        for chat in unresolved {
            XCTAssertThrowsError(
                try MessageService.resolvedTarget(for: request, chat: chat),
                "\(String(describing: chat))"
            ) { error in
                XCTAssertEqual(error as? SendError, .chatUnresolved("any;+;chat123456"))
                XCTAssertTrue(error.localizedDescription.contains("Nothing was sent"), error.localizedDescription)
            }
        }
    }

    func testInvalidArgumentsAreErrors() {
        let cases: [(arguments: [String: Value], message: String)] = [
            (["recipient": "5551234567"], "text is required"),
            (["recipient": "5551234567", "text": " \n "], "text is required"),
            (["recipient": "5551234567", "text": 42], "text must be a string"),
            (["text": "Hi"], "either recipient or chatId"),
            (["recipient": "5551234567", "chatId": "iMessage;-;+15551234567", "text": "Hi"], "not both"),
            (["recipient": "Jane", "text": "Hi"], "phone number or an email address"),
            (["recipient": "5551234567", "text": "Hi", "service": "WhatsApp"], "one of: iMessage, SMS, RCS"),
            (["chatId": "iMessage;-;+15551234567", "text": "Hi", "service": "SMS"], "own service"),
            (["chatId": "+15551234567", "text": "Hi"], "conversation @id"),
            (["chatId": 7, "text": "Hi"], "chatId must be a string"),
        ]

        for (arguments, message) in cases {
            XCTAssertThrowsError(try SendRequest(arguments: arguments), "\(arguments)") { error in
                XCTAssertTrue(
                    error.localizedDescription.contains(message),
                    "\(arguments): \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Apple event

    func testParticipantEventCallsTheHandlerWithTypedParameters() throws {
        let text = "\" & (do shell script \"echo nope\") & \""
        let request = SendRequest(destination: .recipient("+15551234567", .SMS), text: text)
        let event = request.subroutine.event()

        XCTAssertEqual(event.eventClass, fourCharCode("ascr"))
        XCTAssertEqual(event.eventID, fourCharCode("psbr"))
        XCTAssertEqual(event.paramDescriptor(forKeyword: fourCharCode("snam"))?.stringValue, "sendtoparticipant")

        let parameters = try XCTUnwrap(event.paramDescriptor(forKeyword: keyDirectObject))
        XCTAssertEqual(parameters.numberOfItems, 3)
        XCTAssertEqual(parameters.atIndex(1)?.stringValue, text)
        XCTAssertEqual(parameters.atIndex(2)?.stringValue, "+15551234567")
        XCTAssertEqual(parameters.atIndex(3)?.descriptorType, typeEnumerated)
        XCTAssertEqual(parameters.atIndex(3)?.enumCodeValue, fourCharCode("ssms"))
    }

    func testServicesUseTheMessagesDictionaryCodes() {
        XCTAssertEqual(MessageService.SendService.iMessage.serviceTypeCode, fourCharCode("sims"))
        XCTAssertEqual(MessageService.SendService.SMS.serviceTypeCode, fourCharCode("ssms"))
        XCTAssertEqual(MessageService.SendService.RCS.serviceTypeCode, fourCharCode("srcs"))
    }

    func testChatEventCallsTheChatHandler() throws {
        let request = SendRequest(destination: .chat("iMessage;+;chat123456"), text: "Hi")
        let event = request.subroutine.event()

        XCTAssertEqual(event.paramDescriptor(forKeyword: fourCharCode("snam"))?.stringValue, "sendtochat")
        let parameters = try XCTUnwrap(event.paramDescriptor(forKeyword: keyDirectObject))
        XCTAssertEqual(parameters.numberOfItems, 2)
        XCTAssertEqual(parameters.atIndex(1)?.stringValue, "Hi")
        XCTAssertEqual(parameters.atIndex(2)?.stringValue, "iMessage;+;chat123456")
    }

    /// Compiling reads the Messages dictionary but runs nothing.
    @MainActor
    func testSendScriptCompilesAndDefinesTheHandlers() throws {
        let source = MessageService.sendScriptSource
        XCTAssertTrue(source.contains("on sendToParticipant(messageText, recipientHandle, serviceType)"))
        XCTAssertTrue(source.contains("on sendToChat(messageText, chatID)"))
        XCTAssertTrue(source.contains("tell application id \"com.apple.MobileSMS\""))

        let script = try XCTUnwrap(NSAppleScript(source: source))
        var errorInfo: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&errorInfo), String(describing: errorInfo))
    }

    // MARK: - Confirmation

    private func identity(_ request: SendRequest, service: String = "SMS") -> MessageService.SendIdentity {
        switch request.destination {
        case .recipient(let handle, _):
            return .init(conversation: "handle:\(handle.lowercased())", service: service, text: request.text)
        case .chat(let id):
            return .init(conversation: "chat:\(id)", service: service, text: request.text)
        }
    }

    /// Answers every confirmation the same way, and keeps what it was asked.
    private final class Answering: OutboundConfirming, @unchecked Sendable {
        private let answer: OutboundConfirmationAnswer
        private let asked = OSAllocatedUnfairLock(initialState: [OutboundConfirmationRequest]())
        var requests: [OutboundConfirmationRequest] { asked.withLock { $0 } }

        init(_ answer: OutboundConfirmationAnswer) { self.answer = answer }

        func confirm(_ request: OutboundConfirmationRequest) async -> OutboundConfirmationAnswer {
            asked.withLock { $0.append(request) }
            return answer
        }
    }

    /// Opens no window and lets the real timeout run out.
    private struct NeverAnswering: OutboundConfirming {
        let timeout: Duration

        func confirm(_ request: OutboundConfirmationRequest) async -> OutboundConfirmationAnswer {
            await OutboundConfirmation.ask(timeout: timeout, gate: .init()) { _ in {} }
        }
    }

    private let sampleConfirmation = OutboundConfirmationRequest(action: "Send Message", clientName: nil, details: [])

    private func sendWithoutDelivering(
        _ request: SendRequest,
        confirmer: any OutboundConfirming
    ) async -> Error? {
        do {
            _ = try await MessageService.send(
                request,
                identity: identity(request),
                confirmation: sampleConfirmation,
                confirmer: confirmer,
                deliver: { _ in
                    XCTFail("delivered without approval")
                    return nil
                },
                locate: { _, _ in
                    XCTFail("looked for a message without approval")
                    return nil
                }
            )
            XCTFail("expected an error")
            return nil
        } catch {
            return error
        }
    }

    func testDeclinedSendNeverDelivers() async {
        let request = SendRequest(destination: .recipient("+15551234567", .iMessage), text: "Hi")
        let error = await sendWithoutDelivering(request, confirmer: Answering(.declined))
        XCTAssertEqual(error as? OutboundConfirmationError, .declined(action: "Send Message"))
        XCTAssertTrue(error?.localizedDescription.contains("Nothing was done") == true)
    }

    func testUnansweredConfirmationTimesOutAndNeverDelivers() async {
        let request = SendRequest(destination: .recipient("+15551234567", .iMessage), text: "Hi")
        let error = await sendWithoutDelivering(request, confirmer: NeverAnswering(timeout: .milliseconds(50)))
        XCTAssertEqual(error as? OutboundConfirmationError, .timedOut(action: "Send Message"))
    }

    func testBusyConfirmationNeverDelivers() async {
        let request = SendRequest(destination: .recipient("+15551234567", .SMS), text: "Hi")
        let error = await sendWithoutDelivering(request, confirmer: Answering(.busy))
        XCTAssertEqual(error as? OutboundConfirmationError, .busy(action: "Send Message"))
    }

    func testSendAlreadyConfirmedByTheSharedGateDoesNotAskAgain() async throws {
        let request = SendRequest(destination: .chat("iMessage;-;+15551234567"), text: "Hi")
        let confirmer = Answering(.declined)
        var delivered = 0

        _ = try await MessageService.send(
            request,
            identity: identity(request, service: "iMessage"),
            confirmation: sampleConfirmation,
            confirmer: confirmer,
            alreadyConfirmed: true,
            deliver: { _ in
                delivered += 1
                return nil
            },
            locate: { _, _ in nil },
            inFlight: MessageService.InFlightSends()
        )

        XCTAssertEqual(delivered, 1)
        XCTAssertTrue(confirmer.requests.isEmpty)
    }

    func testConfirmedSendDeliversOnceAndReportsTheSentMessage() async throws {
        let request = SendRequest(destination: .chat("iMessage;-;+15551234567"), text: "Hi")
        var events: [String] = []
        let sent = OutgoingMessage(
            rowID: 101,
            id: "B6E1F0C2-0000-4000-8000-000000000001",
            chatID: "iMessage;-;+15551234567",
            service: "iMessage",
            text: "Hi",
            date: Date(timeIntervalSinceReferenceDate: 800_000_000),
            isFromMe: true
        )

        let result = try await MessageService.send(
            request,
            identity: identity(request, service: "iMessage"),
            confirmation: sampleConfirmation,
            confirmer: Answering(.approved),
            deliver: {
                XCTAssertEqual($0, request)
                events.append("deliver")
                return 100
            },
            locate: { located, baseline in
                XCTAssertEqual(located, request)
                events.append("locate after \(baseline)")
                return sent
            },
            inFlight: MessageService.InFlightSends()
        )

        XCTAssertEqual(events, ["deliver", "locate after 100"])
        XCTAssertEqual(result["@type"], "SendAction")
        XCTAssertEqual(result["recipient"], ["@type": "Conversation", "@id": "iMessage;-;+15551234567"])
        XCTAssertEqual(
            result["object"],
            [
                "@type": "Message",
                "@id": "B6E1F0C2-0000-4000-8000-000000000001",
                "text": "Hi",
                "createdAt": .string(sent.date.formatted(.iso8601)),
                "isPartOf": ["@type": "Conversation", "@id": "iMessage;-;+15551234567"],
            ]
        )
        XCTAssertNil(result["description"])
    }

    func testSendWithoutAFoundMessageSucceedsWithoutAnID() async throws {
        let request = SendRequest(destination: .recipient("+15551234567", .SMS), text: "Hi")

        for baseline: Int64? in [nil, 100] {
            var looked = false
            let result = try await MessageService.send(
                request,
                identity: identity(request),
                confirmation: sampleConfirmation,
                confirmer: Answering(.approved),
                deliver: { _ in baseline },
                locate: { _, _ in
                    looked = true
                    return nil
                },
                inFlight: MessageService.InFlightSends()
            )

            // Without a baseline there's nothing to compare rows with, so there's no lookup.
            XCTAssertEqual(looked, baseline != nil)
            XCTAssertEqual(result["object"], ["@type": "Message", "text": "Hi"])
            XCTAssertEqual(result["recipient"], ["@id": "+15551234567"])
            XCTAssertTrue(result["description"]?.stringValue?.contains("no @id") == true)
        }
    }

    private func overlappingSends(
        _ first: (SendRequest, MessageService.SendIdentity),
        _ second: (SendRequest, MessageService.SendIdentity),
        inFlight: MessageService.InFlightSends = .init()
    ) async throws -> (outer: Value?, inner: Value?) {
        func send(
            _ send: (SendRequest, MessageService.SendIdentity),
            during: () async throws -> Void = {}
        ) async throws -> [String: Value] {
            try await MessageService.send(
                send.0,
                identity: send.1,
                confirmation: sampleConfirmation,
                confirmer: Answering(.approved),
                deliver: { _ in
                    try await during()
                    return 100
                },
                locate: { request, _ in
                    OutgoingMessage(
                        rowID: 101,
                        id: "found",
                        chatID: "any;-;+15551234567",
                        service: "SMS",
                        text: request.text,
                        date: .now,
                        isFromMe: true
                    )
                },
                inFlight: inFlight
            )
        }

        // The second send starts and finishes while the first is delivering.
        var inner: [String: Value]?
        let outer = try await send(first) {
            inner = try await send(second)
        }
        return (outer["object"]?.objectValue?["@id"], inner?["object"]?.objectValue?["@id"])
    }

    func testIdenticalOverlappingSendsGetNoID() async throws {
        let request = SendRequest(destination: .chat("any;-;+15551234567"), text: "On my way")
        let other = SendRequest(destination: .chat("any;-;+15551234567"), text: "Running late")
        let inFlight = MessageService.InFlightSends()

        let same = try await overlappingSends(
            (request, identity(request)),
            (request, identity(request)),
            inFlight: inFlight
        )
        XCTAssertNil(same.outer)
        XCTAssertNil(same.inner)

        // Different text doesn't overlap, and a later identical send doesn't either.
        let different = try await overlappingSends(
            (request, identity(request)),
            (other, identity(other)),
            inFlight: inFlight
        )
        XCTAssertEqual(different.outer, "found")
        XCTAssertEqual(different.inner, "found")
        let later = try await overlappingSends(
            (request, identity(request)),
            (other, identity(other)),
            inFlight: inFlight
        )
        XCTAssertEqual(later.outer, "found")
    }

    func testRecipientAndChatIDSendsToOneConversationOverlap() async throws {
        let recipient = SendRequest(destination: .recipient("+15551234567", .SMS), text: "On my way")
        let chat = SendRequest(destination: .chat("any;-;+15551234567"), text: "On my way ")
        let details = MessageService.ChatDetails(displayName: nil, participants: ["+15551234567"], service: "SMS")

        let recipientIdentity = MessageService.sendIdentity(
            for: recipient,
            target: try MessageService.resolvedTarget(for: recipient, chat: nil),
            chat: nil
        )
        let chatIdentity = MessageService.sendIdentity(
            for: chat,
            target: try MessageService.resolvedTarget(for: chat, chat: details),
            chat: details
        )
        XCTAssertEqual(recipientIdentity, chatIdentity)

        let ids = try await overlappingSends((recipient, recipientIdentity), (chat, chatIdentity))
        XCTAssertNil(ids.outer)
        XCTAssertNil(ids.inner)

        // The same conversation on another service doesn't overlap.
        let iMessage = SendRequest(destination: .recipient("+15551234567", .iMessage), text: "On my way")
        let iMessageIdentity = MessageService.sendIdentity(
            for: iMessage,
            target: try MessageService.resolvedTarget(for: iMessage, chat: nil),
            chat: nil
        )
        XCTAssertFalse(iMessageIdentity.mayOverlap(chatIdentity))
    }

    func testEmailCaseVariantsOverlap() async throws {
        let upper = SendRequest(destination: .recipient("Jane@Example.com", .iMessage), text: "Hi")
        let lower = SendRequest(destination: .recipient("jane@example.com", .iMessage), text: "Hi")
        func identity(_ request: SendRequest) throws -> MessageService.SendIdentity {
            MessageService.sendIdentity(
                for: request,
                target: try MessageService.resolvedTarget(for: request, chat: nil),
                chat: nil
            )
        }
        XCTAssertEqual(try identity(upper).conversation, "handle:jane@example.com")
        XCTAssertEqual(try identity(upper), try identity(lower))

        let ids = try await overlappingSends((upper, try identity(upper)), (lower, try identity(lower)))
        XCTAssertNil(ids.outer)
        XCTAssertNil(ids.inner)
    }

    func testOneToOneChatWithAnUnnormalizedHandleFallsBackToItsID() throws {
        let request = SendRequest(destination: .chat("any;-;5551234567"), text: "Hi")
        let details = MessageService.ChatDetails(displayName: nil, participants: ["5551234567"], service: "SMS")
        let identity = MessageService.sendIdentity(
            for: request,
            target: try MessageService.resolvedTarget(for: request, chat: details),
            chat: details
        )
        XCTAssertEqual(identity.conversation, "chat:any;-;5551234567")
    }

    func testUnresolvedConversationsGetNoID() async throws {
        // Without a country code, 5551234567 can't be compared with +15551234567.
        XCTAssertNil(MessageService.normalizedHandle("5551234567"))
        XCTAssertEqual(MessageService.normalizedHandle("+15551234567"), "+15551234567")
        XCTAssertEqual(MessageService.normalizedHandle("12345"), "12345")

        let local = SendRequest(destination: .recipient("5551234567", .SMS), text: "On my way")
        let localIdentity = MessageService.sendIdentity(
            for: local,
            target: try MessageService.resolvedTarget(for: local, chat: nil),
            chat: nil
        )
        XCTAssertNil(localIdentity.conversation)

        // Alone, it gets no @id.
        let alone = try await overlappingSends(
            (local, localIdentity),
            (
                SendRequest(destination: .chat("any;+;chat1"), text: "Other"),
                .init(conversation: "chat:any;+;chat1", service: "SMS", text: "Other")
            )
        )
        XCTAssertNil(alone.outer)
        XCTAssertEqual(alone.inner, "found")

        // It may be the same conversation as a resolved send with the same text and service.
        let resolved = SendRequest(destination: .recipient("+15551234567", .SMS), text: "On my way")
        let both = try await overlappingSends(
            (resolved, identity(resolved)),
            (local, localIdentity)
        )
        XCTAssertNil(both.outer)
        XCTAssertNil(both.inner)
    }

    // MARK: - Delivery checks

    private let approvedChat = MessageService.ChatDetails(
        displayName: "Book Club",
        participants: ["+15551234567", "jane@example.com"],
        service: "iMessage"
    )

    func testChatThatChangedSinceApprovalIsNotSent() {
        let request = SendRequest(destination: .chat("any;+;chat123456"), text: "Hi")
        let changed: [MessageService.ChatDetails?] = [
            nil,
            .init(displayName: "Book Club", participants: ["+15551234567"], service: "iMessage"),
            .init(
                displayName: "Book Club",
                participants: ["+15551234567", "jane@example.com", "+15557654321"],
                service: "iMessage"
            ),
            .init(displayName: "Book Club", participants: ["+15551234567", "jane@example.com"], service: "SMS"),
        ]
        for current in changed {
            var baselineRead = false
            XCTAssertThrowsError(
                try MessageService.prepareDelivery(
                    for: request,
                    approvedChat: approvedChat,
                    currentChat: { current },
                    baseline: {
                        baselineRead = true
                        return 100
                    }
                ),
                "\(String(describing: current))"
            ) { error in
                XCTAssertEqual(error as? SendError, .chatChanged("any;+;chat123456"))
                XCTAssertTrue(error.localizedDescription.contains("changed"), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains("Nothing was sent"), error.localizedDescription)
            }
            XCTAssertFalse(baselineRead)
        }

        // A chat that can't be read again is treated as changed.
        XCTAssertThrowsError(
            try MessageService.prepareDelivery(
                for: request,
                approvedChat: approvedChat,
                currentChat: { throw SendError.unknownChat("any;+;chat123456") },
                baseline: { 100 }
            )
        ) { error in
            XCTAssertEqual(error as? SendError, .chatChanged("any;+;chat123456"))
        }
    }

    func testUnchangedChatIsSentAndReadsTheBaselineLast() throws {
        let request = SendRequest(destination: .chat("any;+;chat123456"), text: "Hi")
        var events: [String] = []
        let rowID = try MessageService.prepareDelivery(
            for: request,
            approvedChat: approvedChat,
            currentChat: {
                events.append("chat")
                // The same people in another order, and a new name, are the same chat.
                return .init(
                    displayName: "Readers",
                    participants: ["jane@example.com", "+15551234567"],
                    service: "iMessage"
                )
            },
            baseline: {
                events.append("baseline")
                return 100
            }
        )
        XCTAssertEqual(rowID, 100)
        XCTAssertEqual(events, ["chat", "baseline"])

        // A recipient send has no chat to check.
        let recipient = SendRequest(destination: .recipient("+15551234567", .SMS), text: "Hi")
        XCTAssertNil(
            try MessageService.prepareDelivery(
                for: recipient,
                approvedChat: nil,
                currentChat: {
                    XCTFail("read a chat for a recipient send")
                    return nil
                },
                baseline: { nil }
            )
        )
    }

    // MARK: - Finding the sent message

    private func message(
        _ id: String,
        rowID: Int64 = 101,
        chat: String? = "any;-;+15551234567",
        service: String? = "SMS",
        text: String = "On my way",
        fromMe: Bool = true
    ) -> OutgoingMessage {
        OutgoingMessage(
            rowID: rowID,
            id: id,
            chatID: chat,
            service: service,
            text: text,
            date: Date(timeIntervalSinceReferenceDate: 800_000_000),
            isFromMe: fromMe
        )
    }

    private func match(
        _ request: SendRequest,
        service: String = "SMS",
        _ messages: [OutgoingMessage]
    ) -> MessageService.SentMessageMatch {
        MessageService.sentMessage(for: request, service: service, after: 100, among: messages)
    }

    func testOnlyRowsNewerThanTheBaselineMatch() {
        let request = SendRequest(destination: .recipient("+15551234567", .SMS), text: "On my way")
        XCTAssertEqual(match(request, [message("old", rowID: 99), message("baseline", rowID: 100)]), .none)
        XCTAssertEqual(
            match(request, [message("old", rowID: 99), message("new", rowID: 101)]),
            .one(message("new", rowID: 101))
        )
    }

    func testSameTextSentTwiceIsAmbiguous() {
        let request = SendRequest(destination: .recipient("+15551234567", .SMS), text: "On my way")
        XCTAssertEqual(
            match(request, [message("first", rowID: 101), message("second", rowID: 102)]),
            .ambiguous
        )
    }

    func testMatchesRequireTheService() {
        let request = SendRequest(destination: .recipient("+15551234567", .SMS), text: "On my way")
        XCTAssertEqual(
            match(request, [message("iMessage", service: "iMessage"), message("none", service: nil)]),
            .none
        )
        XCTAssertEqual(match(request, [message("sms", service: "sms")]), .one(message("sms", service: "sms")))

        let chat = SendRequest(destination: .chat("any;-;+15551234567"), text: "On my way")
        XCTAssertEqual(match(chat, service: "iMessage", [message("sms", service: "SMS")]), .none)
        XCTAssertEqual(
            match(chat, service: "iMessage", [message("imessage", service: "iMessage")]),
            .one(message("imessage", service: "iMessage"))
        )
    }

    func testMessagesFromOthersOrElsewhereDoNotMatch() {
        let request = SendRequest(destination: .recipient("+15551234567", .SMS), text: "On my way")
        let messages = [
            message("from them", fromMe: false),
            message("other text", text: "On my way!"),
            message("other chat", chat: "any;-;+15557654321"),
            message("group chat", chat: "any;+;chat123456"),
            message("no chat", chat: nil),
        ]
        XCTAssertEqual(match(request, messages), .none)
    }

    func testRecipientsMatchTheirOneToOneConversationExactly() {
        func matches(_ handle: String, _ chat: String) -> Bool {
            SendRequest(destination: .recipient(handle, .iMessage), text: "Hi").isDestination(ofChat: chat)
        }
        XCTAssertTrue(matches("+15551234567", "any;-;+15551234567"))
        XCTAssertTrue(matches("Jane@Example.com", "iMessage;-;jane@example.com"))
        XCTAssertTrue(matches("12345", "SMS;-;12345"))
        XCTAssertFalse(matches("5551234567", "SMS;-;+15551234567"))
        XCTAssertFalse(matches("12345", "SMS;-;912345"))
        XCTAssertFalse(matches("+15551234567", "any;+;+15551234567"))
        XCTAssertFalse(matches("jane@example.com", "any;-;+15551234567"))

        let chat = SendRequest(destination: .chat("any;+;chat123456"), text: "Hi")
        XCTAssertTrue(chat.isDestination(ofChat: "any;+;chat123456"))
        XCTAssertFalse(chat.isDestination(ofChat: "any;+;chat654321"))
    }

    func testTextIsMatchedWithoutSurroundingWhitespace() {
        let request = SendRequest(destination: .chat("any;-;+15551234567"), text: "On my way\n")
        XCTAssertEqual(match(request, [message("sent")]), .one(message("sent")))
    }

    private func awaitSentMessage(
        timeout: Duration = .seconds(5),
        interval: Duration = .milliseconds(1),
        read: () throws -> [OutgoingMessage]?
    ) async -> OutgoingMessage? {
        await MessageService.awaitSentMessage(
            for: SendRequest(destination: .chat("any;-;+15551234567"), text: "On my way"),
            service: "SMS",
            after: 100,
            timeout: timeout,
            interval: interval,
            read: read
        )
    }

    func testLookupWaitsForTheMessageToAppear() async {
        var reads = 0
        let found = await awaitSentMessage {
            reads += 1
            if reads == 2 { throw CocoaError(.fileReadUnknown) }
            return reads < 3 ? [] : [message("sent")]
        }
        XCTAssertEqual(found?.id, "sent")
        XCTAssertEqual(reads, 3)
    }

    func testLookupGivesUpWithoutAMatchWithinTheTimeout() async {
        let clock = ContinuousClock()
        let started = clock.now
        var reads = 0
        let found = await awaitSentMessage(timeout: .milliseconds(100), interval: .milliseconds(10)) {
            reads += 1
            return [message("other", text: "Something else")]
        }
        XCTAssertNil(found)
        XCTAssertGreaterThan(reads, 1)
        XCTAssertLessThan(clock.now - started, .seconds(2))
    }

    func testLookupStopsWhenTheDatabaseIsUnreadableOrTheMatchIsAmbiguous() async {
        var reads = 0
        let unreadable = await awaitSentMessage {
            reads += 1
            return nil
        }
        XCTAssertNil(unreadable)
        XCTAssertEqual(reads, 1)

        reads = 0
        let ambiguous = await awaitSentMessage {
            reads += 1
            return [message("first", rowID: 101), message("second", rowID: 102)]
        }
        XCTAssertNil(ambiguous)
        XCTAssertEqual(reads, 1)
    }

    func testLookupStopsWhenCancelled() async {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let firstRead = expectation(description: "first read")
        let task = Task {
            await MessageService.awaitSentMessage(
                for: SendRequest(destination: .chat("any;-;+15551234567"), text: "On my way"),
                service: "SMS",
                after: 100,
                timeout: .seconds(30),
                interval: .seconds(10)
            ) {
                if reads.withLock({ count in
                    count += 1
                    return count
                }) == 1 {
                    firstRead.fulfill()
                }
                return []
            }
        }
        await fulfillment(of: [firstRead], timeout: 5)
        let clock = ContinuousClock()
        let cancelled = clock.now
        task.cancel()
        let found = await task.value
        XCTAssertNil(found)
        XCTAssertEqual(reads.withLock { $0 }, 1)
        XCTAssertLessThan(clock.now - cancelled, .seconds(2))
    }

    @MainActor
    func testLongOrUnusualTextKeepsTheWindowSize() {
        _ = NSApplication.shared
        func size(_ text: String) -> NSSize {
            let view = OutboundConfirmationView(
                request: MessageService.confirmation(
                    for: SendRequest(destination: .recipient("+15551234567", .SMS), text: text),
                    target: .init(recipient: "+15551234567", conversationID: nil, service: "SMS"),
                    clientName: "Claude"
                ),
                onApprove: {},
                onDecline: {}
            )
            return NSHostingView(rootView: view).fittingSize
        }
        let short = size("Hi")
        for text in [
            String(repeating: "x", count: 20_000),
            String(repeating: "line\n", count: 2_000),
            "\u{202E}" + String(repeating: "To: +15559999999 ", count: 500),
        ] {
            let measured = size(text)
            XCTAssertEqual(measured.width, short.width, accuracy: 0.5)
            XCTAssertLessThanOrEqual(measured.height, short.height + 200)
        }
    }

    // MARK: - Errors

    func testAppleScriptErrorsAreDescribed() {
        let participant = SendRequest(destination: .recipient("+15551234567", .SMS), text: "Hi")
        let chat = SendRequest(destination: .chat("iMessage;-;+15551234567"), text: "Hi")
        func error(_ number: Int, _ message: String = "message") -> NSAppleScript.ExecutionError {
            NSAppleScript.ExecutionError(number: number, message: message)
        }

        let notAuthorized = SendError(error(-1743), request: participant)
        XCTAssertEqual(notAuthorized, .notAuthorized)
        XCTAssertTrue(notAuthorized.localizedDescription.contains("Privacy & Security > Automation"))

        XCTAssertEqual(SendError(error(-1728), request: chat), .unknownChat("iMessage;-;+15551234567"))
        XCTAssertEqual(
            SendError(error(-1728), request: participant),
            .noAccountOrRecipient("+15551234567", .SMS)
        )
        XCTAssertEqual(
            SendError(error(-1719), request: participant),
            .noAccountOrRecipient("+15551234567", .SMS)
        )
        XCTAssertEqual(
            SendError(error(-1712, "AppleEvent timed out."), request: chat),
            .appleScript(number: -1712, message: "AppleEvent timed out.")
        )
    }

    // MARK: - AppleScript

    /// A handler receives hostile text as a value: the script that would run it never does.
    /// These scripts send no Apple events to other apps.
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

    func testBeforeSendingRunsImmediatelyBeforeTheScript() async throws {
        // The hook runs on the queue before the script, which still returns its result.
        let marker = OSAllocatedUnfairLock(initialState: 0)
        let result = try await NSAppleScript.execute("return 7") {
            marker.withLock { $0 = 1 }
        }
        XCTAssertEqual(result.int32Value, 7)
        XCTAssertEqual(marker.withLock { $0 }, 1)

        // When the hook throws, the script doesn't run.
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
            return try await NSAppleScript.execute("return 2") { called.withLock { $0 = true } }.int32Value
        }
        _ = try? await task.value
        XCTAssertFalse(called.withLock { $0 })
    }

    // MARK: - Tool

    func testSendToolIsAnnotatedAsDestructive() throws {
        let tool = try XCTUnwrap(MessageService.shared.tools.first { $0.name == "messages_send" })
        XCTAssertEqual(tool.annotations.readOnlyHint, false)
        XCTAssertEqual(tool.annotations.destructiveHint, true)
        XCTAssertEqual(tool.annotations.idempotentHint, false)
        XCTAssertEqual(tool.annotations.openWorldHint, true)
    }

    func testSendToolDescribesTheContractAndTheDeliveryCheck() throws {
        let tool = try XCTUnwrap(MessageService.shared.tools.first { $0.name == "messages_send" })
        XCTAssertTrue(tool.description.contains("Give exactly one destination"), tool.description)
        XCTAssertTrue(tool.description.contains("without service"), tool.description)
        XCTAssertTrue(tool.description.contains("50 seconds"), tool.description)
        XCTAssertTrue(tool.description.contains("isDelivered"), tool.description)
        XCTAssertTrue(tool.description.contains("with that @id"), tool.description)
        XCTAssertTrue(tool.description.contains("best match found"), tool.description)
        XCTAssertFalse(tool.description.contains("by recipient, text, and time"), tool.description)

        let fetch = try XCTUnwrap(MessageService.shared.tools.first { $0.name == "messages_fetch" })
        XCTAssertTrue(fetch.description.contains("isDelivered"), fetch.description)
    }

    // MARK: - Allow writes and the confirmation

    private func writesDefaults(enabled: Bool?) throws -> UserDefaults {
        let name = "MessagesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        if let enabled {
            ServiceWrites.setEnabled(enabled, serviceID: "MessageService", defaults: defaults)
        }
        return defaults
    }

    func testMessagesWritesAreOffUntilTheUserTurnsThemOn() throws {
        let service = MessageService(confirmer: Answering(.approved), automationCheck: {})
        XCTAssertFalse(service.writesEnabledByDefault)
        XCTAssertEqual(service.writeToolNames, ["messages_send"])
        XCTAssertFalse(service.areWritesEnabled(defaults: try writesDefaults(enabled: nil)))
        XCTAssertTrue(service.areWritesEnabled(defaults: try writesDefaults(enabled: true)))
    }

    func testWithWritesOffSendIsHiddenAndRefusedWithoutAsking() async throws {
        let confirmer = Answering(.approved)
        let service = MessageService(confirmer: confirmer, automationCheck: {})
        let defaults = try writesDefaults(enabled: nil)

        let listed = Set(service.listedTools(defaults: defaults).map(\.name))
        XCTAssertFalse(listed.contains("messages_send"))
        XCTAssertTrue(listed.contains("messages_fetch"))

        do {
            _ = try await service.call(
                tool: "messages_send",
                with: ["recipient": "+15551234567", "text": "Hi"],
                defaults: defaults
            )
            XCTFail("expected the call to be refused")
        } catch {
            XCTAssertEqual(error as? WritesDisabledError, WritesDisabledError(tool: "messages_send"))
        }
        XCTAssertTrue(confirmer.requests.isEmpty)
    }

    func testWithWritesOnSendIsListed() throws {
        let service = MessageService(confirmer: Answering(.approved), automationCheck: {})
        let listed = Set(service.listedTools(defaults: try writesDefaults(enabled: true)).map(\.name))
        XCTAssertTrue(listed.contains("messages_send"))
    }

    func testInvalidCallFailsBeforeAskingTheUser() async throws {
        let confirmer = Answering(.approved)
        let service = MessageService(confirmer: confirmer, automationCheck: {})
        do {
            _ = try await service.call(
                tool: "messages_send",
                with: ["recipient": "Jane", "text": "Hi"],
                defaults: try writesDefaults(enabled: true)
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("phone number"), error.localizedDescription)
        }
        XCTAssertTrue(confirmer.requests.isEmpty)
    }

    /// The tool asks once, names the connected client, and a decline sends nothing:
    /// a decline can't reach Messages, so this runs the real tool.
    func testToolAsksOnceWithTheClientNameAndTheFullRequest() async throws {
        let confirmer = Answering(.declined)
        let service = MessageService(confirmer: confirmer, automationCheck: {})
        let text = String(repeating: "Long line of text. ", count: 100) + "\nSecond line"
        do {
            _ = try await ToolCallContext.$clientName.withValue("Claude Desktop") {
                try await service.call(
                    tool: "messages_send",
                    with: ["recipient": "+1 (555) 123-4567", "text": .string(text), "service": "SMS"],
                    defaults: try writesDefaults(enabled: true)
                )
            }
            XCTFail("expected a decline")
        } catch {
            XCTAssertEqual(error as? OutboundConfirmationError, .declined(action: "Send Message"))
        }

        let request = try XCTUnwrap(confirmer.requests.first)
        XCTAssertEqual(confirmer.requests.count, 1)
        XCTAssertEqual(request.clientName, "Claude Desktop")
        XCTAssertEqual(request.body, text)
        XCTAssertEqual(request.details.map(\.label), ["To", "Service"])
        XCTAssertEqual(request.details.map(\.value), ["+15551234567", "SMS"])
    }

    func testAutomationDenialIsReportedBeforeAsking() async throws {
        let confirmer = Answering(.approved)
        let service = MessageService(confirmer: confirmer, automationCheck: { throw SendError.notAuthorized })
        do {
            _ = try await service.call(
                tool: "messages_send",
                with: ["recipient": "+15551234567", "text": "Hi"],
                defaults: try writesDefaults(enabled: true)
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SendError, .notAuthorized)
        }
        XCTAssertTrue(confirmer.requests.isEmpty)
    }

    func testConfirmationShowsEveryHandleAndTheWholeText() throws {
        let handles = (0 ..< 40).map { "+1555000\(String(format: "%04d", $0))" }
        let request = SendRequest(destination: .chat("any;+;chat123456"), text: "x")
        let target = try MessageService.resolvedTarget(
            for: request,
            chat: .init(displayName: "Crew", participants: handles, service: "iMessage")
        )
        let text = "  Line one\n\nLine \"two\"  " + String(repeating: "y", count: 5000)
        let confirmation = MessageService.confirmation(
            for: SendRequest(destination: .chat("any;+;chat123456"), text: text),
            target: target,
            clientName: "Evil\nTo: +15559999999"
        )

        XCTAssertEqual(confirmation.action, "Send Message")
        XCTAssertEqual(confirmation.clientName, "Evil To: +15559999999")
        XCTAssertEqual(confirmation.body, text, "the body is exactly what is sent")
        let to = try XCTUnwrap(confirmation.details.first { $0.label == "To" }).value
        for handle in handles {
            XCTAssertTrue(to.contains(handle), "\(handle) is missing from \(to)")
        }
        XCTAssertTrue(confirmation.details.contains { $0.label == "Conversation" && $0.value == "any;+;chat123456" })
        XCTAssertTrue(confirmation.details.contains { $0.label == "Service" && $0.value == "iMessage" })
    }

    private func fourCharCode(_ string: String) -> FourCharCode {
        string.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
