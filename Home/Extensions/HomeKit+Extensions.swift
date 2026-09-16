import CoreFoundation
import Foundation
import HomeKit

@MainActor
enum HomeValue {
    static func encode(_ value: Any?) -> Value {
        guard let value else { return .null }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return number.doubleValue.isFinite ? .double(number.doubleValue) : .null
        }
        if let string = value as? String { return .string(string) }
        if let data = value as? Data { return .string(data.base64EncodedString()) }
        if let values = value as? [Any] { return .array(values.map(encode)) }
        return .null
    }

    static func decode(_ value: Value, for characteristic: HMCharacteristic, writable: Bool = true) throws -> NSCopying
    {
        if writable && !characteristic.properties.contains(HMCharacteristicPropertyWritable) {
            throw HomeError("The characteristic is read-only.")
        }
        guard let metadata = characteristic.metadata, let format = metadata.format else {
            throw HomeError("The characteristic has no format metadata.")
        }
        if format == HMCharacteristicMetadataFormatBool {
            guard case .bool(let value) = value else { throw HomeError("The characteristic requires a Boolean.") }
            return NSNumber(value: value)
        }
        if format == HMCharacteristicMetadataFormatString {
            guard case .string(let value) = value else { throw HomeError("The characteristic requires a string.") }
            if let limit = metadata.maxLength, value.utf8.count > limit.intValue {
                throw HomeError("The string exceeds maxLength.")
            }
            return value as NSString
        }
        if format == HMCharacteristicMetadataFormatData || format == HMCharacteristicMetadataFormatTLV8 {
            guard case .string(let value) = value, let data = Data(base64Encoded: value) else {
                throw HomeError("The characteristic requires a base64 string.")
            }
            return data as NSData
        }
        let number: Double
        switch value {
        case .int(let value): number = Double(value)
        case .double(let value): number = value
        default: throw HomeError("The characteristic requires a number.")
        }
        guard number.isFinite else { throw HomeError("The number must be finite.") }
        let ranges: [String: ClosedRange<Double>] = [
            HMCharacteristicMetadataFormatUInt8: 0 ... 255,
            HMCharacteristicMetadataFormatUInt16: 0 ... 65535,
            HMCharacteristicMetadataFormatUInt32: 0 ... 4294967295,
            // JSON numeric precision limits exact uint64 representation.
            HMCharacteristicMetadataFormatUInt64: 0 ... 9007199254740991,
            HMCharacteristicMetadataFormatInt: Double(Int32.min) ... Double(Int32.max),
        ]
        if let range = ranges[format] {
            guard range.contains(number), number.rounded() == number else {
                throw HomeError("The number must be an integer within the characteristic format's range.")
            }
        } else if format != HMCharacteristicMetadataFormatFloat {
            throw HomeError("Unsupported characteristic format: \(format)")
        }
        if let min = metadata.minimumValue, number < min.doubleValue {
            throw HomeError("The value is below minimumValue.")
        }
        if let max = metadata.maximumValue, number > max.doubleValue {
            throw HomeError("The value exceeds maximumValue.")
        }
        if let valid = metadata.validValues, !valid.contains(where: { $0.doubleValue == number }) {
            throw HomeError("The value is not in validValues.")
        }
        if let step = metadata.stepValue?.doubleValue, step.isFinite, step > 0 {
            let minimum = metadata.minimumValue?.doubleValue ?? 0
            let base = minimum.isFinite ? minimum : 0
            let count = (number - base) / step
            if abs(count - count.rounded()) > 0.000001 { throw HomeError("The value does not match stepValue.") }
        }
        return NSNumber(value: number)
    }
}

func homeErrorMessage(_ error: Error) -> String {
    let error = error as NSError
    guard error.domain == HMErrorDomain else { return error.localizedDescription }
    switch HMError.Code(rawValue: error.code) {
    case .homeAccessNotAuthorized:
        return "HomeKit access is not authorized. Enable iMCP Home in System Settings → Privacy & Security → HomeKit."
    case .accessoryNotReachable: return "The accessory is not reachable. Check its power and connection."
    case .readOnlyCharacteristic: return "The characteristic is read-only."
    case .insufficientPrivileges: return "This operation requires a home owner or administrator."
    case .nameContainsProhibitedCharacters: return "The name contains prohibited characters."
    case .nameDoesNotEndWithValidCharacters: return "The name must end with a letter or number."
    case .cloudDataSyncInProgress: return "HomeKit is syncing iCloud data. Retry when syncing finishes."
    default: return error.localizedDescription
    }
}
