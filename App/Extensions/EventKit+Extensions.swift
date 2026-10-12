import EventKit

extension EKEventAvailability {
    init(_ string: String) {
        switch string.lowercased() {
        case "busy": self = .busy
        case "free": self = .free
        case "tentative": self = .tentative
        case "unavailable": self = .unavailable
        default: self = .busy
        }
    }

    static var allCases: [EKEventAvailability] {
        return [.busy, .free, .tentative, .unavailable]
    }

    var stringValue: String {
        switch self {
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        default: return "unknown"
        }
    }
}

extension EKEventStatus {
    init(_ string: String) {
        switch string.lowercased() {
        case "none": self = .none
        case "tentative": self = .tentative
        case "confirmed": self = .confirmed
        case "canceled": self = .canceled
        default: self = .none
        }
    }
}

extension EKRecurrenceFrequency {
    init(_ string: String) {
        switch string.lowercased() {
        case "daily": self = .daily
        case "weekly": self = .weekly
        case "monthly": self = .monthly
        case "yearly": self = .yearly
        default: self = .daily
        }
    }
}

extension EKReminderPriority {
    static func from(string: String) -> EKReminderPriority {
        switch string.lowercased() {
        case "high": return .high
        case "medium": return .medium
        case "low": return .low
        default: return .none
        }
    }

    /// Strict parse for tool arguments: nil unless the string names one of
    /// `allCases`, unlike `from(string:)`, which folds unknowns into `.none`.
    static func from(exactString string: String) -> EKReminderPriority? {
        allCases.first { $0.stringValue == string.lowercased() }
    }

    static var allCases: [EKReminderPriority] {
        return [.none, .low, .medium, .high]
    }

    var stringValue: String {
        switch self {
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        case .none: return "none"
        @unknown default: return "unknown"
        }
    }
}

extension EKRecurrenceFrequency {
    var stringValue: String {
        switch self {
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .yearly: return "yearly"
        @unknown default: return "unknown"
        }
    }
}

extension EKRecurrenceDayOfWeek {
    var dayName: String {
        switch dayOfTheWeek {
        case .sunday: return "sunday"
        case .monday: return "monday"
        case .tuesday: return "tuesday"
        case .wednesday: return "wednesday"
        case .thursday: return "thursday"
        case .friday: return "friday"
        case .saturday: return "saturday"
        @unknown default: return "unknown"
        }
    }

    /// The day matching an English day name, as accepted and emitted by the
    /// reminders tools.
    static func day(named name: String) -> EKRecurrenceDayOfWeek? {
        let weekday: EKWeekday
        switch name.lowercased() {
        case "sunday": weekday = .sunday
        case "monday": weekday = .monday
        case "tuesday": weekday = .tuesday
        case "wednesday": weekday = .wednesday
        case "thursday": weekday = .thursday
        case "friday": weekday = .friday
        case "saturday": weekday = .saturday
        default: return nil
        }
        return EKRecurrenceDayOfWeek(dayOfTheWeek: weekday, weekNumber: 0)
    }
}
