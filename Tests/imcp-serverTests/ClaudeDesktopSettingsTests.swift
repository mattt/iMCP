import Foundation
import XCTest

final class ClaudeDesktopSettingsTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("settings.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func update() throws {
        try ClaudeDesktopSettings.update(at: url, command: "/fixture/imcp-server")
    }

    func testMissingFileCreatesPrivateSettingsWithoutCredential() throws {
        try update()

        let expected = ["mcpServers": ["iMCP": ["command": "/fixture/imcp-server"]]]
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary
        XCTAssertEqual(saved, expected as NSDictionary)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testUpdateKeepsExistingCredentialAndOtherSettings() throws {
        let edited = """
            {
              "preferences": {"zoom": 1.25, "theme": null},
              "mcpServers": {
                "other": {"url": "https://fixture.invalid", "enabled": false},
                "iMCP": {
                  "command": "previous", "args": ["--example"], "future": [1, true],
                  "env": {"OTHER": "data:text/plain;base64,QQ==", "\(ClientCredential.environmentVariable)": "edited"}
                }
              }
            }
            """
        try Data(edited.utf8).write(to: url)
        try update()

        let expected = edited.replacingOccurrences(of: "\"previous\"", with: "\"/fixture/imcp-server\"")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary
        XCTAssertEqual(saved, try JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary)
    }

    func testMalformedSettingsRemainUntouched() throws {
        for text in [
            "", "{", "[]", #"{"mcpServers":null}"#, #"{"mcpServers":{"iMCP":[]}}"#,
            #"{"mcpServers":{"iMCP":{"env":false}}}"#,
        ] {
            let original = Data(text.utf8)
            try original.write(to: url)
            XCTAssertThrowsError(try update(), text)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testUnreadableFileRemainsUntouched() throws {
        let original = Data(#"{"keep":true}"#.utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: url.path)
        XCTAssertThrowsError(try update())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testWriteFailureLeavesSettingsUntouched() throws {
        let original = Data(
            """
            {"mcpServers":{"iMCP":{"env":{"\(ClientCredential.environmentVariable)":"existing"}}}}
            """.utf8
        )
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        XCTAssertThrowsError(try update())
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
