import Foundation
import JSONSchema
import MCP

enum JSONSchemaToValueConverter {
    static func convert(_ schema: JSONSchema) throws -> Value {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []

        let data = try encoder.encode(schema)
        let jsonObject = try JSONSerialization.jsonObject(with: data)

        return try convertJSONToValue(jsonObject)
    }

    private static func convertJSONToValue(_ object: Any) throws -> Value {
        switch object {
        case let dict as [String: Any]:
            let convertedDict = try dict.mapValues { try convertJSONToValue($0) }
            return .object(convertedDict)

        case let array as [Any]:
            let convertedArray = try array.map { try convertJSONToValue($0) }
            return .array(convertedArray)

        case let string as String:
            return .string(string)

        case let number as NSNumber:
            if number === kCFBooleanTrue {
                return .bool(true)
            } else if number === kCFBooleanFalse {
                return .bool(false)
            } else if number.doubleValue == Double(number.intValue) {
                return .int(number.intValue)
            } else {
                return .double(number.doubleValue)
            }

        case is NSNull:
            return .null

        default:
            throw NSError(
                domain: "JSONSchemaToValueConverter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected JSON type: \(type(of: object))"]
            )
        }
    }
}
