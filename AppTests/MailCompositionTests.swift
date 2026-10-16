import Foundation
import Mail
import XCTest

final class MailCompositionTests: XCTestCase {
    func testPackageErrorsPreserveToolGuidance() throws {
        XCTAssertThrowsError(try MailService.shared.mailboxID(from: "INBOX")) { error in
            let description = String(describing: MailToolError(underlying: error))
            XCTAssertTrue(description.contains("@id"))
            XCTAssertTrue(description.contains("\"12\""))
            XCTAssertTrue(description.contains("url field"))
        }
        XCTAssertEqual(try MailService.shared.mailboxID(from: "12"), 12)
        XCTAssertEqual(
            String(
                describing: MailToolError(underlying: Mail.Message.FetchRequest.ValidationError.limitOutOfRange)
            ),
            "Invalid argument: limit must be 1 through 100"
        )
        XCTAssertTrue(MailToolError(underlying: Mail.MailError.databaseBusy).localizedDescription.contains("iMCP"))
    }

    func testCompositionEncodingAndFailure() throws {
        let composition = MailComposition(
            to: "a@example.com,b@example.com",
            cc: "c@example.com",
            bcc: "d@example.com",
            subject: "A & B?#% café",
            body: "one\ntwo &+?#%"
        )
        let url = try composition.url
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:a%40example.com,b%40example.com?cc=c%40example.com&bcc="))
        XCTAssertTrue(url.absoluteString.contains("subject=A%20%26%20B%3F%23%25%20caf%C3%A9"))
        XCTAssertTrue(url.absoluteString.contains("body=one%0D%0Atwo%20%26%2B%3F%23%25"))
        XCTAssertThrowsError(try MailComposition(to: "a@example.com\r\nBcc: x@example.com").url)
        XCTAssertThrowsError(try MailComposition(subject: "Hi\nBcc: x").url)
        XCTAssertThrowsError(try composition.open(using: { _ in false })) { error in
            XCTAssertEqual(error as? MailError, .composeFailed)
        }
        var opened: URL?
        try composition.open {
            opened = $0; return true
        }
        XCTAssertEqual(opened, url)
        XCTAssertEqual(try MailComposition().url.absoluteString, "mailto:")
    }
}
