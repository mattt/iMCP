import AlarmKit
import Foundation

// The app and its widget extension both compile this file:
// the app schedules alarms with this type,
// and the widget shows it in the countdown Live Activity.

/// What iMCP stores with each alarm for its Live Activity.
struct MobileAlarmMetadata: AlarmMetadata {
    var title: String
    var isTimer: Bool
}
