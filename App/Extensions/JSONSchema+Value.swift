import JSONSchema
import Foundation

extension JSONSchema {
    func mcpValue() throws -> MCP.Value {
        let schemaData = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(MCP.Value.self, from: schemaData)
    }
}
