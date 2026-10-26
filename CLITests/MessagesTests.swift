import AppKit
import Foundation
import XCTest

final class MessagesTests: XCTestCase {
    private typealias SendRequest = MessageService.SendRequest
    private typealias SendError = MessageService.SendError

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
                    deliver: { _ in XCTFail("delivered after \(answer)") }
                )
                XCTFail("expected an error after \(answer)")
            } catch {
                XCTAssertEqual(error as? SendError, expected)
                XCTAssertTrue(error.localizedDescription.contains("declined"), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains("Nothing was sent"), error.localizedDescription)
            }
        }
    }

    func testConfirmedSendDeliversOnce() async throws {
        let request = SendRequest(destination: .chat("iMessage;-;+15551234567"), text: "Hi")
        var delivered: [SendRequest] = []

        let result = try await MessageService.send(
            request,
            confirm: { .send },
            deliver: { delivered.append($0) }
        )

        XCTAssertEqual(delivered, [request])
        XCTAssertEqual(result["@type"], "SendAction")
        XCTAssertEqual(result["recipient"], ["@type": "Conversation", "@id": "iMessage;-;+15551234567"])
        XCTAssertEqual(result["object"], ["@type": "Message", "text": "Hi"])
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
        func info(_ number: Int, _ message: String = "message") -> NSDictionary {
            [NSAppleScript.errorNumber: NSNumber(value: number), NSAppleScript.errorMessage: message]
        }

        let notAuthorized = SendError(errorInfo: info(-1743), request: participant)
        XCTAssertEqual(notAuthorized, .notAuthorized)
        XCTAssertTrue(notAuthorized.localizedDescription.contains("Privacy & Security > Automation"))

        XCTAssertEqual(SendError(errorInfo: info(-1728), request: chat), .unknownChat("iMessage;-;+15551234567"))
        XCTAssertEqual(
            SendError(errorInfo: info(-1728), request: participant),
            .noAccountOrRecipient("+15551234567", .SMS)
        )
        XCTAssertEqual(
            SendError(errorInfo: info(-1719), request: participant),
            .noAccountOrRecipient("+15551234567", .SMS)
        )
        XCTAssertEqual(
            SendError(errorInfo: info(-1712, "AppleEvent timed out."), request: chat),
            .appleScript(number: -1712, message: "AppleEvent timed out.")
        )
    }

    // MARK: - Tool

    func testSendToolIsAnnotatedAsDestructive() throws {
        let tool = try XCTUnwrap(MessageService.shared.tools.first { $0.name == "messages_send" })
        XCTAssertEqual(tool.annotations.readOnlyHint, false)
        XCTAssertEqual(tool.annotations.destructiveHint, true)
        XCTAssertEqual(tool.annotations.idempotentHint, false)
        XCTAssertEqual(tool.annotations.openWorldHint, true)
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
