import Foundation

enum ClaudeDesktopSettings {
    private typealias Object = [String: Any]

    private struct InvalidObject: LocalizedError {
        let field: String

        var errorDescription: String? {
            "Expected a JSON object for \(field) in the Claude Desktop configuration."
        }
    }

    /// Reads the selected destination after the setup and save panels have closed.
    ///
    /// iMCP trusts Claude Desktop by its code signature, so it writes no credential.
    /// It keeps the server's environment as it is,
    /// including a credential that an earlier version wrote,
    /// which keeps working.
    static func update(at url: URL, command: String) throws {
        var config = try read(at: url)
        var servers = try object(config["mcpServers"], field: "mcpServers")
        var server = try object(servers["iMCP"], field: "mcpServers.iMCP")
        if server["env"] != nil {
            _ = try object(server["env"], field: "mcpServers.iMCP.env")
        }

        server["command"] = command
        servers["iMCP"] = server
        config["mcpServers"] = servers

        let data = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func read(at url: URL) throws -> Object {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        }
        return try object(JSONSerialization.jsonObject(with: data), field: "the document")
    }

    private static func object(_ value: Any?, field: String) throws -> Object {
        guard let value else { return [:] }
        guard let object = value as? Object else { throw InvalidObject(field: field) }
        return object
    }
}
