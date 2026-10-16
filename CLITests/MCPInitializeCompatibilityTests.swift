import Foundation
import XCTest

final class MCPInitializeCompatibilityTests: XCTestCase {
    private let initialize = Data(
        #"{"jsonrpc":"2.0","id":"request-1","method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"codex-mcp-client","version":"0.160.0"},"capabilities":{"elicitation":{"form":{}},"roots":{"listChanged":false},"experimental":{"codex/auth-change":{},"legacy":"unchanged"}}}}"#
            .utf8
    )

    func testRemovesOnlyUnsupportedCapability() throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: initialize) as? [String: Any])
        let normalized = try XCTUnwrap(
            JSONSerialization.jsonObject(with: MCPInitializeCompatibility.normalize(initialize)) as? [String: Any]
        )
        var expected = original
        var params = try XCTUnwrap(expected["params"] as? [String: Any])
        var capabilities = try XCTUnwrap(params["capabilities"] as? [String: Any])
        capabilities["experimental"] = ["legacy": "unchanged"]
        params["capabilities"] = capabilities
        expected["params"] = params
        XCTAssertEqual(normalized as NSDictionary, expected as NSDictionary)
    }

    func testNormalizedInitializeUsesStableSortedKeys() {
        let expected = Data(
            #"{"id":"request-1","jsonrpc":"2.0","method":"initialize","params":{"capabilities":{"elicitation":{"form":{}},"experimental":{"legacy":"unchanged"},"roots":{"listChanged":false}},"clientInfo":{"name":"codex-mcp-client","version":"0.160.0"},"protocolVersion":"2025-06-18"}}"#
                .utf8
        )
        for _ in 0 ..< 100 {
            XCTAssertEqual(MCPInitializeCompatibility.normalize(initialize), expected)
        }
    }

    func testRemovesEmptyExperimentalMap() throws {
        let input = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":{"codex/auth-change":{}}}}}"#
                .utf8
        )
        let result = try XCTUnwrap(
            JSONSerialization.jsonObject(with: MCPInitializeCompatibility.normalize(input)) as? [String: Any]
        )
        let params = try XCTUnwrap(result["params"] as? [String: Any])
        let capabilities = try XCTUnwrap(params["capabilities"] as? [String: Any])
        XCTAssertNil(capabilities["experimental"])
    }

    func testOtherRequestsStayByteIdentical() {
        for method in ["tools/call", "tools/list", "notifications/initialized", "elicitation/create"] {
            let input = Data(
                String(decoding: initialize, as: UTF8.self)
                    .replacingOccurrences(of: "\"method\":\"initialize\"", with: "\"method\":\"\(method)\"").utf8
            )
            XCTAssertEqual(MCPInitializeCompatibility.normalize(input), input)
        }
    }

    func testMalformedAndUnrelatedDataStayByteIdentical() {
        let inputs = [
            "not JSON", "[]", "null", "{\"method\":\"initialize\"}",
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":{"codex/auth-change":"legacy"}}}}"#,
            #"{"jsonrpc":"2.0","id":null,"method":"initialize","params":{"capabilities":{"experimental":{"codex/auth-change":{}}}}}"#,
        ]
        for input in inputs {
            let data = Data(input.utf8)
            XCTAssertEqual(MCPInitializeCompatibility.normalize(data), data)
        }
    }

    func testUnknownCapabilitiesAreNotRemoved() {
        let input = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":{"other/auth-change":{}}}}}"#
                .utf8
        )
        XCTAssertEqual(MCPInitializeCompatibility.normalize(input), input)
    }

    func testFragmentedInitializeIsNormalizedOnceComplete() throws {
        var frames = MCPStdinFrames()
        for byte in initialize { XCTAssertTrue(try frames.append(Data([byte])).isEmpty) }
        let result = try frames.append(Data([0x0A]))
        XCTAssertEqual(result, [MCPInitializeCompatibility.normalize(initialize) + Data([0x0A])])
    }

    func testBatchedRequestsPreserveOrderAndOtherBytes() throws {
        var frames = MCPStdinFrames()
        let next = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)
        let newline = Data([0x0A])
        let input = initialize + newline + next + newline
        XCTAssertEqual(
            try frames.append(input),
            [MCPInitializeCompatibility.normalize(initialize) + newline, next + newline]
        )
    }

    func testBlankLinesAndSplitUTF8() throws {
        var frames = MCPStdinFrames()
        XCTAssertTrue(try frames.append(Data(" \t\r\n\n".utf8)).isEmpty)
        let input = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"şehir"}}"#.utf8)
        for byte in input { XCTAssertTrue(try frames.append(Data([byte])).isEmpty) }
        XCTAssertEqual(try frames.append(Data([0x0A])), [input + Data([0x0A])])
    }

    func testOversizedUnterminatedFrameFailsClosed() {
        var frames = MCPStdinFrames()
        XCTAssertThrowsError(try frames.append(Data(repeating: 0x61, count: MCPStdinFrames.maximumFrameBytes + 1)))
        XCTAssertEqual(MCPServiceLoop.decision(error: MCPStdinFrames.Failure.frameTooLarge), .terminate)
    }

    func testOversizedTerminatedFrameFailsClosed() {
        var frames = MCPStdinFrames()
        var input = Data(repeating: 0x61, count: MCPStdinFrames.maximumFrameBytes + 1)
        input.append(0x0A)
        XCTAssertThrowsError(try frames.append(input))
    }
}
