import Foundation

// Pure logic behind the Reminders tools: due-date and recurrence parsing,
// search normalization, paging, named views, batch bookkeeping, list colors,
// and the strictness check for geocoded addresses. Nothing here touches
// EventKit, so the test target compiles this file on its own.
//
// The feature set follows the behavior documented for viticci/remctl (MIT).

/// A validation failure with a stable machine-readable code and a message
/// for the caller.
struct RemindersInputError: Error, LocalizedError, Equatable {
    var code: String
    var message: String

    var errorDescription: String? { message.contains("(\(code))") ? message : "\(message) (\(code))" }
}

enum RemindersQuery {
    // MARK: - Due dates

    struct ParsedDue: Equatable {
        /// Year, month, day for an all-day reminder; plus hour and minute
        /// for a timed one.
        var components: DateComponents
        var isAllDay: Bool
    }

    private static let dueExpression = try! NSRegularExpression(
        pattern:
            #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{1,2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?\s*(Z|[+-]\d{2}:?\d{2})?)?$"#
    )

    /// Parses a due date.
    ///
    /// - `YYYY-MM-DD` is all-day.
    /// - `YYYY-MM-DD HH:MM` (or with `T`, optional seconds) is timed, in the
    ///   given calendar's time zone.
    /// - A trailing `Z` or `+HH:MM` offset is honored and converted to the
    ///   calendar's time zone.
    static func parseDue(
        _ string: String,
        calendar: Calendar = .current
    ) throws -> ParsedDue {
        let text = string.trimmingCharacters(in: .whitespaces)
        let invalid = RemindersInputError(
            code: "invalid_due_date",
            message:
                "Invalid date \"\(string)\". Use YYYY-MM-DD for an all-day reminder or YYYY-MM-DD HH:MM for a timed one (an ISO 8601 offset such as Z or +02:00 is also accepted)."
        )
        let range = NSRange(text.startIndex..., in: text)
        guard let match = dueExpression.firstMatch(in: text, range: range) else { throw invalid }

        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        guard let year = group(1).flatMap(Int.init),
            let month = group(2).flatMap(Int.init),
            let day = group(3).flatMap(Int.init)
        else { throw invalid }

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        guard let hour = group(4).flatMap(Int.init) else {
            // Date only: all-day. Reject dates the calendar would roll over.
            let components = DateComponents(year: year, month: month, day: day)
            guard let date = utc.date(from: components),
                utc.dateComponents([.year, .month, .day], from: date) == components
            else { throw invalid }
            return ParsedDue(components: components, isAllDay: true)
        }
        let minute = group(5).flatMap(Int.init) ?? 0
        let second = group(6).flatMap(Int.init) ?? 0
        guard (0 ... 23).contains(hour), (0 ... 59).contains(minute), (0 ... 59).contains(second)
        else { throw invalid }

        let wall = DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
        guard let wallDate = utc.date(from: wall),
            utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wallDate)
                == wall
        else { throw invalid }

        var instantCalendar = calendar
        let offsetText = group(7)
        let instant: Date
        if let offsetText {
            guard let offset = offsetSeconds(offsetText) else { throw invalid }
            instant = wallDate.addingTimeInterval(-Double(offset))
        } else {
            var local = calendar
            local.timeZone = calendar.timeZone
            guard let date = local.date(from: wall) else { throw invalid }
            instant = date
            instantCalendar = local
        }

        var components = instantCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: instant
        )
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        return ParsedDue(components: components, isAllDay: false)
    }

    private static func offsetSeconds(_ text: String) -> Int? {
        if text == "Z" { return 0 }
        let sign = text.hasPrefix("-") ? -1 : 1
        let digits = text.dropFirst().filter(\.isNumber)
        guard digits.count == 4, let value = Int(digits) else { return nil }
        let hours = value / 100
        let minutes = value % 100
        guard hours <= 23, minutes <= 59 else { return nil }
        return sign * (hours * 3600 + minutes * 60)
    }

    /// Parses a completion date: `YYYY-MM-DD` or `YYYY-MM-DD HH:MM`. A
    /// date-only value means local midnight.
    static func parseCompletionDate(
        _ string: String,
        calendar: Calendar = .current
    ) throws -> Date {
        let parsed: ParsedDue
        do {
            parsed = try parseDue(string, calendar: calendar)
        } catch {
            throw RemindersInputError(
                code: "invalid_completion_date",
                message:
                    "Invalid completion date \"\(string)\". Use YYYY-MM-DD or YYYY-MM-DD HH:MM."
            )
        }
        var components = parsed.components
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        guard let date = calendar.date(from: components) else {
            throw RemindersInputError(
                code: "invalid_completion_date",
                message: "Invalid completion date \"\(string)\"."
            )
        }
        return date
    }

    // MARK: - Priority

    /// EventKit priorities: 0 none, 1 through 4 high, 5 medium, 6 through 9
    /// low. The names map to the values Reminders itself writes.
    static func priorityNumber(name: String) -> Int? {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "high": return 1
        case "medium": return 5
        case "low": return 9
        case "none", "": return 0
        default: return nil
        }
    }

    static func priorityNumber(apple number: Int) -> Int? {
        (0 ... 9).contains(number) ? number : nil
    }

    static func priorityName(for number: Int) -> String {
        switch number {
        case 1 ... 4: return "high"
        case 5: return "medium"
        case 6 ... 9: return "low"
        default: return "none"
        }
    }

    // MARK: - Recurrence strings

    struct WeekdaySpec: Equatable {
        /// 1 is Sunday through 7 is Saturday, as in `Calendar`.
        var weekday: Int
        /// 0 for every week; 1 through 5 for the nth of the month; -1
        /// through -5 counting from the end.
        var ordinal: Int
    }

    struct RecurrenceSpec: Equatable {
        enum Frequency: String, Equatable { case daily, weekly, monthly, yearly }
        var frequency: Frequency
        var interval: Int = 1
        var weekdays: [WeekdaySpec] = []
        var monthDays: [Int] = []
    }

    enum RecurrenceInput: Equatable {
        case clear
        case rule(RecurrenceSpec)
    }

    private static let weekdayTokens: [String: Int] = [
        "sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "wednesday": 4, "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6, "sat": 7, "saturday": 7,
    ]

    private static let ordinalTokens: [String: Int] = [
        "1st": 1, "2nd": 2, "3rd": 3, "4th": 4, "5th": 5, "last": -1,
    ]

    /// Parses specs such as `daily`, `weekly mon,wed,fri`, `monthly 1,15`,
    /// `monthly 4th-fri`, `monthly last-fri`, `daily x2`, or
    /// `monthly x2 last-fri`. `clear`, `none`, and `never` stop repeating.
    static func parseRecurrence(_ string: String) throws -> RecurrenceInput {
        func fail(_ message: String) -> RemindersInputError {
            RemindersInputError(
                code: "invalid_recurrence",
                message: "Invalid recurrence \"\(string)\": \(message)"
            )
        }

        let tokens =
            string
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard let first = tokens.first else { throw fail("it is empty.") }
        if tokens.count == 1, ["clear", "none", "never"].contains(first) { return .clear }
        guard let frequency = RecurrenceSpec.Frequency(rawValue: first) else {
            throw fail("start with daily, weekly, monthly, or yearly (or clear, none, never).")
        }

        var spec = RecurrenceSpec(frequency: frequency)
        var sawInterval = false
        var sawDetail = false
        for token in tokens.dropFirst() {
            if token.hasPrefix("x"), let interval = Int(token.dropFirst()) {
                guard !sawInterval else { throw fail("the interval appears twice.") }
                guard (1 ... 999).contains(interval) else {
                    throw fail("the interval must be 1 to 999.")
                }
                spec.interval = interval
                sawInterval = true
                continue
            }
            guard !sawDetail else { throw fail("unexpected extra text \"\(token)\".") }
            sawDetail = true
            let parts = token.split(separator: ",", omittingEmptySubsequences: false).map(
                String.init
            )
            switch frequency {
            case .daily, .yearly:
                throw fail("\(frequency.rawValue) takes only an optional interval such as x2.")
            case .weekly:
                for part in parts {
                    guard let weekday = weekdayTokens[part] else {
                        throw fail("\"\(part)\" is not a weekday (use mon, tue, ... or sunday ...).")
                    }
                    spec.weekdays.append(WeekdaySpec(weekday: weekday, ordinal: 0))
                }
            case .monthly:
                for part in parts {
                    if let day = Int(part) {
                        guard day != 0, (-31 ... 31).contains(day) else {
                            throw fail("day numbers run 1 to 31 (or -1 for the last day).")
                        }
                        spec.monthDays.append(day)
                    } else if let weekday = try ordinalWeekday(part, fail: fail) {
                        spec.weekdays.append(weekday)
                    } else {
                        throw fail("\"\(part)\" is not a day number or an ordinal weekday.")
                    }
                }
                guard spec.weekdays.isEmpty || spec.monthDays.isEmpty else {
                    throw fail("ordinal weekdays cannot be mixed with day numbers.")
                }
            }
        }
        return .rule(spec)
    }

    /// `4th-fri`, `last-fri`, `-1-fri`. Returns nil when the text is not
    /// shaped like an ordinal weekday at all.
    private static func ordinalWeekday(
        _ text: String,
        fail: (String) -> RemindersInputError
    ) throws -> WeekdaySpec? {
        guard let dash = text.lastIndex(of: "-"), dash != text.startIndex else { return nil }
        let ordinalText = String(text[..<dash])
        let dayText = String(text[text.index(after: dash)...])
        guard let weekday = weekdayTokens[dayText] else { return nil }

        if let ordinal = ordinalTokens[ordinalText] {
            return WeekdaySpec(weekday: weekday, ordinal: ordinal)
        }
        if let number = Int(ordinalText) {
            guard (-5 ... -1).contains(number) else {
                throw fail("a negative ordinal runs -1 to -5.")
            }
            return WeekdaySpec(weekday: weekday, ordinal: number)
        }
        // A bare number plus a wrong suffix, such as 4st, is rejected rather
        // than guessed at.
        if let digits = ordinalText.firstIndex(where: { !$0.isNumber }),
            let number = Int(ordinalText[..<digits])
        {
            throw fail(
                "the suffix of \"\(ordinalText)\" does not match \(number) (use 1st, 2nd, 3rd, 4th, 5th)."
            )
        }
        return nil
    }

    // MARK: - Alarm strings

    enum AlarmInput: Equatable {
        case clear
        case relative(minutes: Int)
        case absolute(Date)
    }

    /// `15m`, `1h`, `1d`, `1w` (before the due date), an ISO date or datetime
    /// (absolute), or `clear` / `none`.
    static func parseAlarm(_ string: String, calendar: Calendar = .current) throws -> AlarmInput {
        let text = string.trimmingCharacters(in: .whitespaces).lowercased()
        if ["clear", "none"].contains(text) { return .clear }
        if let unit = text.last, "mhdw".contains(unit), let count = Int(text.dropLast()),
            count >= 0
        {
            let multiplier = ["m": 1, "h": 60, "d": 1440, "w": 10080][String(unit)]!
            let (minutes, overflow) = count.multipliedReportingOverflow(by: multiplier)
            guard !overflow, minutes <= 52_560_000 else {
                throw RemindersInputError(
                    code: "invalid_alarm",
                    message: "Relative alarm \"\(string)\" is too large."
                )
            }
            return .relative(minutes: minutes)
        }
        do {
            return .absolute(try parseCompletionDate(string, calendar: calendar))
        } catch {
            throw RemindersInputError(
                code: "invalid_alarm",
                message:
                    "Invalid alarm \"\(string)\". Use 15m, 1h, 1d, 1w (before the due date), a date such as 2026-05-27 09:30, or clear."
            )
        }
    }

    /// True when the user has disabled `reminders_delete` in Settings.
    static func isDeleteDisabled(defaults: UserDefaults = .standard) -> Bool {
        guard let data = defaults.data(forKey: "disabledTools"),
            let disabled = try? JSONDecoder().decode(Set<String>.self, from: data)
        else {
            return false
        }
        return disabled.contains("reminders_delete")
    }

    // MARK: - Search

    /// Case, accent, and width insensitive form used to compare text.
    static func folded(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
    }

    /// True when the folded query occurs in any of the folded fields. The
    /// query is literal text: `%`, `_`, and `\` are ordinary characters.
    static func matches(query: String, fields: [String?]) -> Bool {
        let needle = folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return true }
        return fields.contains { field in
            guard let field else { return false }
            return folded(field).contains(needle)
        }
    }

    struct Page<Element> {
        var items: [Element]
        var total: Int
        var offset: Int
        var limit: Int

        var count: Int { items.count }
        var hasMore: Bool { offset + items.count < total }
        var nextOffset: Int? { hasMore ? offset + items.count : nil }
    }

    static let defaultPageLimit = 100
    static let maximumPageLimit = 500

    static func validatedPaging(
        limit: Int?,
        offset: Int?
    ) throws -> (limit: Int, offset: Int) {
        let limit = limit ?? defaultPageLimit
        let offset = offset ?? 0
        guard (1 ... maximumPageLimit).contains(limit) else {
            throw RemindersInputError(
                code: "invalid_limit",
                message: "limit must be 1 to \(maximumPageLimit)."
            )
        }
        guard offset >= 0 else {
            throw RemindersInputError(code: "invalid_offset", message: "offset must be 0 or more.")
        }
        return (limit, offset)
    }

    static func page<Element>(
        _ items: [Element],
        limit: Int,
        offset: Int
    ) -> Page<Element> {
        let start = min(offset, items.count)
        let end = min(start + limit, items.count)
        return Page(
            items: Array(items[start ..< end]),
            total: items.count,
            offset: offset,
            limit: limit
        )
    }

    // MARK: - Named views

    /// Whether a due date falls in a named view. `components` carry no hour
    /// for an all-day reminder.
    enum Views {
        static func dueDate(of components: DateComponents, calendar: Calendar) -> Date? {
            var components = components
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            if components.hour == nil { components.hour = 0 }
            if components.minute == nil { components.minute = 0 }
            return calendar.date(from: components)
        }

        /// Overdue: an all-day reminder due before today, or a timed one
        /// whose due time has passed.
        static func isOverdue(
            _ components: DateComponents?,
            now: Date,
            calendar: Calendar
        ) -> Bool {
            guard let components, let due = dueDate(of: components, calendar: calendar) else {
                return false
            }
            if components.hour == nil {
                return due < calendar.startOfDay(for: now)
            }
            return due < now
        }

        static func isDueToday(
            _ components: DateComponents?,
            now: Date,
            calendar: Calendar
        ) -> Bool {
            guard let components, let due = dueDate(of: components, calendar: calendar) else {
                return false
            }
            return calendar.isDate(due, inSameDayAs: now)
        }

        /// Due from the start of today through the end of the day `days` days
        /// ahead, so `days` of 1 covers today and tomorrow.
        static func isUpcoming(
            _ components: DateComponents?,
            days: Int,
            now: Date,
            calendar: Calendar
        ) -> Bool {
            guard let components, let due = dueDate(of: components, calendar: calendar),
                let last = calendar.date(
                    byAdding: .day,
                    value: days + 1,
                    to: calendar.startOfDay(for: now)
                )
            else { return false }
            return due >= calendar.startOfDay(for: now) && due < last
        }
    }

    static func validatedUpcomingDays(_ days: Int?) throws -> Int {
        let days = days ?? 7
        guard (1 ... 365).contains(days) else {
            throw RemindersInputError(code: "invalid_days", message: "days must be 1 to 365.")
        }
        return days
    }

    // MARK: - Batches

    static let maximumBatchSize = 50

    /// Identifiers with duplicates removed (first occurrence wins). A batch
    /// writes each reminder once.
    static func batchPlan(
        _ identifiers: [String]
    ) throws -> (unique: [String], duplicatesIgnored: [String]) {
        guard !identifiers.isEmpty else {
            throw RemindersInputError(
                code: "empty_batch",
                message: "Pass at least one reminder identifier."
            )
        }
        guard identifiers.count <= maximumBatchSize else {
            throw RemindersInputError(
                code: "batch_too_large",
                message: "A batch takes at most \(maximumBatchSize) identifiers; got \(identifiers.count)."
            )
        }
        guard identifiers.allSatisfy({ !$0.isEmpty }) else {
            throw RemindersInputError(
                code: "invalid_identifier",
                message: "Reminder identifiers must be non-empty strings."
            )
        }
        var seen = Set<String>()
        var unique: [String] = []
        var duplicates: [String] = []
        for identifier in identifiers {
            if seen.insert(identifier).inserted {
                unique.append(identifier)
            } else {
                duplicates.append(identifier)
            }
        }
        return (unique, duplicates)
    }

    enum BatchStatus: String, Equatable {
        case succeeded, failed, uncertain, skipped
    }

    /// `completed` when every id succeeded, `failed` when none changed or
    /// may have changed, `partial` otherwise.
    static func batchOverallStatus(_ statuses: [BatchStatus]) -> String {
        if statuses.allSatisfy({ $0 == .succeeded }) { return "completed" }
        if statuses.allSatisfy({ $0 == .failed || $0 == .skipped }) { return "failed" }
        return "partial"
    }

    // MARK: - List colors

    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        var hex: String {
            func byte(_ value: Double) -> Int { Int((value * 255).rounded()) }
            return String(
                format: "#%02X%02X%02X",
                byte(red),
                byte(green),
                byte(blue)
            )
        }
    }

    /// Reminders' color names, with the system palette values.
    static let namedListColors: [String: RGB] = {
        func rgb(_ hex: UInt32) -> RGB {
            RGB(
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255
            )
        }
        return [
            "red": rgb(0xFF3B30), "orange": rgb(0xFF9500), "yellow": rgb(0xFFCC00),
            "green": rgb(0x34C759), "blue": rgb(0x007AFF), "purple": rgb(0xAF52DE),
            "brown": rgb(0xA2845E), "gray": rgb(0x8E8E93), "grey": rgb(0x8E8E93),
            "cyan": rgb(0x32ADE6), "teal": rgb(0x30B0C7),
        ]
    }()

    static func parseListColor(_ string: String) throws -> RGB {
        let text = string.trimmingCharacters(in: .whitespaces).lowercased()
        if let named = namedListColors[text] { return named }
        if text.hasPrefix("#"), text.count == 7, let value = UInt32(text.dropFirst(), radix: 16) {
            return RGB(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        }
        throw RemindersInputError(
            code: "invalid_color",
            message:
                "Unknown color \"\(string)\". Use red, orange, yellow, green, blue, purple, brown, gray, cyan, teal, or #RRGGBB."
        )
    }

    // MARK: - Address strictness

    struct GeocodeCandidate: Equatable {
        var name: String?
        var thoroughfare: String?
        var subThoroughfare: String?
        var locality: String?
        var postalCode: String?
        var administrativeArea: String?
        var country: String?
        var latitude: Double
        var longitude: Double
        /// Radius of the area the match covers; nil when unknown.
        var radiusMeters: Double?

        var summary: String {
            [
                name, [subThoroughfare, thoroughfare].compactMap { $0 }.joined(separator: " "),
                locality, administrativeArea, postalCode, country,
            ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        }
    }

    struct GeocodeRejection: Error, Equatable {
        var code: String
        var message: String
        var candidates: [GeocodeCandidate]
    }

    /// Labels that name a person's own place; the geocoder cannot know them.
    private static let personalLabels: Set<String> = [
        "home", "my home", "house", "my house", "work", "my work", "office", "my office",
        "school", "my school", "here", "current location", "my location", "nearby",
    ]

    /// Largest area, in meters, a match may cover and still count as precise.
    static let maximumGeocodeRadius = 1000.0

    private static let streetAbbreviations: [String: String] = [
        "st": "street", "ave": "avenue", "av": "avenue", "rd": "road", "dr": "drive",
        "blvd": "boulevard", "ln": "lane", "ct": "court", "pl": "place", "hwy": "highway",
        "pkwy": "parkway", "sq": "square", "ter": "terrace", "cir": "circle",
        "n": "north", "s": "south", "e": "east", "w": "west",
    ]

    private static func tokens(_ text: String) -> [String] {
        folded(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .map { streetAbbreviations[$0] ?? $0 }
    }

    /// Accepts a match only when there is exactly one, it is small enough,
    /// it names the street or place that was typed, and the query also gives
    /// a town or postal code. Otherwise it throws with a stable code.
    static func judgeAddress(
        query: String,
        candidates: [GeocodeCandidate]
    ) throws -> GeocodeCandidate {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if personalLabels.contains(folded(trimmed)) {
            throw GeocodeRejection(
                code: "location_label_not_address",
                message:
                    "\"\(trimmed)\" is a personal label; the address behind it is unknown. Pass the street address, or pass coordinates with a title.",
                candidates: []
            )
        }
        guard !candidates.isEmpty else {
            throw GeocodeRejection(
                code: "location_not_found",
                message: "No location matched \"\(trimmed)\". Check the address or pass coordinates.",
                candidates: []
            )
        }
        guard candidates.count == 1, let match = candidates.first else {
            throw GeocodeRejection(
                code: "location_ambiguous",
                message:
                    "\(candidates.count) locations matched \"\(trimmed)\". Pass a fuller address or one candidate's coordinates.",
                candidates: candidates
            )
        }
        if let radius = match.radiusMeters {
            guard radius < maximumGeocodeRadius else {
                throw GeocodeRejection(
                    code: "location_imprecise",
                    message:
                        "\"\(trimmed)\" resolved to an area about \(Int(radius)) m across, not a place. Pass a street address, or coordinates if the whole area is meant.",
                    candidates: [match]
                )
            }
        } else if match.thoroughfare == nil, match.name == nil {
            throw GeocodeRejection(
                code: "location_imprecise",
                message:
                    "\"\(trimmed)\" did not resolve to a specific place. Pass a street address or coordinates.",
                candidates: [match]
            )
        }

        let queryTokens = Set(tokens(trimmed))
        let street = (match.thoroughfare ?? match.name).map(tokens) ?? []
        let namesPlace = !street.isEmpty && street.allSatisfy(queryTokens.contains)
        let namesName =
            (match.name.map(tokens) ?? []).allSatisfy(queryTokens.contains)
            && !(match.name.map(tokens) ?? []).isEmpty
        guard namesPlace || namesName else {
            throw GeocodeRejection(
                code: "location_unconfirmed",
                message:
                    "The match (\(match.summary)) does not carry the street or place named in \"\(trimmed)\" (street_mismatch). Pass a fuller address or its coordinates.",
                candidates: [match]
            )
        }

        let foldedQuery = folded(trimmed)
        let givesTown =
            (match.locality.map { foldedQuery.contains(folded($0)) } ?? false)
            || (match.postalCode.map { foldedQuery.contains(folded($0)) } ?? false)
        guard givesTown else {
            throw GeocodeRejection(
                code: "location_unconfirmed",
                message:
                    "\"\(trimmed)\" gives no town or postal code (no_town); the match was \(match.summary). Add a town or postal code.",
                candidates: [match]
            )
        }
        return match
    }

    /// Radius of a location alarm: 1 to 100000 m, 100 by default.
    static func validatedGeofenceRadius(_ radius: Double?) throws -> Double {
        guard let radius else { return 100 }
        guard (1 ... 100_000).contains(radius) else {
            throw RemindersInputError(
                code: "invalid_location_radius",
                message: "The radius must be 1 to 100000 meters."
            )
        }
        return radius
    }
}
