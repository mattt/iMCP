import Foundation

/// A validated request to create an alarm or a timer,
/// before the iPhone or iPad turns it into an AlarmKit configuration.
struct MobileAlarmRequest: Equatable, Sendable {
    enum Schedule: Equatable, Sendable {
        /// One time, at a date.
        case fixed(Date)
        /// At a time of day: the next occurrence, or every week on `weekdays`,
        /// which use calendar numbering from 1 (Sunday) to 7 (Saturday).
        case relative(hour: Int, minute: Int, weekdays: [Int])
        /// A countdown.
        case timer(seconds: Int)
    }

    var id: UUID
    var title: String
    var schedule: Schedule

    init(tool: String, _ args: MobileArguments, now: Date = Date()) throws {
        id = try args.uuid("id") ?? UUID()
        title = (args.string("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MobileError("title must not be empty.") }
        switch tool {
        case "timers_create":
            guard let seconds = args.int("duration_seconds"), seconds > 0 else {
                throw MobileError("duration_seconds must be a positive number of seconds.")
            }
            schedule = .timer(seconds: seconds)
        case "alarms_create":
            if let date = try args.date("fire_at") {
                guard date > now else { throw MobileError("fire_at must be in the future.") }
                schedule = .fixed(date)
            } else if let hour = args.int("hour"), let minute = args.int("minute") {
                let names = args.strings("weekdays") ?? []
                let weekdays = try names.map { name -> Int in
                    guard let index = MobileTools.weekdays.firstIndex(of: name) else {
                        throw MobileError("\(name) isn't a weekday.")
                    }
                    return index + 1
                }
                schedule = .relative(hour: hour, minute: minute, weekdays: weekdays.sorted())
            } else {
                throw MobileError("Give fire_at, or hour and minute.")
            }
        default:
            throw MobileError("\(tool) doesn't create alarms.")
        }
    }
}
