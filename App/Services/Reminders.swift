import CoreLocation
import EventKit
import Foundation
import JSONSchema
import OSLog
import Ontology
import OrderedCollections

private let log = Logger.service("reminders")

/// Reminder properties accepted by both `reminders_create` and `reminders_update`.
/// Passing `null` for an optional property in `reminders_update` clears it.
private let reminderProperties: OrderedDictionary<String, JSONSchema> = [
    "title": .string(),
    "notes": .string(description: "Notes for the reminder. Pass null to clear."),
    "url": .string(description: "URL attached to the reminder. Pass null to clear.", format: .uri),
    "list": .string(description: "Reminder list name"),
    "start": .string(
        description:
            "Start date/time for the reminder. If timezone is omitted, local time is assumed. Date-only uses local midnight. Pass null to clear.",
        format: .dateTime
    ),
    "due": .string(
        description:
            "Due date/time for the reminder. If timezone is omitted, local time is assumed. Date-only uses local midnight. Pass null to clear.",
        format: .dateTime
    ),
    "priority": .string(
        default: .string(EKReminderPriority.none.stringValue),
        enum: EKReminderPriority.allCases.map { .string($0.stringValue) }
    ),
    "alarms": .array(
        description: "Alarm configurations for the reminder. Pass null to remove all alarms.",
        items: .anyOf([
            // Relative alarm (minutes before due date)
            .object(
                properties: [
                    "type": .string(
                        const: "relative"
                    ),
                    "minutes": .integer(
                        description: "Minutes offset from the due date (positive is before)"
                    ),
                    "sound": .string(
                        description: "Sound name to play when alarm triggers",
                        enum: Sound.allCases.map { .string($0.rawValue) }
                    ),
                    "emailAddress": .string(
                        description: "Email address to send notification to"
                    ),
                ],
                required: ["minutes"],
                additionalProperties: false
            ),
            // Absolute alarm (specific date/time)
            .object(
                properties: [
                    "type": .string(
                        const: "absolute"
                    ),
                    "datetime": .string(
                        description:
                            "Alarm date/time. If timezone is omitted, local time is assumed.",
                        format: .dateTime
                    ),
                    "sound": .string(
                        description: "Sound name to play when alarm triggers",
                        enum: Sound.allCases.map { .string($0.rawValue) }
                    ),
                    "emailAddress": .string(
                        description: "Email address to send notification to"
                    ),
                ],
                required: ["datetime"],
                additionalProperties: false
            ),
            // Proximity alarm (location-based)
            .object(
                properties: [
                    "type": .string(
                        const: "proximity"
                    ),
                    "proximity": .string(
                        description: "Proximity trigger type",
                        default: .string("enter"),
                        enum: [.string("enter"), .string("leave")]
                    ),
                    "locationTitle": .string(),
                    "latitude": .number(),
                    "longitude": .number(),
                    "radius": .number(
                        description: "Radius in meters",
                        default: .int(200)
                    ),
                    "sound": .string(
                        description: "Sound name to play when alarm triggers",
                        enum: Sound.allCases.map { .string($0.rawValue) }
                    ),
                    "emailAddress": .string(
                        description: "Email address to send notification to"
                    ),
                ],
                required: ["locationTitle", "latitude", "longitude"],
                additionalProperties: false
            ),
        ])
    ),
]

final class RemindersService: Service {
    private let eventStore = EKEventStore()

    static let shared = RemindersService()

    var isActivated: Bool {
        get async {
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        }
    }

    func activate() async throws {
        try await eventStore.requestFullAccessToReminders()
    }

    var tools: [Tool] {
        Tool(
            name: "reminders_lists",
            description: "List available reminder lists",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Reminder Lists",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard try await self.eventStore.requestFullAccessToReminders() else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            let reminderLists = self.eventStore.calendars(for: .reminder)

            return reminderLists.map { reminderList in
                Value.object([
                    "identifier": .string(reminderList.calendarIdentifier),
                    "title": .string(reminderList.title),
                    "source": .string(reminderList.source.title),
                    "color": .string(reminderList.color.accessibilityName),
                    "isEditable": .bool(reminderList.allowsContentModifications),
                    "isSubscribed": .bool(reminderList.isSubscribed),
                ])
            }
        }

        Tool(
            name: "reminders_fetch",
            description: "Get reminders from the reminders app with flexible filtering options",
            inputSchema: .object(
                properties: [
                    "completed": .boolean(
                        description:
                            "If true, fetch completed reminders; if false, fetch incomplete; if omitted, fetch all"
                    ),
                    "start": .string(
                        description:
                            "Start date/time range for fetching reminders. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End date/time range for fetching reminders. If timezone is omitted, local time is assumed. A date-only value includes that whole day.",
                        format: .dateTime
                    ),
                    "lists": .array(
                        description:
                            "Names of reminder lists to fetch from; if empty, fetches from all lists",
                        items: .string()
                    ),
                    "query": .string(
                        description: "Text to search for in reminder titles"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Reminders",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard try await self.eventStore.requestFullAccessToReminders() else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            // Filter reminder lists based on provided names
            var reminderLists = self.eventStore.calendars(for: .reminder)
            if case .array(let listNames) = arguments["lists"],
                !listNames.isEmpty
            {
                let requestedNames = Set(
                    listNames.compactMap { $0.stringValue?.lowercased() }
                )
                reminderLists = reminderLists.filter {
                    requestedNames.contains($0.title.lowercased())
                }
            }

            // Parse dates if provided
            var startDate: Date? = nil
            var endDate: Date? = nil
            var startIsDateOnly = false
            var endIsDateOnly = false

            if case .string(let start) = arguments["start"],
                let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: start
                )
            {
                startDate = parsedStart.date
                startIsDateOnly = parsedStart.isDateOnly
            }
            if case .string(let end) = arguments["end"],
                let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: end
                )
            {
                endDate = parsedEnd.date
                endIsDateOnly = parsedEnd.isDateOnly
            }

            let calendar = Calendar.current
            if let startDateValue = startDate {
                startDate = calendar.normalizedStartDate(
                    from: startDateValue,
                    isDateOnly: startIsDateOnly
                )
            }
            if let endDateValue = endDate {
                endDate = calendar.normalizedEndDate(from: endDateValue, isDateOnly: endIsDateOnly)
            }

            // Choose predicates based on completion status: completed reminders match by
            // completion date and incomplete ones by due date.
            let completedPredicate = self.eventStore.predicateForCompletedReminders(
                withCompletionDateStarting: startDate,
                ending: endDate,
                calendars: reminderLists
            )
            let incompletePredicate = self.eventStore.predicateForIncompleteReminders(
                withDueDateStarting: startDate,
                ending: endDate,
                calendars: reminderLists
            )
            let predicates: [NSPredicate]
            if case .bool(let completed) = arguments["completed"] {
                predicates = [completed ? completedPredicate : incompletePredicate]
            } else if startDate != nil || endDate != nil {
                // Without a completion status, a date range applies to both kinds.
                predicates = [incompletePredicate, completedPredicate]
            } else {
                predicates = [self.eventStore.predicateForReminders(in: reminderLists)]
            }

            // Fetch reminders
            var reminders: [EKReminder] = []
            for predicate in predicates {
                reminders += try await withCheckedThrowingContinuation { continuation in
                    self.eventStore.fetchReminders(matching: predicate) { fetchedReminders in
                        continuation.resume(returning: fetchedReminders ?? [])
                    }
                }
            }

            // Apply additional filters
            var filteredReminders = reminders

            // Filter by search text if provided
            if case .string(let searchText) = arguments["query"],
                !searchText.isEmpty
            {
                filteredReminders = filteredReminders.filter {
                    $0.title?.localizedCaseInsensitiveContains(searchText) == true
                }
            }

            return filteredReminders.map { PlanAction($0) }
        }

        Tool(
            name: "reminders_create",
            description: "Create a new reminder with specified properties",
            inputSchema: .object(
                properties: reminderProperties,
                required: ["title"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Reminder",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard try await self.eventStore.requestFullAccessToReminders() else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            guard case .string(let title) = arguments["title"] else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder title is required"]
                )
            }

            let reminder = EKReminder(eventStore: self.eventStore)
            reminder.title = title

            // Set calendar (list), defaulting to the default list when the
            // provided name does not match an existing list.
            var calendar = self.eventStore.defaultCalendarForNewReminders()
            if case .string(let listName) = arguments["list"] {
                if let matchingCalendar = self.eventStore.calendars(for: .reminder)
                    .first(where: { $0.title.lowercased() == listName.lowercased() })
                {
                    calendar = matchingCalendar
                }
            }
            reminder.calendar = calendar

            try self.apply(arguments, to: reminder)

            // Save the reminder
            try self.eventStore.save(reminder, commit: true)

            return PlanAction(reminder)
        }

        Tool(
            name: "reminders_update",
            description:
                "Update an existing reminder. Only provide values for properties that need to be changed; omit any properties that should remain unchanged. Pass null to clear an optional property.",
            inputSchema: .object(
                properties: ([
                    "identifier": .string(
                        description:
                            "Identifier of the reminder to update, as returned by reminders_fetch or reminders_create"
                    )
                ] as OrderedDictionary)
                .merging(reminderProperties, uniquingKeysWith: { new, _ in new })
                .merging(
                    [
                        "completed": .boolean(
                            description:
                                "Completion state. Setting true records completion at the current time and advances recurring reminders; false clears the completion date."
                        )
                    ] as OrderedDictionary,
                    uniquingKeysWith: { new, _ in new }
                ),
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Update Reminder",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard try await self.eventStore.requestFullAccessToReminders() else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            guard case .string(let identifier) = arguments["identifier"] else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder identifier is required"]
                )
            }

            guard
                let reminder = self.eventStore.calendarItem(withIdentifier: identifier)
                    as? EKReminder
            else {
                throw NSError(
                    domain: "RemindersError",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey: "No reminder found with identifier \(identifier)"
                    ]
                )
            }

            // Move to another list when requested; unlike reminders_create,
            // an unmatched list name is an error rather than a silent default.
            if case .string(let listName) = arguments["list"] {
                guard
                    let matchingCalendar = self.eventStore.calendars(for: .reminder)
                        .first(where: { $0.title.lowercased() == listName.lowercased() })
                else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey: "No reminder list named \"\(listName)\""
                        ]
                    )
                }
                reminder.calendar = matchingCalendar
            }

            guard let targetList = reminder.calendar, targetList.allowsContentModifications else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Reminder list \"\(reminder.calendar?.title ?? "")\" does not allow modifications"
                    ]
                )
            }

            try self.apply(arguments, to: reminder)

            try self.eventStore.save(reminder, commit: true)

            return PlanAction(reminder)
        }

        Tool(
            name: "reminders_delete",
            description: "Delete a reminder by identifier",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description: "Identifier of the reminder to delete"
                    )
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Reminder",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard try await self.eventStore.requestFullAccessToReminders() else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            guard case .string(let identifier) = arguments["identifier"] else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder identifier is required"]
                )
            }

            guard
                let reminder = self.eventStore.calendarItem(withIdentifier: identifier)
                    as? EKReminder
            else {
                throw NSError(
                    domain: "RemindersError",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey: "No reminder found with identifier \(identifier)"
                    ]
                )
            }

            guard reminder.calendar?.allowsContentModifications != false else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Reminder list \"\(reminder.calendar?.title ?? "")\" does not allow modifications"
                    ]
                )
            }

            try self.eventStore.remove(reminder, commit: true)

            return Value.object([
                "deleted": .bool(true),
                "identifier": .string(identifier),
            ])
        }

        Tool(
            name: "reminders_lists_create",
            description: "Create a new reminder list",
            inputSchema: .object(
                properties: [
                    "title": .string(description: "Title of the new reminder list")
                ],
                required: ["title"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Reminder List",
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            guard try await self.eventStore.requestFullAccessToReminders() else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            guard case .string(let title) = arguments["title"], !title.isEmpty else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "List title is required"]
                )
            }

            // Prefer the source of the default list (usually iCloud), falling back
            // to the local source so the list is always creatable.
            guard
                let source = self.eventStore.defaultCalendarForNewReminders()?.source
                    ?? self.eventStore.sources.first(where: { $0.sourceType == .local })
                    ?? self.eventStore.sources.first
            else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: "No available source for a new reminder list"
                    ]
                )
            }

            let list = EKCalendar(for: .reminder, eventStore: self.eventStore)
            list.title = title
            list.source = source

            try self.eventStore.saveCalendar(list, commit: true)

            return Value.object([
                "identifier": .string(list.calendarIdentifier),
                "title": .string(list.title),
                "source": .string(list.source.title),
            ])
        }

        Tool(
            name: "reminders_lists_rename",
            description: "Rename a reminder list",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description:
                            "Identifier of the reminder list to rename, as returned by reminders_lists (preferred)"
                    ),
                    "name": .string(
                        description:
                            "Current name of the reminder list, used when identifier is omitted"
                    ),
                    "title": .string(description: "New title for the reminder list"),
                ],
                required: ["title"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Rename Reminder List",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard try await self.eventStore.requestFullAccessToReminders() else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            let list = try self.list(arguments)

            guard list.allowsContentModifications, !list.isImmutable else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Reminder list \"\(list.title)\" does not allow modifications"
                    ]
                )
            }

            guard case .string(let title) = arguments["title"], !title.isEmpty else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "New list title is required"]
                )
            }

            list.title = title

            try self.eventStore.saveCalendar(list, commit: true)

            return Value.object([
                "identifier": .string(list.calendarIdentifier),
                "title": .string(list.title),
                "source": .string(list.source.title),
            ])
        }

        Tool(
            name: "reminders_lists_delete",
            description:
                "Delete a reminder list and every reminder it contains. This cannot be undone.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description:
                            "Identifier of the reminder list to delete, as returned by reminders_lists (preferred)"
                    ),
                    "name": .string(
                        description:
                            "Name of the reminder list to delete, used when identifier is omitted"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Reminder List",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard try await self.eventStore.requestFullAccessToReminders() else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            let list = try self.list(arguments)

            guard list.allowsContentModifications, !list.isImmutable, !list.isSubscribed else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Reminder list \"\(list.title)\" does not allow modifications"
                    ]
                )
            }

            try self.eventStore.removeCalendar(list, commit: true)

            return Value.object([
                "deleted": .bool(true),
                "identifier": .string(list.calendarIdentifier),
            ])
        }
    }

    /// Applies optional properties from tool arguments to a reminder.
    /// A `null` value clears the corresponding property.
    private func apply(_ arguments: [String: Value], to reminder: EKReminder) throws {
        switch arguments["title"] {
        case .string(let title): reminder.title = title
        default: break
        }

        switch arguments["notes"] {
        case .string(let notes): reminder.notes = notes
        case .null: reminder.notes = nil
        default: break
        }

        switch arguments["url"] {
        case .string(let urlString):
            guard let url = URL(string: urlString) else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid URL \"\(urlString)\""]
                )
            }
            reminder.url = url
        case .null: reminder.url = nil
        default: break
        }

        if case .string(let dateString) = arguments["start"] {
            reminder.startDateComponents = try Self.dateComponents(
                fromDateString: dateString,
                description: "start"
            )
        } else if case .null = arguments["start"] {
            reminder.startDateComponents = nil
        }

        if case .string(let dateString) = arguments["due"] {
            reminder.dueDateComponents = try Self.dateComponents(
                fromDateString: dateString,
                description: "due"
            )
        } else if case .null = arguments["due"] {
            reminder.dueDateComponents = nil
        }

        if case .string(let priorityString) = arguments["priority"] {
            reminder.priority = Int(EKReminderPriority.from(string: priorityString).rawValue)
        }

        switch arguments["alarms"] {
        case .array(let alarmConfigs):
            reminder.alarms = alarmConfigs.compactMap { Self.alarm(from: $0) }
        case .null:
            reminder.alarms = []
        default: break
        }

        if case .bool(let completed) = arguments["completed"] {
            reminder.isCompleted = completed
        }
    }

    /// Parses an ISO 8601 date string into due/start date components,
    /// normalizing date-only values to local midnight.
    private static func dateComponents(
        fromDateString dateString: String,
        description: String
    ) throws -> DateComponents {
        guard
            let parsedDate = ISO8601DateFormatter.parsedLenientISO8601Date(
                fromISO8601String: dateString
            )
        else {
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Invalid \(description) date format. Expected ISO 8601 format."
                ]
            )
        }

        let calendar = Calendar.current
        let date = calendar.normalizedStartDate(
            from: parsedDate.date,
            isDateOnly: parsedDate.isDateOnly
        )
        return calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
    }

    /// Builds an alarm from an alarm configuration object.
    private static func alarm(from value: Value) -> EKAlarm? {
        guard case .object(let config) = value else { return nil }

        var alarm: EKAlarm?

        let alarmType = config["type"]?.stringValue ?? "relative"
        switch alarmType {
        case "relative":
            if case .int(let minutes) = config["minutes"] {
                alarm = EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
            }

        case "absolute":
            if case .string(let datetimeString) = config["datetime"] {
                if ISO8601DateFormatter.isDateOnlyISO8601String(datetimeString) {
                    log.error(
                        "Absolute alarm datetime must include time component: \(datetimeString, privacy: .public)"
                    )
                } else if let absoluteDate = ISO8601DateFormatter.lenientDate(
                    fromISO8601String: datetimeString
                ) {
                    alarm = EKAlarm(absoluteDate: absoluteDate)
                }
            }

        case "proximity":
            if case .string(let locationTitle) = config["locationTitle"],
                case .double(let latitude) = config["latitude"],
                case .double(let longitude) = config["longitude"]
            {
                let structuredLocation = EKStructuredLocation(title: locationTitle)
                structuredLocation.geoLocation = CLLocation(
                    latitude: latitude,
                    longitude: longitude
                )

                switch config["radius"] {
                case .double(let radius): structuredLocation.radius = radius
                case .int(let radius): structuredLocation.radius = Double(radius)
                default: break
                }

                alarm = EKAlarm()
                alarm?.proximity = config["proximity"]?.stringValue == "leave" ? .leave : .enter
                alarm?.structuredLocation = structuredLocation
            }

        default:
            log.error(
                "Unexpected alarm type encountered: \(alarmType, privacy: .public)"
            )
            return nil
        }

        guard let alarm = alarm else { return nil }

        if case .string(let soundName) = config["sound"],
            Sound(rawValue: soundName) != nil
        {
            alarm.soundName = soundName
        }

        if case .string(let email) = config["emailAddress"], !email.isEmpty {
            alarm.emailAddress = email
        }

        return alarm
    }

    /// Resolves a reminder list by identifier, falling back to a case-insensitive name match.
    private func list(_ arguments: [String: Value]) throws -> EKCalendar {
        let lists = eventStore.calendars(for: .reminder)

        if case .string(let identifier) = arguments["identifier"], !identifier.isEmpty {
            guard
                let matchingList = lists.first(where: {
                    $0.calendarIdentifier == identifier
                })
            else {
                throw NSError(
                    domain: "RemindersError",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey: "No reminder list found with identifier \(identifier)"
                    ]
                )
            }
            return matchingList
        }

        if case .string(let name) = arguments["name"], !name.isEmpty {
            guard
                let matchingList = lists.first(where: {
                    $0.title.lowercased() == name.lowercased()
                })
            else {
                throw NSError(
                    domain: "RemindersError",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey: "No reminder list named \"\(name)\""
                    ]
                )
            }
            return matchingList
        }

        throw NSError(
            domain: "RemindersError",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: "Reminder list identifier or name is required"
            ]
        )
    }
}
