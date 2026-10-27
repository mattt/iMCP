import Foundation
import TOML
import XCTest

final class ChatGPTConfigTests: XCTestCase {
    private let command = "/Applications/iMCP.app/Contents/MacOS/imcp-server"

    private func updated(_ original: String) throws -> String {
        try ChatGPTConfig.updatedConfig(original: original, command: command)
    }

    func testEmptyFile() throws {
        let result = try updated("")
        XCTAssertEqual(result, "[mcp_servers.iMCP]\ncommand = \"\(command)\"\n")
        XCTAssertEqual(ChatGPTConfig.commandValue(in: try parse(result)), command)
    }

    func testFileWithOtherServersAndComments() throws {
        let original = """
            # My Codex settings
            model = "gpt-5"

            # Another server
            [mcp_servers.other]
            command = "other-cmd"
            args = ["--flag"]

            """
        let result = try updated(original)
        XCTAssertTrue(result.contains("# My Codex settings"))
        XCTAssertTrue(result.contains("# Another server"))
        XCTAssertTrue(result.contains("[mcp_servers.other]\ncommand = \"other-cmd\""))
        XCTAssertTrue(result.hasSuffix("[mcp_servers.iMCP]\ncommand = \"\(command)\"\n"))
        XCTAssertEqual(ChatGPTConfig.commandValue(in: try parse(result)), command)
    }

    func testExistingIMCPTableKeepsOtherKeys() throws {
        let original = """
            [mcp_servers.iMCP]
            command = "old-cmd"
            command_timeout = 30
            enabled = true

            [other]
            x = 1

            """
        let result = try updated(original)
        XCTAssertTrue(result.contains("command = \"\(command)\""))
        XCTAssertFalse(result.contains("old-cmd"))
        XCTAssertTrue(result.contains("command_timeout = 30"))
        XCTAssertTrue(result.contains("enabled = true"))
        XCTAssertTrue(result.contains("[other]\nx = 1"))
    }

    func testExistingIMCPTableWithoutCommandGetsOneAfterTheHeader() throws {
        let original = """
            [mcp_servers.iMCP]
            command_timeout = 30

            """
        let result = try updated(original)
        XCTAssertTrue(result.contains("[mcp_servers.iMCP]\ncommand = \"\(command)\"\ncommand_timeout = 30"))
    }

    func testQuotedKeyFormsAreRefused() throws {
        for original in [
            "[mcp_servers.\"iMCP\"]\ncommand = \"old\"\n",
            "[\"mcp_servers\".iMCP]\ncommand = \"old\"\n",
            "[mcp_servers.'iMCP']\ncommand = \"old\"\n",
        ] {
            XCTAssertThrowsError(try updated(original), original) { error in
                XCTAssertTrue(String(describing: error).contains("ambiguous"), "\(error)")
            }
        }
    }

    func testDottedKeyFormsAreRefused() throws {
        for original in [
            "mcp_servers.iMCP.command = \"old\"\n",
            "[mcp_servers]\niMCP.command = \"old\"\n",
            "mcp_servers.iMCP = { command = \"old\" }\n",
        ] {
            XCTAssertThrowsError(try updated(original), original)
        }
    }

    func testInlineTableIsRefused() throws {
        XCTAssertThrowsError(try updated("[mcp_servers]\niMCP = { command = \"old\" }\n")) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("ChatGPT Settings > MCP servers"),
                error.localizedDescription
            )
            XCTAssertFalse(error.localizedDescription.contains("by hand"), error.localizedDescription)
        }
        XCTAssertThrowsError(try updated("mcp_servers = { iMCP = { command = \"old\" } }\n"))
    }

    func testArrayOfTablesIsRefused() throws {
        XCTAssertThrowsError(try updated("[[mcp_servers.iMCP]]\ncommand = \"old\"\n"))
    }

    func testValueLineThatStartsWithBracketInsideIMCPTable() throws {
        // The args array spans lines, and a continuation line starts with `[`.
        // It is a value, not a header, so the command after it still belongs to iMCP.
        let original = """
            [mcp_servers.iMCP]
            args = [
            ["nested"],
            ]
            command = "old-cmd"

            [mcp_servers.other]
            command = "other-cmd"

            """
        let result = try updated(original)
        XCTAssertTrue(result.contains("command = \"\(command)\""))
        XCTAssertFalse(result.contains("old-cmd"))
        XCTAssertTrue(result.contains("command = \"other-cmd\""))
    }

    func testValueLineThatStartsWithBracketInOtherTableDoesNotMoveTheEdit() throws {
        let original = """
            [mcp_servers.other]
            args = [
            ["nested"],
            ]

            [mcp_servers.iMCP]
            command = "old-cmd"

            """
        let result = try updated(original)
        XCTAssertTrue(result.contains("command = \"\(command)\""))
        XCTAssertEqual(ChatGPTConfig.commandValue(in: try parse(result)), command)
    }

    func testCommandWithQuotesAndBackslashes() throws {
        let tricky = "C:\\Program Files\\\"iMCP\"\\imcp-server"
        let result = try ChatGPTConfig.updatedConfig(original: "", command: tricky)
        XCTAssertTrue(result.contains("command = \"C:\\\\Program Files\\\\\\\"iMCP\\\"\\\\imcp-server\""))
        XCTAssertEqual(ChatGPTConfig.commandValue(in: try parse(result)), tricky)
    }

    func testFileThatDoesNotParseIsRefused() throws {
        XCTAssertThrowsError(try updated("model = \"unclosed\n")) { error in
            XCTAssertTrue(error.localizedDescription.contains("not valid TOML"), error.localizedDescription)
            XCTAssertTrue(
                error.localizedDescription.contains("ChatGPT Settings > MCP servers"),
                error.localizedDescription
            )
            XCTAssertFalse(error.localizedDescription.contains("by hand"), error.localizedDescription)
        }
        XCTAssertThrowsError(try updated("[mcp_servers.iMCP]\ncommand = \"a\"\ncommand = \"b\"\n"))
    }

    func testCommentAndFormattingSurvive() throws {
        let original = """
            # top comment
            model    =    "gpt-5"   # trailing comment

            [mcp_servers.iMCP]   # our server
            command="old"

            """
        let result = try updated(original)
        XCTAssertTrue(result.contains("# top comment"))
        XCTAssertTrue(result.contains("model    =    \"gpt-5\"   # trailing comment"))
        XCTAssertTrue(result.contains("[mcp_servers.iMCP]   # our server"))
        XCTAssertTrue(result.contains("command = \"\(command)\""))
    }

    private func parse(_ text: String) throws -> DynamicTOMLValue {
        try TOMLDecoder().decode(DynamicTOMLValue.self, from: text)
    }
}
