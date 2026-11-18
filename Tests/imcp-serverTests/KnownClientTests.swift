import XCTest

final class KnownClientTests: XCTestCase {
    func testKnownClientsAreMatchedByTheNameTheyReport() {
        XCTAssertEqual(KnownClient.match(name: "Claude Desktop"), .claudeDesktop)
        XCTAssertEqual(KnownClient.match(name: "claude-code"), .claudeCode)
        XCTAssertEqual(KnownClient.match(name: "Claude Code (CLI)"), .claudeCode)
        XCTAssertEqual(KnownClient.match(name: "Claude Duet"), .claudeDuet)
        XCTAssertEqual(KnownClient.match(name: "Claude"), .claudeAI)
        XCTAssertEqual(KnownClient.match(name: "Muse"), .muse)
        XCTAssertEqual(KnownClient.match(name: "Gemini CLI"), .gemini)
        XCTAssertNil(KnownClient.match(name: "Some Other Tool"))
    }

    func testEachKnownAppHasItsLogo() {
        XCTAssertEqual(KnownClient.claudeDesktop.logoAsset, "ConnectorClaude")
        XCTAssertEqual(KnownClient.claudeDuet.logoAsset, "ConnectorClaudeDuet")
        XCTAssertEqual(KnownClient.muse.logoAsset, "ConnectorMuse")
        XCTAssertEqual(KnownClient.gemini.logoAsset, "ConnectorGemini")
        XCTAssertEqual(KnownClient.claudeCode.logoAsset, "ConnectorClaudeCode")
    }
}
