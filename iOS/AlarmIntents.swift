import AlarmKit
import AppIntents
import Foundation

// The app and its widget extension both compile this file:
// the app schedules alarms with these types,
// and the widget shows them in the countdown Live Activity.

/// What iMCP stores with each alarm for its Live Activity.
struct MobileAlarmMetadata: AlarmMetadata {
    var title: String
    var isTimer: Bool
}

/// Stops an alarm or timer from its alert or Live Activity.
struct StopAlarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Alarm"
    static let isDiscoverable = false

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {}

    init(alarmID: UUID) {
        self.alarmID = alarmID.uuidString
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) {
            try AlarmManager.shared.stop(id: id)
        }
        return .result()
    }
}
