import Foundation

extension ISO8601DateFormatter {
    /// Attempts to parse a date string using several common ISO 8601 format options.
    /// - Parameters:
    ///   - dateString: The string representation of the date.
    /// - Returns: A `Date` object if parsing is successful with any format, otherwise `nil`.
    static func parseFlexibleISODate(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()

        let optionsToTry: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],  // Handles yyyy-MM-dd\'T\'HH:mm:ss.SSSZ and yyyy-MM-dd\'T\'HH:mm:ss.SSSZZZZZ
            [.withInternetDateTime],  // Handles yyyy-MM-dd\'T\'HH:mm:ssZ and yyyy-MM-dd\'T\'HH:mm:ssZZZZZ
            [.withFullDate, .withFullTime, .withFractionalSeconds],  // Handles yyyy-MM-dd\'T\'HH:mm:ss.SSS (no Z or offset)
            [.withFullDate, .withFullTime],  // Handles yyyy-MM-dd\'T\'HH:mm:ss (no Z or offset)
            [.withFullDate, .withFullTime, .withSpaceBetweenDateAndTime, .withFractionalSeconds],  // Handles yyyy-MM-dd HH:mm:ss.SSSZZZZZ etc.
            [.withFullDate, .withFullTime, .withSpaceBetweenDateAndTime],  // Handles yyyy-MM-dd HH:mm:ssZZZZZ etc.
        ]

        for options in optionsToTry {
            formatter.formatOptions = options
            if let date = formatter.date(from: dateString) {
                return date
            }
        }

        return nil
    }
}
