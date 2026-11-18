import Foundation
import MCP

/// Edits the MCP server settings in a client's JSON configuration file.
enum MCPClientConfig {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Returns `data` with `entry` stored as the `mcpServers` entry named `server`.
    ///
    /// Everything else in the file is kept.
    ///
    /// - Parameter data: The file's current contents, or `nil` if the file doesn't exist.
    static func upserting(server: String, entry: [String: Value], into data: Data?) throws -> Data {
        var config: [String: Value] = [:]
        if let data, !data.isEmpty {
            config = try JSONDecoder().decode([String: Value].self, from: data)
        }
        var servers = config["mcpServers"]?.objectValue ?? [:]
        servers[server] = .object(entry)
        config["mcpServers"] = .object(servers)
        return try encoder.encode(config)
    }

    /// Returns the value of environment variable `name` in the `mcpServers` entry named `server`.
    static func environmentValue(_ name: String, server: String, in data: Data?) -> String? {
        guard let data, let config = try? JSONDecoder().decode([String: Value].self, from: data) else { return nil }
        return config["mcpServers"]?.objectValue?[server]?.objectValue?["env"]?.objectValue?[name]?.stringValue
    }

    /// Replaces the file at `url` with `data` in one step,
    /// so that a client that reads the file never sees half of it.
    ///
    /// The file keeps its permissions, or is private to the person if it's new,
    /// because it holds a client credential.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let permissions =
            (try? manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
