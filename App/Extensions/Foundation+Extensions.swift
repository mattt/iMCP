import Foundation

extension ISO8601DateFormatter {
    /// Attempts to parse a date string using common ISO 8601 variants,
    /// falling back to local-time parsing when no timezone is present.
    /// - Parameters:
    ///   - dateString: The string representation of the date.
    /// - Returns: A `Date` object if parsing is successful with any format, otherwise `nil`.
    static func lenientDate(fromISO8601String dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()

        let optionsToTry: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],  // `yyyy-MM-dd'T'HH:mm:ss.SSSZ`, `yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ`
            [.withInternetDateTime],  // `yyyy-MM-dd'T'HH:mm:ssZ`, `yyyy-MM-dd'T'HH:mm:ssZZZZZ`
            [.withFullDate, .withFullTime, .withFractionalSeconds],  // `yyyy-MM-dd'T'HH:mm:ss.SSS` (no zone)
            [.withFullDate, .withFullTime],  // `yyyy-MM-dd'T'HH:mm:ss` (no zone)
            [.withFullDate, .withFullTime, .withSpaceBetweenDateAndTime, .withFractionalSeconds],  // `yyyy-MM-dd HH:mm:ss.SSSZZZZZ`
            [.withFullDate, .withFullTime, .withSpaceBetweenDateAndTime],  // `yyyy-MM-dd HH:mm:ssZZZZZ`
        ]

        for options in optionsToTry {
            formatter.formatOptions = options
            if let date = formatter.date(from: dateString) {
                return date
            }
        }

        // If the string already includes a timezone, don't guess with local-time parsing.
        let hasTimeZoneInfo =
            dateString.range(
                of: #"([Zz]|[+-]\d{2}(:?\d{2})?)$"#,
                options: .regularExpression
            ) != nil
        guard !hasTimeZoneInfo else {
            return nil
        }

        // Fall back to local-time parsing for timezone-less inputs.
        let fallbackFormats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd",
        ]

        let fallbackFormatter = DateFormatter()
        fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
        fallbackFormatter.timeZone = TimeZone.current

        for format in fallbackFormats {
            fallbackFormatter.dateFormat = format
            if let date = fallbackFormatter.date(from: dateString) {
                return date
            }
        }

        return nil
    }

    static func parsedLenientISO8601Date(
        fromISO8601String dateString: String
    ) -> (date: Date, isDateOnly: Bool)? {
        let isDateOnly = isDateOnlyISO8601String(dateString)
        guard let date = lenientDate(fromISO8601String: dateString) else {
            return nil
        }
        return (date, isDateOnly)
    }

    static func isDateOnlyISO8601String(_ dateString: String) -> Bool {
        dateString.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}

extension Calendar {
    func normalizedStartDate(from date: Date, isDateOnly: Bool) -> Date {
        isDateOnly ? startOfDay(for: date) : date
    }

    func normalizedEndDate(from date: Date, isDateOnly: Bool) -> Date {
        guard isDateOnly else { return date }
        let startOfDay = startOfDay(for: date)
        return self.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
    }
}
