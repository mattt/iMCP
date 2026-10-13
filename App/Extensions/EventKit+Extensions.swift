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

    /// The day as the reminders tools emit it: a bare name when it repeats
    /// every week, an ordinal-prefixed name ("second tuesday") when it is
    /// one weekday of the month, symmetric with `day(named:)`. A week
    /// number outside this vocabulary emits "unknown", matching the other
    /// foreign-value degrades.
    var namedValue: String {
        // 0 is the every-week form; the bare name round-trips.
        if weekNumber == 0 { return dayName }
        let ordinal: String?
        switch weekNumber {
        case 1: ordinal = "first"
        case 2: ordinal = "second"
        case 3: ordinal = "third"
        case 4: ordinal = "fourth"
        case 5: ordinal = "fifth"
        case -1: ordinal = "last"
        case -2: ordinal = "second-to-last"
        case -3: ordinal = "third-to-last"
        case -4: ordinal = "fourth-to-last"
        case -5: ordinal = "fifth-to-last"
        default: ordinal = nil
        }
        // Ordinals beyond ±5 are not representable in this vocabulary
        // (foreign calendars can carry them). Emitting the bare day
        // name would silently turn a sixth or further-out ordinal into
        // "every tuesday" on a round-trip; degrade instead.
        guard let ordinal else { return "unknown" }
        return "\(ordinal) \(dayName)"
    }

    /// The day matching an English day name, as accepted and emitted by the
    /// reminders tools: "tuesday" for every week, "second tuesday" or
    /// "second-to-last friday" for one weekday of the month.
    static func day(named name: String) -> EKRecurrenceDayOfWeek? {
        let words = name.lowercased().split(separator: " ").map(String.init)
        let weekday: EKWeekday
        switch words.last {
        case "sunday": weekday = .sunday
        case "monday": weekday = .monday
        case "tuesday": weekday = .tuesday
        case "wednesday": weekday = .wednesday
        case "thursday": weekday = .thursday
        case "friday": weekday = .friday
        case "saturday": weekday = .saturday
        default: return nil
        }
        let weekNumber: Int
        switch words.count {
        case 1: weekNumber = 0
        case 2:
            switch words.first {
            case "first": weekNumber = 1
            case "second": weekNumber = 2
            case "third": weekNumber = 3
            case "fourth": weekNumber = 4
            case "fifth": weekNumber = 5
            case "last": weekNumber = -1
            case "second-to-last": weekNumber = -2
            case "third-to-last": weekNumber = -3
            case "fourth-to-last": weekNumber = -4
            case "fifth-to-last": weekNumber = -5
            default: return nil
            }
        default: return nil
        }
        return EKRecurrenceDayOfWeek(dayOfTheWeek: weekday, weekNumber: weekNumber)
    }
}
