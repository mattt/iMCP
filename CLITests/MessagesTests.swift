import AppKit
import Foundation
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
        XCTAssertEqual(request.serviceDescription, "iMessage")
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

    func testChatIDKeepsTheConversationsService() throws {
        let request = try SendRequest(arguments: ["chatId": "iMessage;-;+15551234567", "text": "Hi"])
        XCTAssertEqual(request.destination, .chat("iMessage;-;+15551234567"))
        XCTAssertEqual(request.serviceDescription, "iMessage")

        XCTAssertEqual(
            try SendRequest(arguments: ["chatId": "SMS;-;+15551234567", "text": "Hi"]).serviceDescription,
            "SMS"
        )
        XCTAssertEqual(
            try SendRequest(arguments: ["chatId": "any;+;chat123456", "text": "Hi"]).serviceDescription,
            "Chosen by Messages"
        )
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

    func testDeclinedOrUnansweredSendsNeverDeliver() async {
        let request = SendRequest(destination: .recipient("+15551234567", .iMessage), text: "Hi")

        for (answer, expected) in [
            (MessageService.SendConfirmationAnswer.cancel, SendError.declined),
            (.timeout, .timedOut),
        ] {
            do {
                _ = try await MessageService.send(
                    request,
                    confirm: { answer },
                    deliver: { _ in XCTFail("delivered after \(answer)") },
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
        var delivered: [SendRequest] = []
        var lookupStart: Date?
        let before = Date()
        let sent = OutgoingMessage(
            id: "B6E1F0C2-0000-4000-8000-000000000001",
            chatID: "iMessage;-;+15551234567",
            text: "Hi",
            date: Date(timeIntervalSinceReferenceDate: 800_000_000),
            isFromMe: true
        )

        let result = try await MessageService.send(
            request,
            confirm: { .send },
            deliver: { delivered.append($0) },
            locate: { located, start in
                XCTAssertEqual(located, request)
                lookupStart = start
                return sent
            }
        )

        XCTAssertEqual(delivered, [request])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(lookupStart), before)
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

        let result = try await MessageService.send(
            request,
            confirm: { .send },
            deliver: { _ in },
            locate: { _, _ in nil }
        )

        XCTAssertEqual(result["object"], ["@type": "Message", "text": "Hi"])
        XCTAssertEqual(result["recipient"], ["@id": "+15551234567"])
        XCTAssertTrue(result["description"]?.stringValue?.contains("no @id") == true)
    }

    // MARK: - Finding the sent message

    private let sendStart = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func message(
        _ id: String,
        chat: String? = "any;-;+15551234567",
        text: String = "On my way",
        secondsAfterStart: TimeInterval = 1,
        fromMe: Bool = true
    ) -> OutgoingMessage {
        OutgoingMessage(
            id: id,
            chatID: chat,
            text: text,
            date: sendStart.addingTimeInterval(secondsAfterStart),
            isFromMe: fromMe
        )
    }

    func testSameTextSentTwiceMatchesTheNewestAfterTheSend() {
        let request = SendRequest(destination: .recipient("+15551234567", .SMS), text: "On my way")
        let messages = [
            message("before", secondsAfterStart: -30),
            message("first", secondsAfterStart: 0),
            message("second", secondsAfterStart: 2),
        ]
        XCTAssertEqual(
            MessageService.sentMessage(for: request, sentAfter: sendStart, among: messages)?.id,
            "second"
        )
    }

    func testMessagesFromOthersBeforeTheSendOrElsewhereDoNotMatch() {
        let request = SendRequest(destination: .recipient("+15551234567", .SMS), text: "On my way")
        let messages = [
            message("from them", fromMe: false),
            message("before", secondsAfterStart: -1),
            message("other text", text: "On my way!"),
            message("other chat", chat: "any;-;+15557654321"),
            message("group chat", chat: "any;+;chat123456"),
            message("no chat", chat: nil),
        ]
        XCTAssertNil(MessageService.sentMessage(for: request, sentAfter: sendStart, among: messages))
    }

    func testRecipientsMatchTheirOneToOneConversation() {
        func matches(_ handle: String, _ chat: String) -> Bool {
            SendRequest(destination: .recipient(handle, .iMessage), text: "Hi").isDestination(ofChat: chat)
        }
        XCTAssertTrue(matches("+15551234567", "any;-;+15551234567"))
        XCTAssertTrue(matches("5551234567", "SMS;-;+15551234567"))
        XCTAssertTrue(matches("Jane@Example.com", "iMessage;-;jane@example.com"))
        XCTAssertTrue(matches("12345", "SMS;-;12345"))
        XCTAssertFalse(matches("12345", "SMS;-;912345"))
        XCTAssertFalse(matches("+15551234567", "any;+;+15551234567"))
        XCTAssertFalse(matches("jane@example.com", "any;-;+15551234567"))

        let chat = SendRequest(destination: .chat("any;+;chat123456"), text: "Hi")
        XCTAssertTrue(chat.isDestination(ofChat: "any;+;chat123456"))
        XCTAssertFalse(chat.isDestination(ofChat: "any;+;chat654321"))
    }

    func testTextIsMatchedWithoutSurroundingWhitespace() {
        let request = SendRequest(destination: .chat("any;-;+15551234567"), text: "On my way\n")
        XCTAssertEqual(
            MessageService.sentMessage(for: request, sentAfter: sendStart, among: [message("sent")])?.id,
            "sent"
        )
    }

    func testLookupWaitsForTheMessageToAppear() async {
        let request = SendRequest(destination: .chat("any;-;+15551234567"), text: "On my way")
        var reads = 0
        let found = await MessageService.awaitSentMessage(
            for: request,
            sentAfter: sendStart,
            timeout: .seconds(5),
            interval: .milliseconds(1)
        ) {
            reads += 1
            if reads == 2 { throw CocoaError(.fileReadUnknown) }
            return reads < 3 ? [] : [message("sent")]
        }
        XCTAssertEqual(found?.id, "sent")
        XCTAssertEqual(reads, 3)
    }

    func testLookupGivesUpWithoutAMatchWithinTheTimeout() async {
        let request = SendRequest(destination: .chat("any;-;+15551234567"), text: "On my way")
        let clock = ContinuousClock()
        let started = clock.now
        var reads = 0
        let found = await MessageService.awaitSentMessage(
            for: request,
            sentAfter: sendStart,
            timeout: .milliseconds(100),
            interval: .milliseconds(10)
        ) {
            reads += 1
            return [message("other", text: "Something else")]
        }
        XCTAssertNil(found)
        XCTAssertGreaterThan(reads, 1)
        XCTAssertLessThan(clock.now - started, .seconds(2))
    }

    func testLookupStopsWhenTheDatabaseIsUnreadable() async {
        let request = SendRequest(destination: .chat("any;-;+15551234567"), text: "On my way")
        var reads = 0
        let found = await MessageService.awaitSentMessage(
            for: request,
            sentAfter: sendStart,
            timeout: .seconds(5),
            interval: .milliseconds(1)
        ) {
            reads += 1
            return nil
        }
        XCTAssertNil(found)
        XCTAssertEqual(reads, 1)
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
