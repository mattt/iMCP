import JSONSchema

/// Validates the schema features used by Home tools before any HomeKit mutation.
enum HomeInput {
    static func validate(_ input: [String: Value], schema: JSONSchema) throws {
        try validate(.object(input), schema: Value(schema), path: "arguments")
    }

    private static func validate(_ value: Value, schema: Value, path: String) throws {
        guard case .object(let schema) = schema else { throw HomeError("Invalid Home tool schema.") }
        if case .array(let choices) = schema["anyOf"] {
            for choice in choices {
                if (try? validate(value, schema: choice, path: path)) != nil { return }
            }
            throw HomeError("\(path) does not match any permitted input format.")
        }
        if case .array(let choices) = schema["enum"], !choices.contains(value) {
            throw HomeError("\(path) is not one of the permitted values.")
        }
        switch schema["type"]?.stringValue {
        case "object":
            guard case .object(let object) = value else { throw HomeError("\(path) must be an object.") }
            let properties = schema["properties"]?.objectValue ?? [:]
            if case .array(let required) = schema["required"] {
                for key in required.compactMap(\.stringValue) where object[key] == nil {
                    throw HomeError("Missing argument: \(path).\(key)")
                }
            }
            for (key, member) in object {
                if let property = properties[key] {
                    try validate(member, schema: property, path: "\(path).\(key)")
                } else if schema["additionalProperties"] == .bool(false) {
                    throw HomeError("Unknown argument: \(path).\(key)")
                }
            }
        case "array":
            guard case .array(let array) = value else { throw HomeError("\(path) must be an array.") }
            if let min = schema["minItems"]?.intValue, array.count < min {
                throw HomeError("\(path) has too few items.")
            }
            if schema["uniqueItems"] == .bool(true), Set(array).count != array.count {
                throw HomeError("\(path) must contain distinct items.")
            }
            if let item = schema["items"] {
                for (index, member) in array.enumerated() {
                    try validate(member, schema: item, path: "\(path)[\(index)]")
                }
            }
        case "string":
            guard case .string = value else { throw HomeError("\(path) must be a string.") }
        case "boolean":
            guard case .bool = value else { throw HomeError("\(path) must be a Boolean.") }
        case "number", "integer":
            let number: Double
            switch value {
            case .int(let integer): number = Double(integer)
            case .double(let double) where schema["type"]?.stringValue == "number": number = double
            default: throw HomeError("\(path) must be a \(schema["type"]?.stringValue ?? "number").")
            }
            guard number.isFinite else { throw HomeError("\(path) must be finite.") }
            if let min = numeric(schema["minimum"]), number < min { throw HomeError("\(path) is below its minimum.") }
            if let max = numeric(schema["maximum"]), number > max { throw HomeError("\(path) exceeds its maximum.") }
        default: throw HomeError("Unsupported Home tool schema type.")
        }
    }

    private static func numeric(_ value: Value?) -> Double? {
        switch value {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }
}
