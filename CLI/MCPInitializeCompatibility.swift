import Foundation

/// The bundled SDK cannot decode Codex's unused, object-valued auth-change capability.
enum MCPInitializeCompatibility {
    static func normalize(_ data: Data) -> Data {
        guard var request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            request["jsonrpc"] as? String == "2.0",
            request["method"] as? String == "initialize",
            let id = request["id"], !(id is NSNull),
            var params = request["params"] as? [String: Any],
            var capabilities = params["capabilities"] as? [String: Any],
            var experimental = capabilities["experimental"] as? [String: Any],
            experimental["codex/auth-change"] is [String: Any]
        else { return data }

        experimental.removeValue(forKey: "codex/auth-change")
        if experimental.isEmpty {
            capabilities.removeValue(forKey: "experimental")
        } else {
            capabilities["experimental"] = experimental
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
