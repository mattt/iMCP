import Foundation
import os

extension FileManager {
    /// The user's home folder, read from the password database.
    ///
    /// In the App Sandbox,
    /// `NSHomeDirectory()` and `homeDirectoryForCurrentUser` return the app's container,
    /// and the home folder is not always `/Users/<name>`:
    /// it can be moved, for example to another volume.
    static let userHomeDirectoryURL = URL(
        fileURLWithPath: getpwuid(getuid())?.pointee.pw_dir.map { String(cString: $0) } ?? "/Users/\(NSUserName())",
        isDirectory: true
    )
}

extension ISO8601DateFormatter {
    /// Attempts to parse a date string using common ISO 8601 variants,
    /// falling back to local-time parsing when no timezone is present.
    /// - Parameters:
    ///   - dateString: The string representation of the date.
    /// - Returns: A `Date` object if parsing is successful with any format, otherwise `nil`.
    static func lenientDate(fromISO8601String dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()

        let optionsToTry: [ISO8601DateFormatter.Options] = [
            // `yyyy-MM-dd'T'HH:mm:ss.SSSZ`, `yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ`
            [.withInternetDateTime, .withFractionalSeconds],

            // `yyyy-MM-dd'T'HH:mm:ssZ`, `yyyy-MM-dd'T'HH:mm:ssZZZZZ`
            [.withInternetDateTime],

            // `yyyy-MM-dd'T'HH:mm:ss.SSS` (no timezone)
            [.withFullDate, .withFullTime, .withFractionalSeconds],

            // `yyyy-MM-dd'T'HH:mm:ss` (no timezone)
            [.withFullDate, .withFullTime],

            // `yyyy-MM-dd HH:mm:ss.SSSZZZZZ`
            [.withFullDate, .withFullTime, .withSpaceBetweenDateAndTime, .withFractionalSeconds],

            // `yyyy-MM-dd HH:mm:ssZZZZZ`
            [.withFullDate, .withFullTime, .withSpaceBetweenDateAndTime],
        ]

        for options in optionsToTry {
            formatter.formatOptions = options
            if let date = formatter.date(from: dateString) {
                return date
            }
        }

        // If the string already includes a timezone suffix on a *time* component,
        // don't guess with local-time parsing. We must NOT run this check on a
        // bare `yyyy-MM-dd` because the trailing `-DD` would match the
        // `[+-]\d{2}` branch of this regex and falsely classify the day as a
        // timezone offset, causing the parser to bail before trying the
        // `yyyy-MM-dd` fallback below.
        let hasTimeZoneInfo =
            dateString.count > 10
            && dateString.range(
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

    /// Attempts to parse a date string using common ISO 8601 variants,
    /// falling back to local-time parsing when no timezone is present.
    /// - Parameters:
    ///   - dateString: The string representation of the date.
    /// - Returns: A tuple containing the `Date` object and a boolean indicating if the date is date-only.
    static func parsedLenientISO8601Date(
        fromISO8601String dateString: String
    ) -> (date: Date, isDateOnly: Bool)? {
        let isDateOnly = isDateOnlyISO8601String(dateString)
        guard let date = lenientDate(fromISO8601String: dateString) else {
            return nil
        }
        return (date, isDateOnly)
    }

    /// Checks if a date string is a date-only ISO 8601 string.
    /// - Parameters:
    ///   - dateString: The string representation of the date.
    /// - Returns: A boolean indicating if the date is date-only.
    static func isDateOnlyISO8601String(_ dateString: String) -> Bool {
        dateString.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}

extension Calendar {
    /// Normalizes a start date to ensure it is a date-only date.
    /// - Parameters:
    ///   - date: The date to normalize.
    ///   - isDateOnly: A boolean indicating if the date is date-only.
    /// - Returns: The normalized date.
    func normalizedStartDate(from date: Date, isDateOnly: Bool) -> Date {
        isDateOnly ? startOfDay(for: date) : date
    }

    /// Normalizes an end date to ensure it is a date-only date.
    /// - Parameters:
    ///   - date: The date to normalize.
    ///   - isDateOnly: A boolean indicating if the date is date-only.
    /// - Returns: The normalized date.
    func normalizedEndDate(from date: Date, isDateOnly: Bool) -> Date {
        guard isDateOnly else { return date }
        let startOfDay = startOfDay(for: date)
        return self.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
    }
}

extension NSAppleScript {
    /// An AppleScript compilation or execution error.
    struct ExecutionError: Error, Equatable, Sendable {
        /// The AppleScript error number, such as -1743 when the user has not allowed
        /// iMCP to send Apple events to the target app.
        let number: Int?
        let message: String

        init(number: Int?, message: String) {
            self.number = number
            self.message = message
        }

        init(errorInfo: NSDictionary?) {
            number = (errorInfo?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            message =
                errorInfo?[NSAppleScript.errorMessage] as? String
                ?? errorInfo.map { String(describing: $0) }
                ?? "unknown error"
        }
    }

    /// Creates and runs each script in one block, off the main thread.
    /// Script objects are not shared between queue blocks.
    /// Tests hold this queue to keep a script waiting.
    static let executionQueue = DispatchQueue(label: "me.mattt.iMCP.AppleScript")

    /// A call to a handler that a script defines, with its arguments.
    ///
    /// Values passed this way reach the script as Apple event descriptors,
    /// never as source text,
    /// so no value can change what the script does,
    /// whatever characters it contains.
    /// Prefer this to building a script from a template that interpolates a value.
    struct Subroutine: Equatable, Sendable {
        /// An argument of a handler.
        enum Parameter: Equatable, Sendable {
            case string(String)
            case boolean(Bool)
            /// A real number, sent as one, so the script never reads it from text.
            case number(Double)
            /// A list of strings, as an AppleScript list.
            case strings([String])
        }

        /// The handler's name, as the script declares it.
        let name: String
        let parameters: [Parameter]

        init(_ name: String, _ parameters: [Parameter]) {
            self.name = name
            self.parameters = parameters
        }

        /// The Apple event that makes a script run the handler,
        /// as `osascript` sends one for a script's `on <name>` handler.
        func event() -> NSAppleEventDescriptor {
            // The four-character codes of the AppleScript suite:
            // `kASAppleScriptSuite`, `kASSubroutineEvent`, `keyASSubroutineName`.
            let event = NSAppleEventDescriptor(
                eventClass: 0x6173_6372,  // 'ascr'
                eventID: 0x7073_6272,  // 'psbr'
                targetDescriptor: .currentProcess(),
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            // AppleScript looks up handlers by their lowercased names.
            event.setParam(
                NSAppleEventDescriptor(string: name.lowercased()),
                forKeyword: 0x736E_616D  // 'snam'
            )
            let arguments = NSAppleEventDescriptor.list()
            for (index, parameter) in parameters.enumerated() {
                arguments.insert(parameter.descriptor, at: index + 1)
            }
            event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
            return event
        }
    }

    /// Compiles `source` and runs it on a serial queue, off the main thread.
    ///
    /// A task cancelled before its script starts runs nothing:
    /// cancellation is checked before the script is queued
    /// and again on the queue, after compiling and before any Apple event is sent.
    /// A script that has started runs to the end.
    ///
    /// - Parameters:
    ///   - source: The script's source. Pass a fixed script, not one built from untrusted text.
    ///   - subroutine: A handler of the script to run in place of the script's own `run` handler.
    /// - Returns: The result of the script.
    /// - Throws: ``ExecutionError`` when the script does not compile or fails,
    ///   or `CancellationError` when the task is cancelled before the script starts.
    static func execute(_ source: String, calling subroutine: Subroutine? = nil) async throws
        -> NSAppleEventDescriptor
    {
        try Task.checkCancellation()
        let isCancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                executionQueue.async {
                    guard let script = NSAppleScript(source: source) else {
                        continuation.resume(
                            throwing: ExecutionError(number: nil, message: "the script could not be loaded")
                        )
                        return
                    }
                    var errorInfo: NSDictionary?
                    guard script.compileAndReturnError(&errorInfo) else {
                        continuation.resume(throwing: ExecutionError(errorInfo: errorInfo))
                        return
                    }
                    errorInfo = nil
                    // The last point before an Apple event can be sent.
                    if isCancelled.withLock({ $0 }) {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let result =
                        if let subroutine {
                            script.executeAppleEvent(subroutine.event(), error: &errorInfo)
                        } else {
                            script.executeAndReturnError(&errorInfo)
                        }
                    if errorInfo != nil {
                        continuation.resume(throwing: ExecutionError(errorInfo: errorInfo))
                    } else {
                        continuation.resume(returning: result)
                    }
                }
            }
        } onCancel: {
            isCancelled.withLock { $0 = true }
        }
    }
}

extension NSAppleScript.Subroutine.Parameter {
    fileprivate var descriptor: NSAppleEventDescriptor {
        switch self {
        case .string(let value):
            return NSAppleEventDescriptor(string: value)
        case .boolean(let value):
            return NSAppleEventDescriptor(boolean: value)
        case .number(let value):
            return NSAppleEventDescriptor(double: value)
        case .strings(let values):
            let list = NSAppleEventDescriptor.list()
            for (index, value) in values.enumerated() {
                list.insert(NSAppleEventDescriptor(string: value), at: index + 1)
            }
            return list
        }
    }
}
