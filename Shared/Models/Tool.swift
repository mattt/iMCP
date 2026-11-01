import Foundation
import JSONSchema
import MCP
import Ontology

public struct Tool: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONSchema
    let annotations: MCP.Tool.Annotations
    private let implementation: @Sendable ([String: Value]) async throws -> Value

    public init<T: Encodable>(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        annotations: MCP.Tool.Annotations,
        implementation: @Sendable @escaping ([String: Value]) async throws -> T
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.implementation = { input in
            let result = try await implementation(input)

            let encoder = JSONEncoder()
            encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] =
                TimeZone.current
            encoder.userInfo[JSONLD.omitsNestedTypesKey] = true
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

            let data = try encoder.encode(result)

            let decoder = JSONDecoder()
            return try decoder.decode(Value.self, from: data)
        }
    }

    public func callAsFunction(_ input: [String: Value]) async throws -> Value {
        try await implementation(input)
    }
}

/// A JSON-LD document that lists values in `@graph` under one `@context`.
///
/// Return a list as a graph so that its values keep their Schema.org context
/// without each value repeating it.
public struct JSONLDGraph<Element: Encodable>: Encodable {
    /// The values in the graph.
    public var elements: [Element]

    /// Properties of the document that apply to every value, such as attribution.
    public var properties: [String: Value]

    public init(_ elements: [Element], properties: [String: Value] = [:]) {
        self.elements = elements
        self.properties = properties
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode("https://schema.org", forKey: Key("@context"))
        try container.encode(elements, forKey: Key("@graph"))
        for (key, value) in properties {
            try container.encode(value, forKey: Key(key))
        }
    }
}
