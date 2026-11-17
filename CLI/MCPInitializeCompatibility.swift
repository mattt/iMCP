import Foundation

/// Removes experimental client capabilities that the bundled SDK can't decode.
///
/// Swift MCP SDK 0.12 decodes `capabilities.experimental` as `[String: String]`,
/// so an `initialize` request with any other value fails with `-32603`
/// before iMCP can ask the user to approve the client.
/// Codex sends an object for `codex/auth-change`,
/// and ChatGPT sends an object for `openai/visibility`.
/// iMCP doesn't use experimental capabilities,
/// so the normalizer removes each entry that isn't a string
/// and removes the map if no entries remain.
/// Other data passes through unchanged.
///
/// Remove this workaround when a swift-sdk release decodes arbitrary JSON
/// in `experimental` (modelcontextprotocol/swift-sdk#276).
enum MCPInitializeCompatibility {
    static func normalize(_ data: Data) -> Data {
        guard var request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            request["jsonrpc"] as? String == "2.0",
            request["method"] as? String == "initialize",
            let id = request["id"], !(id is NSNull),
            var params = request["params"] as? [String: Any],
            var capabilities = params["capabilities"] as? [String: Any],
            let experimental = capabilities["experimental"] as? [String: Any]
        else { return data }

        let supported = experimental.filter { $0.value is String }
        guard supported.count < experimental.count else { return data }

        if supported.isEmpty {
            capabilities.removeValue(forKey: "experimental")
        } else {
            capabilities["experimental"] = supported
        }
        params["capabilities"] = capabilities
        request["params"] = params
        return (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])) ?? data
    }
}

/// Stdin reads may split a JSON message or contain several newline-delimited messages.
struct MCPStdinFrames {
    enum Failure: Error { case frameTooLarge }

    static let maximumFrameBytes = 10 * 1024 * 1024
    private var pending = Data()

    mutating func append(_ data: Data) throws -> [Data] {
        pending.append(data)
        var frames: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            guard pending.distance(from: pending.startIndex, to: newline) <= Self.maximumFrameBytes else {
                throw Failure.frameTooLarge
            }
            let frame = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            guard !frame.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) else { continue }
            var normalized = MCPInitializeCompatibility.normalize(frame)
            normalized.append(0x0A)
            frames.append(normalized)
        }
        guard pending.count <= Self.maximumFrameBytes else { throw Failure.frameTooLarge }
        return frames
    }
}
