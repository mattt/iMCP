import AppKit
import Foundation
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
        let event = request.handlerEvent

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
        let event = request.handlerEvent

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

    func testDeclinedOrUnansweredSendsNeverDeliver() async {
        let request = SendRequest(destination: .recipient("+15551234567", .iMessage), text: "Hi")

        for (answer, expected) in [
            (MessageService.SendConfirmationAnswer.cancel, SendError.declined),
            (.timeout, .timedOut),
        ] {
            do {
                _ = try await MessageService.send(
                    request,
                    identity: identity(request),
                    confirm: { answer },
                    deliver: { _ in
                        XCTFail("delivered after \(answer)")
                        return nil
                    },
                    locate: { _, _ in
                        XCTFail("looked for a message after \(answer)")
                        return nil
                    }
                )
                XCTFail("expected an error after \(answer)")
            } catch {
                XCTAssertEqual(error as? SendError, expected)
                let description = answer == .timeout ? "confirmation timed out" : "declined"
                XCTAssertTrue(error.localizedDescription.contains(description), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains("Nothing was sent"), error.localizedDescription)
            }
        }
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
            confirm: { .send },
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
                confirm: { .send },
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
                confirm: { .send },
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
    func testOneConfirmationIsShownAtATime() async {
        let gate = MessageService.SendConfirmationGate()
        var respond: ((Bool) -> Void)?
        let first = Task { @MainActor in
            await MessageService.askForConfirmation(timeout: .seconds(10), gate: gate) { answer in
                respond = answer
                return {}
            }
        }
        while respond == nil { await Task.yield() }
        XCTAssertTrue(gate.isOpen)

        var presentedSecond = false
        let second = await MessageService.askForConfirmation(timeout: .seconds(10), gate: gate) { _ in
            presentedSecond = true
            return {}
        }
        XCTAssertEqual(second, .busy)
        XCTAssertFalse(presentedSecond)

        respond?(true)
        let firstAnswer = await first.value
        XCTAssertEqual(firstAnswer, .send)
        XCTAssertFalse(gate.isOpen)

        // Once the first is answered, the next is shown, and its timeout starts then.
        var presentedThird = false
        let third = await MessageService.askForConfirmation(timeout: .milliseconds(20), gate: gate) { _ in
            presentedThird = true
            return {}
        }
        XCTAssertTrue(presentedThird)
        XCTAssertEqual(third, .timeout)
        XCTAssertFalse(gate.isOpen)
    }

    func testBusyConfirmationSendsNothing() async {
        let request = SendRequest(destination: .recipient("+15551234567", .SMS), text: "Hi")
        do {
            _ = try await MessageService.send(
                request,
                identity: identity(request),
                confirm: { .busy },
                deliver: { _ in
                    XCTFail("delivered while another confirmation was open")
                    return nil
                },
                locate: { _, _ in nil }
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SendError, .confirmationBusy)
            XCTAssertTrue(error.localizedDescription.contains("Another message"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Nothing was sent"), error.localizedDescription)
        }
    }

    @MainActor
    func testClosingTheWindowCancelsAndOnlyTheFirstAnswerCounts() throws {
        _ = NSApplication.shared
        let controller = MessageSendConfirmationWindowController(showsWindows: false)
        let confirmation = MessageSendConfirmation(
            clientName: "Claude",
            recipient: "+15551234567",
            conversationID: nil,
            service: "SMS",
            text: "Hi"
        )

        var answers: [Bool] = []
        _ = controller.show(confirmation) { answers.append($0) }
        let closed = try XCTUnwrap(controller.openConfirmationIDs.first)
        let window = try XCTUnwrap(controller.window(for: closed))
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        controller.answer(closed, true)
        XCTAssertEqual(answers, [false])
        XCTAssertTrue(controller.openConfirmationIDs.isEmpty)

        answers = []
        _ = controller.show(confirmation) { answers.append($0) }
        let sent = try XCTUnwrap(controller.openConfirmationIDs.first)
        controller.answer(sent, true)
        controller.answer(sent, false)
        XCTAssertEqual(answers, [true])

        // Dismissing without an answer, as a timeout does, reports nothing.
        answers = []
        let dismiss = controller.show(confirmation) { answers.append($0) }
        dismiss()
        XCTAssertEqual(answers, [])
        XCTAssertTrue(controller.openConfirmationIDs.isEmpty)
    }

    // MARK: - Displayed text

    func testDisplayedStringsAreOneShortLine() {
        let sanitized = MessageSendConfirmation.sanitized
        XCTAssertEqual(sanitized("Claude\nTo: +15559999999", 60), "Claude To: +15559999999")
        XCTAssertEqual(sanitized("  Claude \t\r\n\u{2028} Desktop  ", 60), "Claude Desktop")
        XCTAssertEqual(sanitized("\u{202E}tpircs\u{202C} \u{2066}a\u{2069}\u{200F}b\u{061C}", 60), "tpircs ab")
        XCTAssertEqual(sanitized("bell\u{07}\u{1B}[31m", 60), "bell[31m")
        XCTAssertEqual(sanitized("👩‍👩‍👧 Family", 60), "👩‍👩‍👧 Family")
        XCTAssertEqual(sanitized(String(repeating: "a", count: 100), 10), "aaaaaaaaa…")
        XCTAssertEqual(sanitized("short", 10), "short")
        XCTAssertEqual(sanitized("\n\u{202E}\n", 10), "")
    }

    func testConfirmationSanitizesEverythingButTheText() {
        let text = "Line one\n\u{202E}Line two\tend"
        let confirmation = MessageSendConfirmation(
            clientName: "Evil\nTo: +15559999999\u{202E}",
            recipient: "+15551234567\n",
            conversationID: "any;-;+15551234567\u{2066}",
            service: "SMS\n",
            text: text
        )
        XCTAssertEqual(confirmation.clientName, "Evil To: +15559999999")
        XCTAssertEqual(confirmation.recipient, "+15551234567")
        XCTAssertEqual(confirmation.conversationID, "any;-;+15551234567")
        XCTAssertEqual(confirmation.service, "SMS")
        XCTAssertEqual(confirmation.text, text)

        let blankClient = MessageSendConfirmation(
            clientName: " \n\u{202E} ",
            recipient: "+15551234567",
            conversationID: nil,
            service: "SMS",
            text: "Hi"
        )
        XCTAssertNil(blankClient.clientName)
        XCTAssertEqual(
            MessageSendConfirmation(
                clientName: String(repeating: "c", count: 200),
                recipient: "+15551234567",
                conversationID: nil,
                service: "SMS",
                text: "Hi"
            ).clientName?.count,
            60
        )
    }

    func testGroupNamesAreShortenedToOneLine() throws {
        let request = SendRequest(destination: .chat("any;+;chat123456"), text: "Hi")
        let chat = MessageService.ChatDetails(
            displayName: "Book Club\nTo: +15559999999\u{202E}" + String(repeating: "x", count: 200),
            participants: ["+15551234567"],
            service: "iMessage"
        )
        let target = try MessageService.resolvedTarget(for: request, chat: chat)
        XCTAssertFalse(target.recipient.contains("\n"))
        XCTAssertFalse(target.recipient.unicodeScalars.contains { $0.properties.isBidiControl })
        XCTAssertTrue(target.recipient.hasPrefix("Book Club To: +15559999999xxx"), target.recipient)
        XCTAssertTrue(target.recipient.hasSuffix("… (+15551234567)"), target.recipient)
        XCTAssertEqual(target.recipient.count, 80 + " (+15551234567)".count)
    }

    @MainActor
    func testLongOrUnusualTextKeepsTheWindowSize() {
        _ = NSApplication.shared
        func size(_ text: String) -> NSSize {
            let view = MessageSendConfirmationView(
                confirmation: MessageSendConfirmation(
                    clientName: "Claude",
                    recipient: "+15551234567",
                    conversationID: nil,
                    service: "SMS",
                    text: text
                ),
                onSend: {},
                onCancel: {}
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

    @MainActor
    func testUnansweredConfirmationTimesOutAndCloses() async {
        var dismissals = 0
        let answer = await MessageService.askForConfirmation(timeout: .milliseconds(50)) { _ in
            { dismissals += 1 }
        }
        XCTAssertEqual(answer, .timeout)
        XCTAssertEqual(dismissals, 1)
    }

    @MainActor
    func testFirstAnswerWins() async {
        var respond: ((Bool) -> Void)?
        let answer = await MessageService.askForConfirmation(timeout: .seconds(10)) { answer in
            respond = answer
            Task { @MainActor in
                respond?(false)
                respond?(true)
            }
            return {}
        }
        XCTAssertEqual(answer, .cancel)
    }

    @MainActor
    func testSendAnswerIsReported() async {
        let answer = await MessageService.askForConfirmation(timeout: .seconds(10)) { answer in
            answer(true)
            return {}
        }
        XCTAssertEqual(answer, .send)
    }

    @MainActor
    func testCancelledCallClosesTheConfirmation() async {
        let dismissed = expectation(description: "dismissed")
        let task = Task { @MainActor in
            await MessageService.askForConfirmation(timeout: .seconds(10)) { _ in
                { dismissed.fulfill() }
            }
        }
        await Task.yield()
        task.cancel()
        let answer = await task.value
        XCTAssertEqual(answer, .cancel)
        await fulfillment(of: [dismissed], timeout: 1)
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

    /// These scripts send no Apple events to other apps.
    func testScriptsRunAndCallHandlersOffTheMainThread() async throws {
        let sum = try await NSAppleScript.execute("return 1 + 1")
        XCTAssertEqual(sum.int32Value, 2)

        let doubled = try await NSAppleScript.execute(
            """
            on doubleIt(x)
                return x * 2
            end doubleIt
            """,
            calling: MessageService.handlerEvent(named: "doubleIt", parameters: [NSAppleEventDescriptor(int32: 21)])
        )
        XCTAssertEqual(doubled.int32Value, 42)
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

    func testInvalidCallFailsBeforeAskingTheUser() async {
        do {
            _ = try await MessageService.shared.call(tool: "messages_send", with: ["recipient": "Jane", "text": "Hi"])
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("phone number"), error.localizedDescription)
        }
    }

    private func fourCharCode(_ string: String) -> FourCharCode {
        string.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
