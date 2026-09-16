import Foundation

struct HomeSummary: Codable, Sendable {
    let id: String
    let name: String
    let isPrimary: Bool
    let rooms: Int
    let zones: Int
    let accessories: Int
    let scenes: Int
    let automations: Int
}

struct RoomSummary: Codable, Sendable {
    let id: String
    let name: String
    let accessoryCount: Int
    let isDefaultRoom: Bool
}

struct ZoneSummary: Codable, Sendable {
    let id: String
    let name: String
    let rooms: [String]
}

struct AccessorySummary: Codable, Sendable {
    let id: String
    let name: String
    let home: String?
    let room: String?
    let category: String
    let categoryDescription: String
    let manufacturer: String?
    let model: String?
    let firmware: String?
    let isReachable: Bool
    let isBridged: Bool
    let bridgedBy: String?
    let services: [ServiceSummary]
}

struct ServiceSummary: Codable, Sendable {
    let id: String
    let name: String
    let type: String
    let description: String
}

struct AccessoryDetail: Codable, Sendable {
    let accessory: AccessorySummary
    let uniqueIdentifiersForBridgedAccessories: [String]
    let services: [ServiceDetail]
}

struct ServiceDetail: Codable, Sendable {
    let service: ServiceSummary
    let characteristics: [CharacteristicDetail]
}

struct CharacteristicDetail: Codable, Sendable {
    let id: String
    let type: String
    let description: String
    let properties: [String]
    let metadata: [String: Value]
    var value: Value?
    var error: String?
}

struct SceneSummary: Codable, Sendable {
    let id: String
    let name: String
    let type: String
    let actions: [Value]
}

struct AutomationSummary: Codable, Sendable {
    let id: String
    let name: String
    let kind: String
    let isEnabled: Bool
    let scenes: [String]
    let details: [String: Value]
    var lastFireDate: Value = .null
    var limitations: String =
        "HomeKit may omit Home app or Shortcuts behavior. lastFireDate is no longer supported by Apple."
}

struct BatchResult: Codable, Sendable {
    let id: String
    let ok: Bool
    var value: Value?
    var error: String?
}
