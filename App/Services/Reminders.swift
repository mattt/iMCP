import CoreLocation
import EventKit
import Foundation
import JSONSchema
import MapKit
import OSLog
import Ontology
import OrderedCollections

private let log = Logger.service("reminders")

/// Day names as the reminders tools accept and emit them: bare names for
/// every week, ordinal-prefixed names for one weekday of the month.
private let recurrenceDayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
private let recurrenceDayValues =
    recurrenceDayNames
    + [
        "first", "second", "third", "fourth", "fifth", "last",
        "second-to-last", "third-to-last", "fourth-to-last", "fifth-to-last",
    ].flatMap { ordinal in
        recurrenceDayNames.map { "\(ordinal) \($0)" }
    }

private let monthNames = [
    "january", "february", "march", "april", "may", "june", "july", "august",
    "september", "october", "november", "december",
]

/// Reminder properties accepted by both `reminders_create` and `reminders_update`.
/// Passing `null` for an optional property in `reminders_update` clears it.
private let reminderProperties: OrderedDictionary<String, JSONSchema> = [
    "title": .string(),
    "notes": .anyOf([
        .string(description: "Notes for the reminder. Pass null to clear."),
        .null,
    ]),
    "url": .anyOf([
        .string(description: "URL attached to the reminder. Pass null to clear.", format: .uri),
        .null,
    ]),
    "list": .string(
        description:
            "Reminder list name, or the identifier of one of several lists sharing a name"
    ),
    "start": .anyOf([
        .string(
            description:
                "Start date/time for the reminder. If timezone is omitted, local time is assumed. Date-only uses local midnight. Pass null to clear.",
            format: .dateTime
        ),
        .null,
    ]),
    "due": .anyOf([
        .string(
            description:
                "Due date. YYYY-MM-DD is all-day; YYYY-MM-DD HH:MM is timed in local time; an ISO 8601 datetime with an offset such as Z or +02:00 is also accepted. Pass null to clear (a repeating reminder must keep its due date)."
        ),
        .null,
    ]),
    "recurrence": .anyOf([
        .string(
            description:
                "Recurrence spec: daily, weekly, monthly, or yearly, then optionally an interval xN and details. Examples: \"weekly mon,wed,fri\", \"monthly 1,15\", \"monthly 4th-fri\", \"monthly last-fri\", \"daily x2\", \"monthly x2 last-fri\". \"clear\", \"none\", or \"never\" stops repeating. A repeating reminder needs a due date."
        ),
        .object(
            description:
                "Recurrence rule for a repeating reminder. Pass null to stop repeating.",
            properties: [
                "frequency": .string(
                    description: "How often the reminder repeats",
                    enum: [
                        .string("daily"), .string("weekly"), .string("monthly"),
                        .string("yearly"),
                    ]
                ),
                "interval": .integer(
                    description: "Repeat every N units of the frequency",
                    default: .int(1),
                    minimum: 1
                ),
                "daysOfTheWeek": .array(
                    description:
                        "Days of the week the reminder repeats on; prefix an ordinal (first through fifth, last, or second-to-last through fifth-to-last) to repeat on one weekday of the month, e.g. \"second tuesday\"",
                    items: .string(enum: recurrenceDayValues.map { .string($0) })
                ),
                "daysOfTheMonth": .array(
                    description:
                        "Days of the month the reminder repeats on; nonzero, with negatives counting from the end (-1 is the last day)",
                    items: .integer(minimum: -31, maximum: 31)
                ),
                "monthsOfTheYear": .array(
                    description: "Months the reminder repeats in",
                    items: .string(enum: monthNames.map { .string($0) })
                ),
                "weeksOfTheYear": .array(
                    description:
                        "Weeks of the year the reminder repeats in; nonzero, with negatives counting from the end",
                    items: .integer(minimum: -53, maximum: 53)
                ),
                "daysOfTheYear": .array(
                    description:
                        "Days of the year the reminder repeats on; nonzero, with negatives counting from the end",
                    items: .integer(minimum: -366, maximum: 366)
                ),
                "setPositions": .array(
                    description:
                        "Which of the matched occurrences to keep; nonzero, e.g. -1 for the last one of each period",
                    items: .integer(minimum: -366, maximum: 366)
                ),
                "end": .object(
                    description:
                        "End condition; omit to repeat indefinitely. Pass date or count, not both.",
                    properties: [
                        "date": .string(
                            description:
                                "Date of the last occurrence (inclusive; a date-only value includes that whole day)",
                            format: .dateTime
                        ),
                        "count": .integer(
                            description: "Total number of occurrences",
                            minimum: 1
                        ),
                    ],
                    additionalProperties: false
                ),
            ],
            required: ["frequency"],
            additionalProperties: false
        ),
        .null,
    ]),
    "priority": .anyOf([
        .string(
            description: "Priority name",
            enum: EKReminderPriority.allCases.map { .string($0.stringValue) }
        ),
        .integer(
            description:
                "Apple priority number: 0 none, 1 to 4 high, 5 medium, 6 to 9 low",
            minimum: 0,
            maximum: 9
        ),
    ]),
    "alarms": .anyOf([
        .array(
            description: "Alarm configurations for the reminder. Pass null to remove all alarms.",
            items: .anyOf([
                // Relative alarm in minutes, as accepted before alarms took
                // structured configurations (kept for compatibility)
                .integer(description: "Minutes before the due date"),
                .string(
                    description:
                        "15m, 1h, 1d, or 1w before the due date (needs a due date), or a date such as 2026-05-27 09:30 for an absolute alarm"
                ),
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
                    required: ["type", "datetime"],
                    additionalProperties: false
                ),
                // Proximity alarm (location-based): a free-text location that is
                // geocoded, or explicit coordinates
                .anyOf([
                    .object(
                        properties: [
                            "type": .string(
                                const: "proximity"
                            ),
                            "proximity": .string(
                                description: "Proximity trigger type",
                                default: .string("enter"),
                                enum: [
                                    .string("enter"), .string("leave"), .string("arriving"),
                                    .string("leaving"),
                                ]
                            ),
                            "location": .string(
                                description:
                                    "Place name or address to trigger on, resolved with Maps"
                            ),
                            "radius": .number(
                                description: "Radius in meters. Omit to use the system default.",
                                minimum: 0
                            ),
                            "sound": .string(
                                description: "Sound name to play when alarm triggers",
                                enum: Sound.allCases.map { .string($0.rawValue) }
                            ),
                            "emailAddress": .string(
                                description: "Email address to send notification to"
                            ),
                        ],
                        required: ["type", "location"],
                        additionalProperties: false
                    ),
                    .object(
                        properties: [
                            "type": .string(
                                const: "proximity"
                            ),
                            "proximity": .string(
                                description: "Proximity trigger type",
                                default: .string("enter"),
                                enum: [
                                    .string("enter"), .string("leave"), .string("arriving"),
                                    .string("leaving"),
                                ]
                            ),
                            "locationTitle": .string(
                                description:
                                    "Title of the place (for example Apple Park); used with latitude and longitude"
                            ),
                            "latitude": .number(
                                minimum: -90,
                                maximum: 90
                            ),
                            "longitude": .number(
                                minimum: -180,
                                maximum: 180
                            ),
                            "radius": .number(
                                description: "Radius in meters. Omit to use the system default.",
                                minimum: 0
                            ),
                            "sound": .string(
                                description: "Sound name to play when alarm triggers",
                                enum: Sound.allCases.map { .string($0.rawValue) }
                            ),
                            "emailAddress": .string(
                                description: "Email address to send notification to"
                            ),
                        ],
                        required: ["type", "locationTitle", "latitude", "longitude"],
                        additionalProperties: false
                    ),
                    .object(
                        properties: [
                            "type": .string(
                                const: "proximity"
                            ),
                            "proximity": .string(
                                description: "Proximity trigger type",
                                default: .string("enter"),
                                enum: [
                                    .string("enter"), .string("leave"), .string("arriving"),
                                    .string("leaving"),
                                ]
                            ),
                            "address": .string(
                                description:
                                    "Street address with a town or postal code. Geocoded strictly: an ambiguous, imprecise, or unconfirmed match is refused. Use reminders_resolve_location to preview the match."
                            ),
                            "locationTitle": .string(
                                description: "Title for the alarm; defaults to the match's name"
                            ),
                            "radius": .number(
                                description: "Radius in meters, 1 to 100000; default 100",
                                minimum: 1,
                                maximum: 100_000
                            ),
                            "sound": .string(
                                description: "Sound name to play when alarm triggers",
                                enum: Sound.allCases.map { .string($0.rawValue) }
                            ),
                            "emailAddress": .string(
                                description: "Email address to send notification to"
                            ),
                        ],
                        required: ["type", "address"],
                        additionalProperties: false
                    ),
                ]),
            ])
        ),
        .null,
    ]),
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
                    "colorHex": Self.hex(of: reminderList).map { .string($0) } ?? .null,
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

            return JSONLDGraph(try filteredReminders.map { try self.payload(for: $0, isListItem: true) })
        }

        Tool(
            name: "reminders_create",
            description: "Create a new reminder with specified properties",
            inputSchema: .object(
                properties: reminderProperties.merging(
                    [
                        // Create keeps its pre-existing lenient fallback; the
                        // shared entry has to stay neutral because update is
                        // strict about unmatched names.
                        "list": .string(
                            description:
                                "Reminder list name, or the identifier of one of several lists sharing a name. An unmatched name uses the default list."
                        )
                    ] as OrderedDictionary,
                    uniquingKeysWith: { _, new in new }
                ),
                required: ["title"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Reminder",
                destructiveHint: true,
                // Proximity alarms can geocode a location through Maps.
                openWorldHint: true
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

            // inputSchema is advertised, not enforced: `completed` belongs to
            // the update schema only, and a create that carried it would
            // otherwise silently create a completed reminder.
            try Self.rejectUnknownKeys(arguments, allowed: Set(reminderProperties.keys))

            let reminder = EKReminder(eventStore: self.eventStore)
            reminder.title = title

            // Set calendar (list), defaulting to the default list when the
            // provided name does not match an existing list.
            var calendar = self.eventStore.defaultCalendarForNewReminders()
            switch arguments["list"] {
            case nil: break
            case .string(let listName):
                calendar = try self.listIfPresent(named: listName) ?? calendar
            default:
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "List must be a string."]
                )
            }
            reminder.calendar = calendar

            try await self.apply(arguments, to: reminder)

            // Save the reminder
            try self.eventStore.save(reminder, commit: true)

            return try self.payload(for: reminder)
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
                .merging(reminderProperties, uniquingKeysWith: { _, new in new })
                .merging(
                    [
                        // The shared entries carry create-specific behavior;
                        // for an update, omission means "leave unchanged", so
                        // advertising create's priority default would have
                        // clients wipe priorities they never meant to touch,
                        // and create's unmatched-list fallback is an error.
                        "priority": .anyOf([
                            .string(
                                description: "Priority name; omit to leave unchanged",
                                enum: EKReminderPriority.allCases.map { .string($0.stringValue) }
                            ),
                            .integer(
                                description:
                                    "Apple priority number: 0 none, 1 to 4 high, 5 medium, 6 to 9 low; omit to leave unchanged",
                                minimum: 0,
                                maximum: 9
                            ),
                        ]),
                        "list": .string(
                            description:
                                "Reminder list name, or the identifier of one of several lists sharing a name. Must match an existing list."
                        ),
                    ] as OrderedDictionary,
                    uniquingKeysWith: { _, new in new }
                )
                .merging(
                    [
                        "completed": .boolean(
                            description:
                                "Completion state. Setting true records completion at the current time and advances recurring reminders; false clears the completion date."
                        ),
                        "completion_date": .string(
                            description:
                                "When it was completed: YYYY-MM-DD or YYYY-MM-DD HH:MM. Only with completed true, and not for a repeating reminder."
                        ),
                    ] as OrderedDictionary,
                    uniquingKeysWith: { _, new in new }
                ),
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Update Reminder",
                readOnlyHint: false,
                destructiveHint: true,
                // Proximity alarms can geocode a location through Maps.
                openWorldHint: true
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

            // inputSchema is advertised, not enforced: an unexpected key is
            // an error, not a silent no-op.
            try Self.rejectUnknownKeys(
                arguments,
                allowed: Set(reminderProperties.keys).union([
                    "identifier", "completed", "completion_date",
                ])
            )

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
            // The move happens after apply: EventKit retains unsaved
            // mutations, so a validation error must not leave it behind.
            let targetList: EKCalendar?
            switch arguments["list"] {
            case nil: targetList = nil
            case .string(let listName):
                targetList = try self.list(named: listName)
            default:
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "List must be a string."]
                )
            }

            // Modifiability is checked before anything is mutated: EventKit
            // retains unsaved mutations in its shared store, so throwing
            // after apply would leave them for the next successful save.
            let finalList = targetList ?? reminder.calendar
            guard let finalList, finalList.allowsContentModifications else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Reminder list \"\(finalList?.title ?? "")\" does not allow modifications"
                    ]
                )
            }

            try await self.apply(arguments, to: reminder)

            if let targetList {
                reminder.calendar = targetList
            }

            // EventKit can still reject the changed reminder when it saves,
            // and its own checks can't all run before apply.
            // Roll back the local changes on failure
            // so that the shared store doesn't keep them for a later save.
            do {
                try self.eventStore.save(reminder, commit: true)
            } catch {
                reminder.rollback()
                throw error
            }

            return try self.payload(for: reminder)
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

            try Self.rejectUnknownKeys(arguments, allowed: ["identifier"])

            // Deletion uses its own store because removing a reminder runs a
            // consent check that can fail with EKErrorDomain 29 on the shared
            // store after a first-time grant, while other operations succeed
            // (#315). A stale authorization status on the long-lived store is
            // the suspected cause, but this is not confirmed.
            let eventStore = EKEventStore()

            guard
                let reminder = eventStore.calendarItem(withIdentifier: identifier)
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

            try eventStore.remove(reminder, commit: true)

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
                    "title": .string(description: "Title of the new reminder list"),
                    "color": .string(
                        description:
                            "red, orange, yellow, green, blue, purple, brown, gray, cyan, teal, or #RRGGBB"
                    ),
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
            try Self.rejectUnknownKeys(arguments, allowed: ["title", "color"])
            let color = try Self.colorChange(arguments["color"])

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
            if let color { list.cgColor = color }

            try self.eventStore.saveCalendar(list, commit: true)

            return Value.object([
                "identifier": .string(list.calendarIdentifier),
                "title": .string(list.title),
                "source": .string(list.source.title),
                "color": .string(list.color.accessibilityName),
                "colorHex": Self.hex(of: list).map { .string($0) } ?? .null,
            ])
        }

        Tool(
            name: "reminders_lists_rename",
            // MCP requires `type: "object"` at the root of inputSchema,
            // and JSONSchema cannot add anyOf to an object schema,
            // so the descriptions of this tool and reminders_lists_delete
            // state that one selector is required.
            // list(_:) rejects a request that has neither.
            description: "Rename a reminder list. Either identifier or name is required.",
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

            try Self.rejectUnknownKeys(arguments, allowed: ["identifier", "name", "title"])
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

            // EventKit can still reject the renamed list when it saves.
            // Roll back the title on failure
            // so that the shared store doesn't keep it for a later save.
            do {
                try self.eventStore.saveCalendar(list, commit: true)
            } catch {
                list.rollback()
                throw error
            }

            return Value.object([
                "identifier": .string(list.calendarIdentifier),
                "title": .string(list.title),
                "source": .string(list.source.title),
            ])
        }

        Tool(
            name: "reminders_lists_delete",
            description:
                "Delete a reminder list and every reminder it contains. This cannot be undone. Either identifier or name is required.",
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

            try Self.rejectUnknownKeys(arguments, allowed: ["identifier", "name"])
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

        // MARK: Named views, search, and single reads
        //
        // The behavior follows viticci/remctl (MIT).

        Tool(
            name: "reminders_today",
            description:
                "Incomplete reminders due today, plus overdue ones unless include_overdue is false. Sorted by due date.",
            inputSchema: .object(
                properties: [
                    "include_overdue": .boolean(
                        description: "Include reminders due before today (default true)",
                        default: .bool(true)
                    )
                ],
                additionalProperties: false
            ),
            annotations: .init(title: "Reminders Due Today", readOnlyHint: true, openWorldHint: false)
        ) { arguments in
            try await self.requireAccess()
            try Self.rejectUnknownKeys(arguments, allowed: ["include_overdue"])
            let includeOverdue = try Self.boolArgument(arguments["include_overdue"], default: true)
            return try await self.view(.today(includeOverdue: includeOverdue))
        }

        Tool(
            name: "reminders_upcoming",
            description:
                "Incomplete reminders due from the start of today through the end of the day `days` days ahead (days 1 covers today and tomorrow). Sorted by due date.",
            inputSchema: .object(
                properties: [
                    "days": .integer(
                        description: "Days ahead, 1 to 365 (default 7)",
                        default: .int(7),
                        minimum: 1,
                        maximum: 365
                    )
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Upcoming Reminders",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.requireAccess()
            try Self.rejectUnknownKeys(arguments, allowed: ["days"])
            let days: Int?
            switch arguments["days"] {
            case nil: days = nil
            case .some(let value): days = try Self.integerValue(value, description: "days")
            }
            return try await self.view(.upcoming(days: try RemindersQuery.validatedUpcomingDays(days)))
        }

        Tool(
            name: "reminders_overdue",
            description:
                "Incomplete reminders that are overdue: an all-day reminder due before today, or a timed one whose time has passed. Sorted by due date.",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "Overdue Reminders",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.requireAccess()
            try Self.rejectUnknownKeys(arguments, allowed: [])
            return try await self.view(.overdue)
        }

        Tool(
            name: "reminders_search",
            description:
                "Search reminder titles, notes, and URLs. Ignores case and accents (cafe finds Café); % _ and \\ are ordinary characters. Newest first, with paging: pass nextOffset as offset until hasMore is false.",
            inputSchema: .object(
                properties: [
                    "query": .string(description: "Text to find in titles, notes, or URLs"),
                    "include_completed": .boolean(
                        description: "Also search completed reminders (default false)",
                        default: .bool(false)
                    ),
                    "list": .string(description: "Limit to the list with this name"),
                    "list_id": .string(
                        description: "Limit to the list with this identifier, as returned by reminders_lists"
                    ),
                    "limit": .integer(
                        description: "Page size, 1 to 500 (default 100)",
                        default: .int(100),
                        minimum: 1,
                        maximum: 500
                    ),
                    "offset": .integer(description: "Items to skip (default 0)", minimum: 0),
                ],
                required: ["query"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Reminders",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.requireAccess()
            try Self.rejectUnknownKeys(
                arguments,
                allowed: ["query", "include_completed", "list", "list_id", "limit", "offset"]
            )
            guard case .string(let query) = arguments["query"] else {
                throw RemindersInputError(code: "invalid_query", message: "query is required.")
            }
            let includeCompleted = try Self.boolArgument(
                arguments["include_completed"],
                default: false
            )
            let paging = try RemindersQuery.validatedPaging(
                limit: try arguments["limit"].map { try Self.integerValue($0, description: "limit") },
                offset: try arguments["offset"].map {
                    try Self.integerValue($0, description: "offset")
                }
            )
            let calendars = try self.listFilter(arguments)

            let reminders = try await self.fetch(
                self.eventStore.predicateForReminders(in: calendars)
            )
            let matches =
                reminders
                .filter { includeCompleted || !$0.isCompleted }
                .filter {
                    RemindersQuery.matches(
                        query: query,
                        fields: [$0.title, $0.notes, $0.url?.absoluteString]
                    )
                }
                .sorted {
                    let lhs = $0.creationDate ?? .distantPast
                    let rhs = $1.creationDate ?? .distantPast
                    return lhs == rhs
                        ? $0.calendarItemIdentifier < $1.calendarItemIdentifier : lhs > rhs
                }
            let page = RemindersQuery.page(matches, limit: paging.limit, offset: paging.offset)
            return Value.object([
                "items": .array(page.items.map { self.detail(for: $0) }),
                "count": .int(page.count),
                "total": .int(page.total),
                "offset": .int(page.offset),
                "limit": .int(page.limit),
                "hasMore": .bool(page.hasMore),
                "nextOffset": page.nextOffset.map { .int($0) } ?? .null,
            ])
        }

        Tool(
            name: "reminders_get",
            description:
                "Get one reminder by identifier with every field: list, notes, dates, all-day flag, priority, URL, alarms (relative, absolute, location), recurrence, and completion.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description: "Reminder identifier, as returned by any reminders tool"
                    )
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(title: "Get Reminder", readOnlyHint: true, openWorldHint: false)
        ) { arguments in
            try await self.requireAccess()
            try Self.rejectUnknownKeys(arguments, allowed: ["identifier"])
            guard case .string(let identifier) = arguments["identifier"],
                let reminder = self.eventStore.calendarItem(withIdentifier: identifier)
                    as? EKReminder
            else {
                throw RemindersInputError(
                    code: "reminder_not_found",
                    message: "No reminder found with that identifier."
                )
            }
            return self.detail(for: reminder)
        }

        Tool(
            name: "reminders_lists_get",
            description:
                "Get one reminder list by identifier or name with its color and counts of active, completed, and overdue reminders. Either identifier or name is required.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description: "Identifier of the list, as returned by reminders_lists (preferred)"
                    ),
                    "name": .string(description: "Name of the list, used when identifier is omitted"),
                ],
                additionalProperties: false
            ),
            annotations: .init(title: "Get Reminder List", readOnlyHint: true, openWorldHint: false)
        ) { arguments in
            try await self.requireAccess()
            try Self.rejectUnknownKeys(arguments, allowed: ["identifier", "name"])
            let list = try self.list(arguments)
            let reminders = try await self.fetch(
                self.eventStore.predicateForReminders(in: [list])
            )
            let now = Date()
            let calendar = Calendar.current
            let active = reminders.filter { !$0.isCompleted }
            return Value.object([
                "identifier": .string(list.calendarIdentifier),
                "title": .string(list.title),
                "source": .string(list.source.title),
                "color": .string(list.color.accessibilityName),
                "colorHex": Self.hex(of: list).map { .string($0) } ?? .null,
                "isEditable": .bool(list.allowsContentModifications),
                "isSubscribed": .bool(list.isSubscribed),
                "activeCount": .int(active.count),
                "completedCount": .int(reminders.count - active.count),
                "overdueCount": .int(
                    active.filter {
                        RemindersQuery.Views.isOverdue(
                            $0.dueDateComponents,
                            now: now,
                            calendar: calendar
                        )
                    }.count
                ),
            ])
        }

        // MARK: Batch writes

        Tool(
            name: "reminders_complete",
            description:
                "Complete or uncomplete up to 50 reminders. Each reminder is written once and never retried; the result lists succeeded, failed, and uncertain identifiers. An uncertain one may have changed: read it back with reminders_get before trying again. Completing a repeating reminder advances it by one occurrence.",
            inputSchema: .object(
                properties: [
                    "identifiers": .array(
                        description: "Reminder identifiers, 1 to 50",
                        items: .string(),
                        minItems: 1,
                        maxItems: 50
                    ),
                    "completed": .boolean(
                        description: "true to complete (default), false to uncomplete",
                        default: .bool(true)
                    ),
                    "completion_date": .string(
                        description:
                            "When it was completed: YYYY-MM-DD or YYYY-MM-DD HH:MM. Not allowed for repeating reminders or when uncompleting."
                    ),
                ],
                required: ["identifiers"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Complete Reminders",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            // Completing is an update: respect the reminders_update switch
            // before any reminder is fetched.
            guard !RemindersQuery.isUpdateDisabled() else {
                throw RemindersInputError(
                    code: "tool_disabled",
                    message: "Batch completion is unavailable while reminders_update is disabled."
                )
            }
            try await self.requireAccess()
            try Self.rejectUnknownKeys(
                arguments,
                allowed: ["identifiers", "completed", "completion_date"]
            )
            let plan = try Self.batchPlan(arguments["identifiers"])
            let completed = try Self.boolArgument(arguments["completed"], default: true)
            var completionDate: Date?
            switch arguments["completion_date"] {
            case nil, .null: break
            case .string(let text):
                guard completed else {
                    throw RemindersInputError(
                        code: "completion_date_requires_completed",
                        message: "completion_date applies only when completing."
                    )
                }
                completionDate = try RemindersQuery.parseCompletionDate(text)
            default:
                throw RemindersInputError(
                    code: "invalid_completion_date",
                    message: "completion_date must be YYYY-MM-DD or YYYY-MM-DD HH:MM."
                )
            }
            return self.runBatch(
                operation: completed ? "complete" : "uncomplete",
                plan: plan,
                store: self.eventStore
            ) { store, identifier in
                guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder
                else { return .failed("reminder_not_found", "No reminder found with that identifier.") }
                guard reminder.calendar?.allowsContentModifications != false else {
                    return .failed(
                        "list_not_modifiable",
                        "Reminder list \"\(reminder.calendar?.title ?? "")\" does not allow modifications"
                    )
                }
                let repeating = !(reminder.recurrenceRules ?? []).isEmpty
                if completionDate != nil, repeating {
                    return .failed(
                        "completion_date_not_allowed_for_repeating",
                        "A repeating reminder cannot take a completion date; completing it advances the series."
                    )
                }
                if reminder.isCompleted == completed, completionDate == nil, !repeating {
                    return .unchanged
                }
                reminder.isCompleted = completed
                if let completionDate { reminder.completionDate = completionDate }
                do {
                    try store.save(reminder, commit: true)
                    return .changed
                } catch {
                    reminder.rollback()
                    // The write threw. It may still have landed, so look at
                    // the stored state through a fresh store; never retry.
                    // A repeating reminder advances instead of flipping, so
                    // its stored state cannot settle the question.
                    let stored = EKEventStore().calendarItem(withIdentifier: identifier) as? EKReminder
                    if repeating {
                        return .uncertain(error.localizedDescription)
                    }
                    guard let stored else {
                        // The reminder is gone, so the write cannot be
                        // confirmed either way. Report it and stop the batch.
                        return .uncertain(
                            "The reminder could not be read back after the write failed, so it may or may not have changed."
                        )
                    }
                    if stored.isCompleted == completed {
                        return .uncertain(error.localizedDescription)
                    }
                    return .failed("write_failed", error.localizedDescription)
                }
            }
        }

        Tool(
            name: "reminders_delete_batch",
            description:
                "Delete up to 50 reminders. Each is deleted once and never retried; the result lists succeeded, failed, and uncertain identifiers. An uncertain one may already be gone: check with reminders_get before trying again.",
            inputSchema: .object(
                properties: [
                    "identifiers": .array(
                        description: "Reminder identifiers, 1 to 50",
                        items: .string(),
                        minItems: 1,
                        maxItems: 50
                    )
                ],
                required: ["identifiers"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Reminders",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard !RemindersQuery.isDeleteDisabled() else {
                throw RemindersInputError(
                    code: "tool_disabled",
                    message: "Batch deletion is unavailable while reminders_delete is disabled."
                )
            }
            try await self.requireAccess()
            try Self.rejectUnknownKeys(arguments, allowed: ["identifiers"])
            let plan = try Self.batchPlan(arguments["identifiers"])
            // Deletion uses its own store; see reminders_delete.
            return self.runBatch(operation: "delete", plan: plan, store: EKEventStore()) {
                store,
                identifier in
                guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder
                else { return .failed("reminder_not_found", "No reminder found with that identifier.") }
                guard reminder.calendar?.allowsContentModifications != false else {
                    return .failed(
                        "list_not_modifiable",
                        "Reminder list \"\(reminder.calendar?.title ?? "")\" does not allow modifications"
                    )
                }
                do {
                    try store.remove(reminder, commit: true)
                    return .changed
                } catch {
                    // The batch shares one store. Drop the pending removal so
                    // a later item's commit cannot apply a delete reported
                    // here as failed or uncertain.
                    store.reset()
                    if EKEventStore().calendarItem(withIdentifier: identifier) == nil {
                        return .uncertain(error.localizedDescription)
                    }
                    return .failed("write_failed", error.localizedDescription)
                }
            }
        }

        // MARK: Locations

        Tool(
            name: "reminders_resolve_location",
            description:
                "Geocode a street address without writing anything, so you can review the match before using it in a location alarm. Refuses a match that is ambiguous, covers more than about a kilometer, does not carry the street or place you typed, or has no town or postal code in the query. Apple's geocoder resolves addresses better than business names.",
            inputSchema: .object(
                properties: [
                    "query": .string(
                        description:
                            "Street address with a town or postal code, for example 1 Apple Park Way, Cupertino"
                    )
                ],
                required: ["query"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Resolve Location",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            try Self.rejectUnknownKeys(arguments, allowed: ["query"])
            guard case .string(let query) = arguments["query"],
                !query.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                throw RemindersInputError(code: "invalid_query", message: "query is required.")
            }
            let match = try await Self.resolveAddress(query)
            return Value.object([
                "query": .string(query),
                "title": match.name.map { .string($0) } ?? .null,
                "address": .string(match.summary),
                "latitude": .double(match.latitude),
                "longitude": .double(match.longitude),
                "radiusMeters": match.radiusMeters.map { .double($0) } ?? .null,
            ])
        }

        // MARK: Lists

        Tool(
            name: "reminders_lists_update",
            description:
                "Change a reminder list's title or color. Either identifier or name selects the list; pass title, color, or both.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description: "Identifier of the list, as returned by reminders_lists (preferred)"
                    ),
                    "name": .string(description: "Current name of the list, used when identifier is omitted"),
                    "title": .string(description: "New title"),
                    "color": .string(
                        description:
                            "red, orange, yellow, green, blue, purple, brown, gray, cyan, teal, or #RRGGBB"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Update Reminder List",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            // Renaming is gated by its own switch, before any list is read;
            // a color change is not a rename.
            let wantsRename = arguments["title"] != nil
            if wantsRename, RemindersQuery.isListRenameDisabled() {
                throw RemindersInputError(
                    code: "tool_disabled",
                    message: "Renaming a list is unavailable while reminders_lists_rename is disabled."
                )
            }
            try await self.requireAccess()
            try Self.rejectUnknownKeys(arguments, allowed: ["identifier", "name", "title", "color"])
            let list = try self.list(arguments)
            guard list.allowsContentModifications, !list.isImmutable else {
                throw RemindersInputError(
                    code: "list_not_modifiable",
                    message: "Reminder list \"\(list.title)\" does not allow modifications"
                )
            }
            guard arguments["title"] != nil || arguments["color"] != nil else {
                throw RemindersInputError(
                    code: "nothing_to_update",
                    message: "Pass title, color, or both."
                )
            }
            var newTitle: String?
            switch arguments["title"] {
            case nil: break
            case .string(let title) where !title.isEmpty: newTitle = title
            default:
                throw RemindersInputError(
                    code: "invalid_title",
                    message: "title must be a non-empty string."
                )
            }
            let newColor = try Self.colorChange(arguments["color"])
            if let newTitle { list.title = newTitle }
            if let newColor { list.cgColor = newColor }
            do {
                try self.eventStore.saveCalendar(list, commit: true)
            } catch {
                list.rollback()
                throw error
            }
            return Value.object([
                "identifier": .string(list.calendarIdentifier),
                "title": .string(list.title),
                "source": .string(list.source.title),
                "color": .string(list.color.accessibilityName),
                "colorHex": Self.hex(of: list).map { .string($0) } ?? .null,
            ])
        }
    }

    // MARK: - Shared helpers for the views, search, and batch tools

    private func requireAccess() async throws {
        guard try await eventStore.requestFullAccessToReminders() else {
            log.error("Reminders access not authorized")
            throw NSError(
                domain: "RemindersError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
            )
        }
    }

    private func fetch(_ predicate: NSPredicate) async throws -> [EKReminder] {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    /// The lists named by `list` or `list_id`, or nil for every list.
    private func listFilter(_ arguments: [String: Value]) throws -> [EKCalendar]? {
        switch (arguments["list"], arguments["list_id"]) {
        case (nil, nil): return nil
        case (.some, .some):
            throw RemindersInputError(
                code: "list_conflict",
                message: "Pass list or list_id, not both."
            )
        case (.some(.string(let name)), nil): return [try list(named: name)]
        case (nil, .some(.string(let identifier))):
            return [try list(["identifier": .string(identifier)])]
        default:
            throw RemindersInputError(
                code: "invalid_list",
                message: "list and list_id must be strings."
            )
        }
    }

    private static func boolArgument(_ value: Value?, default defaultValue: Bool) throws -> Bool {
        switch value {
        case nil: return defaultValue
        case .bool(let bool): return bool
        default:
            throw RemindersInputError(code: "invalid_argument", message: "Expected a boolean.")
        }
    }

    private static func batchPlan(_ value: Value?) throws -> (unique: [String], duplicatesIgnored: [String]) {
        guard case .array(let values) = value else {
            throw RemindersInputError(
                code: "invalid_identifiers",
                message: "identifiers must be an array of 1 to 50 strings."
            )
        }
        let identifiers = try values.map { value -> String in
            guard case .string(let identifier) = value else {
                throw RemindersInputError(
                    code: "invalid_identifiers",
                    message: "identifiers must be an array of 1 to 50 strings."
                )
            }
            return identifier
        }
        let plan = try RemindersQuery.batchPlan(identifiers)
        return (plan.unique, plan.duplicatesIgnored)
    }

    private enum ViewKind {
        case today(includeOverdue: Bool)
        case upcoming(days: Int)
        case overdue
    }

    private func view(_ kind: ViewKind) async throws -> Value {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let upperBound: Int
        switch kind {
        case .today, .overdue: upperBound = 1
        case .upcoming(let days): upperBound = days + 1
        }
        guard let end = calendar.date(byAdding: .day, value: upperBound, to: startOfToday) else {
            return .array([])
        }
        // Over-fetch to the end of the window and decide each reminder's
        // view locally, so all-day and timed reminders follow the same rules.
        let reminders = try await fetch(
            eventStore.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: end,
                calendars: nil
            )
        )
        let selected = reminders.filter { reminder in
            let due = reminder.dueDateComponents
            switch kind {
            case .today(let includeOverdue):
                return RemindersQuery.Views.isDueToday(due, now: now, calendar: calendar)
                    || (includeOverdue
                        && RemindersQuery.Views.isOverdue(due, now: now, calendar: calendar))
            case .upcoming(let days):
                return RemindersQuery.Views.isUpcoming(due, days: days, now: now, calendar: calendar)
            case .overdue:
                return RemindersQuery.Views.isOverdue(due, now: now, calendar: calendar)
            }
        }
        .sorted {
            let lhs = RemindersQuery.Views.dueDate(of: $0.dueDateComponents ?? DateComponents(), calendar: calendar)
            let rhs = RemindersQuery.Views.dueDate(of: $1.dueDateComponents ?? DateComponents(), calendar: calendar)
            return (lhs ?? .distantFuture, $0.calendarItemIdentifier)
                < (rhs ?? .distantFuture, $1.calendarItemIdentifier)
        }
        return Value.object([
            "items": .array(selected.map { detail(for: $0) }),
            "count": .int(selected.count),
        ])
    }

    /// Local wall-clock text for a due date: a bare date for an all-day
    /// reminder, date and time for a timed one.
    private static func dueString(_ components: DateComponents) -> String? {
        guard let year = components.year, let month = components.month, let day = components.day
        else { return nil }
        let date = String(format: "%04d-%02d-%02d", year, month, day)
        guard let hour = components.hour else { return date }
        return date + String(format: "T%02d:%02d:00", hour, components.minute ?? 0)
    }

    /// Every field the reminder tools expose, as plain JSON.
    private func detail(for reminder: EKReminder) -> Value {
        var fields: [String: Value] = [
            "identifier": .string(reminder.calendarItemIdentifier),
            "title": .string(reminder.title ?? ""),
            "completed": .bool(reminder.isCompleted),
            "priority": .string(RemindersQuery.priorityName(for: reminder.priority)),
            "priorityValue": .int(reminder.priority),
        ]
        if let list = reminder.calendar {
            fields["list"] = .string(list.title)
            fields["listIdentifier"] = .string(list.calendarIdentifier)
        }
        if let notes = reminder.notes { fields["notes"] = .string(notes) }
        if let url = reminder.url { fields["url"] = .string(url.absoluteString) }
        if let due = reminder.dueDateComponents, let text = Self.dueString(due) {
            fields["dueDate"] = .string(text)
            fields["allDay"] = .bool(due.hour == nil)
        }
        if let start = reminder.startDateComponents, let text = Self.dueString(start) {
            fields["startDate"] = .string(text)
        }
        if let completionDate = reminder.completionDate {
            fields["completedAt"] = .string(Self.iso8601String(completionDate))
        }
        if let created = reminder.creationDate {
            fields["createdAt"] = .string(Self.iso8601String(created))
        }
        if let modified = reminder.lastModifiedDate {
            fields["modifiedAt"] = .string(Self.iso8601String(modified))
        }
        if let rule = reminder.recurrenceRules?.first {
            fields["recurrence"] = Self.value(for: rule)
        }
        let alarms = (reminder.alarms ?? []).map { Self.value(for: $0) }
        if !alarms.isEmpty { fields["alarms"] = .array(alarms) }
        return .object(fields)
    }

    private static func value(for alarm: EKAlarm) -> Value {
        if let location = alarm.structuredLocation {
            var fields: [String: Value] = [
                "type": .string("location"),
                "proximity": .string(alarm.proximity == .leave ? "leave" : "enter"),
                "title": .string(location.title ?? ""),
                "radius": .double(location.radius),
            ]
            if let geo = location.geoLocation {
                fields["latitude"] = .double(geo.coordinate.latitude)
                fields["longitude"] = .double(geo.coordinate.longitude)
            }
            return .object(fields)
        }
        if let date = alarm.absoluteDate {
            return .object([
                "type": .string("absolute"),
                "datetime": .string(iso8601String(date)),
            ])
        }
        // A stored alarm can carry any offset. Convert without trapping: an
        // offset beyond the alarm limit is reported at the nearest bound.
        let minutes = RemindersQuery.relativeAlarmMinutes(alarm.relativeOffset)
        return .object([
            "type": .string("relative"),
            "minutes": .int(minutes),
            "label": .string(RemindersQuery.relativeAlarmLabel(minutes: minutes)),
        ])
    }

    /// What one write in a batch did.
    private enum BatchOutcome {
        case changed
        case unchanged
        case failed(String, String)
        case uncertain(String)
    }

    /// Runs one write per identifier, in order, never retrying. After an
    /// uncertain write the rest are skipped, because they would likely stall
    /// the same way and the first one needs checking.
    private func runBatch(
        operation: String,
        plan: (unique: [String], duplicatesIgnored: [String]),
        store: EKEventStore,
        _ write: (EKEventStore, String) -> BatchOutcome
    ) -> Value {
        var results: [Value] = []
        var statuses: [RemindersQuery.BatchStatus] = []
        var succeeded: [Value] = []
        var failed: [Value] = []
        var uncertain: [Value] = []
        var stop = false

        for identifier in plan.unique {
            var fields: [String: Value] = ["identifier": .string(identifier)]
            let status: RemindersQuery.BatchStatus
            if stop {
                status = .skipped
                fields["status"] = .string("skipped")
                fields["code"] = .string("skipped_after_uncertain")
                fields["message"] = .string("Not attempted: an earlier write in this batch was uncertain.")
            } else {
                let existing = store.calendarItem(withIdentifier: identifier) as? EKReminder
                if let existing {
                    fields["title"] = .string(existing.title ?? "")
                    if let list = existing.calendar?.title { fields["list"] = .string(list) }
                }
                switch write(store, identifier) {
                case .changed:
                    status = .succeeded
                    fields["status"] = .string("succeeded")
                case .unchanged:
                    status = .succeeded
                    fields["status"] = .string("unchanged")
                case .failed(let code, let message):
                    status = .failed
                    fields["status"] = .string("failed")
                    fields["code"] = .string(code)
                    fields["message"] = .string(message)
                case .uncertain(let message):
                    status = .uncertain
                    stop = true
                    fields["status"] = .string("uncertain")
                    fields["code"] = .string("write_uncertain")
                    fields["message"] = .string(
                        "The write reported an error and may still have landed (\(message)). Check with reminders_get before trying again."
                    )
                }
            }
            statuses.append(status)
            switch status {
            case .succeeded: succeeded.append(.string(identifier))
            case .failed, .skipped: failed.append(.string(identifier))
            case .uncertain: uncertain.append(.string(identifier))
            }
            results.append(.object(fields))
        }

        return Value.object([
            "status": .string(RemindersQuery.batchOverallStatus(statuses)),
            "operation": .string(operation),
            "succeeded": .array(succeeded),
            "failed": .array(failed),
            "uncertain": .array(uncertain),
            "duplicatesIgnored": .array(plan.duplicatesIgnored.map { .string($0) }),
            "results": .array(results),
        ])
    }

    /// The color a `color` argument names, or nil when it is absent.
    private static func colorChange(_ value: Value?) throws -> CGColor? {
        switch value {
        case nil: return nil
        case .string(let text):
            let rgb = try RemindersQuery.parseListColor(text)
            return CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        default:
            throw RemindersInputError(code: "invalid_color", message: "color must be a string.")
        }
    }

    private static func hex(of list: EKCalendar) -> String? {
        guard let cgColor = list.cgColor,
            let srgb = cgColor.converted(
                to: CGColorSpace(name: CGColorSpace.sRGB)!,
                intent: .defaultIntent,
                options: nil
            ),
            let c = srgb.components, c.count >= 3
        else { return nil }
        return RemindersQuery.RGB(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2])).hex
    }

    /// Applies optional properties from tool arguments to a reminder.
    /// A `null` value clears the corresponding property. Everything is
    /// parsed and validated before the reminder is touched: EventKit retains
    /// unsaved mutations in its shared store, so an error halfway through
    /// would otherwise be committed by the next successful save.
    private func apply(_ arguments: [String: Value], to reminder: EKReminder) async throws {
        let newTitle: PropertyChange<String>
        switch arguments["title"] {
        case nil: newTitle = .absent
        case .some(.string(let title)): newTitle = .set(title)
        case .some:
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Title must be a string."]
            )
        }

        let newNotes = try Self.stringChange(arguments["notes"], description: "notes")
        let newURL = try Self.urlChange(arguments["url"])
        // Dates are read in local time, as the schema says. Date-only values
        // stay floating, and a timed due keeps its seconds.
        let calendar = Self.localCalendar
        let newStart = try Self.dateComponentsChange(
            arguments["start"],
            description: "start",
            calendar: calendar
        )
        let newDue = try Self.dueChange(arguments["due"], calendar: calendar)
        let newPriority = try Self.priorityChange(arguments["priority"])
        let newCompleted = try Self.boolChange(arguments["completed"], description: "completed")
        let newRecurrence: PropertyChange<EKRecurrenceRule>
        switch arguments["recurrence"] {
        case nil:
            newRecurrence = .absent
        case .object(let recurrence):
            newRecurrence = .set(try Self.recurrenceRule(from: recurrence))
        case .string(let spec):
            switch try RemindersQuery.parseRecurrence(spec) {
            case .clear: newRecurrence = .clear
            case .rule(let rule): newRecurrence = .set(Self.recurrenceRule(from: rule))
            }
        case .null:
            newRecurrence = .clear
        default:
            // inputSchema is advertised, not enforced: a recurrence value
            // of any other shape is an error, not a silently non-recurring
            // reminder.
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Recurrence must be a spec string, an object, or null."
                ]
            )
        }

        // inputSchema is advertised, not enforced: a present value with the
        // wrong shape is an error, not a silent no-op.
        var newAlarms: PropertyChange<[EKAlarm]>
        switch arguments["alarms"] {
        case .array(let alarmConfigs):
            // Parse every alarm before building any,
            // so that an invalid alarm fails
            // before a Maps search runs for another.
            let parsedAlarms = try alarmConfigs.map(Self.parsedAlarm(from:))
            var alarms: [EKAlarm] = []
            for parsedAlarm in parsedAlarms {
                alarms.append(try await Self.makeAlarm(from: parsedAlarm))
            }
            newAlarms = .set(alarms)
        case .null:
            newAlarms = .set([])
        case nil:
            newAlarms = .absent
        default:
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Alarms must be an array of alarm configurations or null."
                ]
            )
        }

        let completionDate: Date?
        switch arguments["completion_date"] {
        case nil, .null: completionDate = nil
        case .string(let text): completionDate = try RemindersQuery.parseCompletionDate(text)
        default:
            throw RemindersInputError(
                code: "invalid_completion_date",
                message: "completion_date must be YYYY-MM-DD or YYYY-MM-DD HH:MM."
            )
        }

        // The final state must be one Reminders can hold: a repeating
        // reminder keeps its due date, and a relative alarm counts back from
        // one. Checked before the reminder is touched.
        let finalDue: DateComponents?
        switch newDue {
        case .set(let components): finalDue = components
        case .clear: finalDue = nil
        case .absent: finalDue = reminder.dueDateComponents
        }
        let finalHasRecurrence: Bool
        switch newRecurrence {
        case .set: finalHasRecurrence = true
        case .clear: finalHasRecurrence = false
        case .absent: finalHasRecurrence = !(reminder.recurrenceRules ?? []).isEmpty
        }
        if finalHasRecurrence, finalDue == nil {
            throw RemindersInputError(
                code: "repeating_reminder_requires_due_date",
                message: "A repeating reminder needs a due date. Nothing was changed."
            )
        }
        if case .set(let alarms) = newAlarms, finalDue == nil,
            alarms.contains(where: Self.isRelative)
        {
            throw RemindersInputError(
                code: "relative_alarm_requires_due_date",
                message:
                    "A relative alarm counts back from the due date, so the reminder needs one. Use an absolute alarm or set a due date."
            )
        }
        if case .absent = newAlarms, finalDue == nil, case .clear = newDue {
            // Clearing the due date leaves no anchor for relative alarms.
            newAlarms = .set((reminder.alarms ?? []).filter { !Self.isRelative($0) })
        }
        if completionDate != nil {
            let willBeCompleted: Bool
            if case .set(let completed) = newCompleted {
                willBeCompleted = completed
            } else {
                willBeCompleted = reminder.isCompleted
            }
            guard willBeCompleted else {
                throw RemindersInputError(
                    code: "completion_date_requires_completed",
                    message: "completion_date applies to a completed reminder."
                )
            }
            guard !finalHasRecurrence else {
                throw RemindersInputError(
                    code: "completion_date_not_allowed_for_repeating",
                    message:
                        "A repeating reminder cannot take a completion date; completing it advances the series."
                )
            }
        }

        if case .set(let title) = newTitle { reminder.title = title }

        switch newNotes {
        case .set(let notes): reminder.notes = notes
        case .clear: reminder.notes = nil
        case .absent: break
        }

        switch newURL {
        case .set(let url): reminder.url = url
        case .clear: reminder.url = nil
        case .absent: break
        }

        switch newStart {
        case .set(let components): reminder.startDateComponents = components
        case .clear: reminder.startDateComponents = nil
        case .absent: break
        }

        switch newDue {
        case .set(let components): reminder.dueDateComponents = components
        case .clear: reminder.dueDateComponents = nil
        case .absent: break
        }

        if case .set(let priority) = newPriority {
            reminder.priority = priority
        }

        if case .set(let alarms) = newAlarms {
            reminder.alarms = alarms
        }

        switch newRecurrence {
        case .set(let rule): reminder.recurrenceRules = [rule]
        case .clear: reminder.recurrenceRules = nil
        case .absent: break
        }

        if case .set(let completed) = newCompleted {
            reminder.isCompleted = completed
        }
        if let completionDate {
            reminder.completionDate = completionDate
        }
    }

    /// An alarm anchored to the due date rather than a time or place.
    private static func isRelative(_ alarm: EKAlarm) -> Bool {
        alarm.absoluteDate == nil && alarm.structuredLocation == nil
    }

    /// The calendar new dates are read in: Gregorian in the Mac's time
    /// zone, as the schema says. Reading them in a reminder's stored zone
    /// would move "09:00" to wherever the reminder was saved.
    private static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private static func dueChange(
        _ value: Value?,
        calendar: Calendar
    ) throws -> PropertyChange<DateComponents> {
        switch value {
        case nil: return .absent
        case .null: return .clear
        case .string(let text):
            return .set(try RemindersQuery.parseDue(text, calendar: calendar).components)
        default:
            throw RemindersInputError(
                code: "invalid_due_date",
                message: "Due must be a date string or null."
            )
        }
    }

    /// Builds an EventKit rule from a parsed recurrence string.
    private static func recurrenceRule(from spec: RemindersQuery.RecurrenceSpec) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency
        switch spec.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        }
        let days = spec.weekdays.compactMap { day -> EKRecurrenceDayOfWeek? in
            guard let weekday = EKWeekday(rawValue: day.weekday) else { return nil }
            return EKRecurrenceDayOfWeek(weekday, weekNumber: day.ordinal)
        }
        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: spec.interval,
            daysOfTheWeek: days.isEmpty ? nil : days,
            daysOfTheMonth: spec.monthDays.isEmpty ? nil : spec.monthDays.map { NSNumber(value: $0) },
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: nil
        )
    }

    /// A property as the update tools see it: untouched, changed, or cleared.
    private enum PropertyChange<Value> {
        case absent
        case set(Value)
        case clear
    }

    /// inputSchema is advertised, not enforced and the schemas declare
    /// `additionalProperties: false`, so an unexpected key is an error rather
    /// than an ignored one that silently narrows the requested change.
    private static func rejectUnknownKeys(
        _ arguments: [String: Value],
        allowed: Set<String>
    ) throws {
        if let unknown = arguments.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Unknown property \"\(unknown)\"."
                ]
            )
        }
    }

    private static func stringChange(
        _ value: Value?,
        description: String
    ) throws -> PropertyChange<String> {
        switch value {
        case nil: return .absent
        case .string(let string): return .set(string)
        case .null: return .clear
        default:
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(description.capitalized) must be a string or null."
                ]
            )
        }
    }

    private static func urlChange(_ value: Value?) throws -> PropertyChange<URL> {
        switch value {
        case nil: return .absent
        case .string(let urlString):
            // .uri is absolute by definition; URL(string:) alone would
            // accept relative references like an empty string.
            guard let url = URL(string: urlString), url.scheme != nil else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "URL \"\(urlString)\" must be absolute (carry a scheme)."
                    ]
                )
            }
            return .set(url)
        case .null: return .clear
        default:
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "URL must be a string or null."]
            )
        }
    }

    private static func dateComponentsChange(
        _ value: Value?,
        description: String,
        calendar: Calendar
    ) throws -> PropertyChange<DateComponents> {
        switch value {
        case nil: return .absent
        case .string(let dateString):
            return .set(
                try Self.dateComponents(
                    fromDateString: dateString,
                    description: description,
                    calendar: calendar
                )
            )
        case .null: return .clear
        default:
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(description.capitalized) must be an ISO 8601 date string or null."
                ]
            )
        }
    }

    /// A priority by name (high, medium, low, none) or Apple number (0 to 9).
    /// A typo is an error, not a silently cleared priority.
    private static func priorityChange(_ value: Value?) throws -> PropertyChange<Int> {
        switch value {
        case nil: return .absent
        case .string(let string):
            guard let priority = RemindersQuery.priorityNumber(name: string) else {
                throw RemindersInputError(
                    code: "invalid_priority",
                    message:
                        "Priority must be high, medium, low, none, or an Apple number from 0 to 9."
                )
            }
            return .set(priority)
        case .int(let number):
            guard let priority = RemindersQuery.priorityNumber(apple: number) else {
                throw RemindersInputError(
                    code: "invalid_priority",
                    message: "Priority numbers run 0 to 9."
                )
            }
            return .set(priority)
        default:
            throw RemindersInputError(
                code: "invalid_priority",
                message: "Priority must be a name or an Apple number from 0 to 9."
            )
        }
    }

    private static func boolChange(
        _ value: Value?,
        description: String
    ) throws -> PropertyChange<Bool> {
        switch value {
        case nil: return .absent
        case .bool(let bool): return .set(bool)
        default:
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(description.capitalized) must be a boolean."
                ]
            )
        }
    }

    /// Encodes a reminder as a PlanAction, layering on recurrence and completion
    /// details that the schema.org representation does not carry.
    ///
    /// A list item is encoded as an array element, without the `@context` of a root value,
    /// so that the list can give the context once.
    private func payload(for reminder: EKReminder, isListItem: Bool = false) throws -> Value {
        let encoder = JSONEncoder()
        encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] = TimeZone.current
        encoder.userInfo[JSONLD.omitsNestedTypesKey] = true
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let base =
            isListItem
            ? try JSONDecoder().decode([Value].self, from: encoder.encode([PlanAction(reminder)]))[0]
            : try JSONDecoder().decode(Value.self, from: encoder.encode(PlanAction(reminder)))
        guard case .object(var fields) = base else { return base }

        if let completionDate = reminder.completionDate {
            fields["completedAt"] = .string(Self.iso8601String(completionDate))
        }

        if let recurrenceRule = reminder.recurrenceRules?.first {
            fields["recurrence"] = Self.value(for: recurrenceRule)
        }

        return .object(fields)
    }

    /// Builds a recurrence rule from a recurrence configuration object.
    private static func recurrenceRule(from config: [String: Value]) throws -> EKRecurrenceRule {
        // inputSchema is advertised, not enforced, and the object declares
        // `additionalProperties: false`: a typo like `interva` must not
        // parse as its absent sibling and silently build a different rule.
        let recurrenceKeys: Set<String> = [
            "frequency", "interval", "daysOfTheWeek", "daysOfTheMonth",
            "monthsOfTheYear", "weeksOfTheYear", "daysOfTheYear", "setPositions",
            "end",
        ]
        if let unknownKey = config.keys.filter({ !recurrenceKeys.contains($0) }).sorted().first {
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Unknown recurrence property \"\(unknownKey)\"."
                ]
            )
        }

        guard let frequencyValue = config["frequency"] else {
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Recurrence frequency is required"]
            )
        }
        guard case .string(let frequencyString) = frequencyValue else {
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Recurrence frequency must be a string."]
            )
        }
        let frequency: EKRecurrenceFrequency
        switch frequencyString {
        case "daily": frequency = .daily
        case "weekly": frequency = .weekly
        case "monthly": frequency = .monthly
        case "yearly": frequency = .yearly
        default:
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unknown recurrence frequency \"\(frequencyString)\". Expected daily, weekly, monthly, or yearly."
                ]
            )
        }

        var interval = 1
        if let intervalValue = config["interval"] {
            interval = try Self.integerValue(intervalValue, description: "Recurrence interval")
            guard interval >= 1 else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Recurrence interval must be at least 1."
                    ]
                )
            }
        }

        var daysOfTheWeek: [EKRecurrenceDayOfWeek]?
        if let dayValues = try Self.arrayValue(config["daysOfTheWeek"], named: "daysOfTheWeek") {
            daysOfTheWeek = try dayValues.map { dayValue in
                guard case .string(let dayName) = dayValue,
                    let day = EKRecurrenceDayOfWeek.day(named: dayName)
                else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unknown day of the week. Expected sunday through saturday, optionally prefixed with first through fifth, last, or second-to-last through fifth-to-last."
                        ]
                    )
                }
                return day
            }
        }

        let daysOfTheMonth = try Self.integers(
            config["daysOfTheMonth"],
            named: "days of the month",
            in: -31 ... 31
        )
        var monthsOfTheYear: [NSNumber]? = nil
        if let monthValues = try Self.arrayValue(
            config["monthsOfTheYear"],
            named: "monthsOfTheYear"
        ) {
            monthsOfTheYear = try monthValues.map { monthValue in
                guard case .string(let monthName) = monthValue,
                    let index = monthNames.firstIndex(of: monthName.lowercased())
                else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unknown month. Expected january through december."
                        ]
                    )
                }
                return NSNumber(value: index + 1)
            }
        }
        let weeksOfTheYear = try Self.integers(
            config["weeksOfTheYear"],
            named: "weeks of the year",
            in: -53 ... 53
        )
        let daysOfTheYear = try Self.integers(
            config["daysOfTheYear"],
            named: "days of the year",
            in: -366 ... 366
        )
        let setPositions = try Self.integers(
            config["setPositions"],
            named: "set positions",
            in: -366 ... 366
        )

        var end: EKRecurrenceEnd?
        if let endValue = config["end"] {
            guard case .object(let endConfig) = endValue else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Recurrence end must be an object."]
                )
            }
            // The end object also declares additionalProperties: false.
            if let unknownEndKey = endConfig.keys
                .filter({ !["date", "count"].contains($0) })
                .sorted()
                .first
            {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Unknown recurrence end property \"\(unknownEndKey)\"."
                    ]
                )
            }
            let hasDate = endConfig["date"] != nil
            let hasCount = endConfig["count"] != nil
            guard hasDate != hasCount else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Recurrence end requires either date or count; passing both is ambiguous."
                    ]
                )
            }
            if hasDate {
                guard case .string(let dateString)? = endConfig["date"],
                    let parsedDate = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: dateString
                    )
                else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Recurrence end date is not a valid ISO 8601 date."
                        ]
                    )
                }
                // EKRecurrenceEnd's date is the last instant a recurrence may
                // start on (inclusive, like RFC 5545 UNTIL), so a date-only
                // value covers that whole day instead of stopping at midnight.
                let endDate: Date
                if parsedDate.isDateOnly {
                    endDate =
                        Calendar.current.date(
                            byAdding: DateComponents(day: 1, second: -1),
                            to: Calendar.current.startOfDay(for: parsedDate.date)
                        ) ?? parsedDate.date
                } else {
                    endDate = parsedDate.date
                }
                end = EKRecurrenceEnd(end: endDate)
            } else {
                let count = try Self.integerValue(
                    endConfig["count"] ?? .null,
                    description: "Recurrence end count"
                )
                guard count >= 1 else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Recurrence end count must be an integer of at least 1."
                        ]
                    )
                }
                end = EKRecurrenceEnd(occurrenceCount: count)
            }
        }

        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: interval,
            daysOfTheWeek: daysOfTheWeek,
            daysOfTheMonth: daysOfTheMonth,
            monthsOfTheYear: monthsOfTheYear,
            weeksOfTheYear: weeksOfTheYear,
            daysOfTheYear: daysOfTheYear,
            setPositions: setPositions,
            end: end
        )
    }

    /// The integer a JSON Schema "integer" accepts: an Int, or a double with
    /// a zero fraction (2.0). Throws for anything else.
    private static func integerValue(_ value: Value, description: String) throws -> Int {
        switch value {
        case .int(let int):
            return int
        case .double(let double) where double.rounded() == double:
            // Int(exactly:) instead of Int(_: an out-of-range integral
            // double is a recoverable error, not a trap.
            guard let int = Int(exactly: double) else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: "\(description) \(double) is out of range."
                    ]
                )
            }
            return int
        default:
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(description) must be an integer."]
            )
        }
    }

    /// The nonzero integers of an array parameter, rejecting anything else.
    /// EventKit silently ignores out-of-range recurrence values, so the
    /// bounds the schema advertises are enforced here too.
    private static func integers(
        _ value: Value?,
        named description: String,
        in bounds: ClosedRange<Int>
    ) throws -> [NSNumber]? {
        let values = try Self.arrayValue(value, named: description)
        guard let values else { return nil }
        return try values.map { item in
            let number = try Self.integerValue(item, description: "Recurrence \(description)")
            guard number != 0, bounds.contains(number) else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Recurrence \(description) takes nonzero integers from \(bounds.lowerBound) to \(bounds.upperBound); \(number) is not allowed."
                    ]
                )
            }
            return NSNumber(value: number)
        }
    }

    /// The array a present recurrence parameter must carry: nil when the
    /// parameter is absent, the values when it is an array, an error when it
    /// is anything else.
    private static func arrayValue(_ value: Value?, named description: String) throws -> [Value]? {
        guard let value else { return nil }
        guard case .array(let values) = value else {
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Recurrence \(description) must be an array."
                ]
            )
        }
        return values
    }

    /// Maps a recurrence rule onto the shape accepted by the recurrence parameter.
    /// The result round-trips back into a reminder unchanged
    /// when the parameter can represent every value in the rule.
    /// A value outside the parameter's vocabulary,
    /// such as a month outside 1-12 or a weekday ordinal beyond ±5,
    /// comes out as "unknown", which `recurrenceRule(from:)` rejects.
    private static func value(for rule: EKRecurrenceRule) -> Value {
        var fields: [String: Value] = [
            "frequency": .string(rule.frequency.stringValue),
            "interval": .int(rule.interval),
        ]

        if let end = rule.recurrenceEnd {
            if let endDate = end.endDate {
                fields["end"] = .object(["date": .string(iso8601String(endDate))])
            } else if end.occurrenceCount > 0 {
                fields["end"] = .object(["count": .int(end.occurrenceCount)])
            }
        }

        if let daysOfTheWeek = rule.daysOfTheWeek, !daysOfTheWeek.isEmpty {
            fields["daysOfTheWeek"] = .array(
                daysOfTheWeek.map { .string($0.namedValue) }
            )
        }
        if let daysOfTheMonth = rule.daysOfTheMonth, !daysOfTheMonth.isEmpty {
            fields["daysOfTheMonth"] = .array(daysOfTheMonth.map { .int($0.intValue) })
        }
        if let monthsOfTheYear = rule.monthsOfTheYear, !monthsOfTheYear.isEmpty {
            fields["monthsOfTheYear"] = .array(
                monthsOfTheYear.map { month in
                    // Rules synced from foreign calendars can carry values
                    // outside 1-12; degrade instead of trapping the service.
                    guard (1 ... 12).contains(month.intValue) else { return .string("unknown") }
                    return .string(monthNames[month.intValue - 1])
                }
            )
        }
        if let weeksOfTheYear = rule.weeksOfTheYear, !weeksOfTheYear.isEmpty {
            fields["weeksOfTheYear"] = .array(weeksOfTheYear.map { .int($0.intValue) })
        }
        if let daysOfTheYear = rule.daysOfTheYear, !daysOfTheYear.isEmpty {
            fields["daysOfTheYear"] = .array(daysOfTheYear.map { .int($0.intValue) })
        }
        if let setPositions = rule.setPositions, !setPositions.isEmpty {
            fields["setPositions"] = .array(setPositions.map { .int($0.intValue) })
        }

        return .object(fields)
    }

    /// A bare ISO 8601 string, as the reminders tools accept: the ontology
    /// encoder writes a JSON-LD wrapper for root-level DateTime values.
    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    /// Parses an ISO 8601 date string into due/start date components,
    /// normalizing date-only values to midnight in `calendar`.
    private static func dateComponents(
        fromDateString dateString: String,
        description: String,
        calendar: Calendar
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

        let date = calendar.normalizedStartDate(
            from: parsedDate.date,
            isDateOnly: parsedDate.isDateOnly
        )
        // Date-only values become all-day reminders: leave out the time
        // components, or EventKit stores them as timed reminders at 12:00 AM.
        let units: Set<Calendar.Component> = parsedDate.isDateOnly
            ? [.year, .month, .day]
            : [.year, .month, .day, .hour, .minute, .second]
        var components = calendar.dateComponents(units, from: date)
        components.calendar = calendar
        // A nil time zone keeps a date-only value floating, per EKReminder.h.
        components.timeZone = parsedDate.isDateOnly ? nil : calendar.timeZone
        return components
    }

    /// An alarm configuration that has passed validation.
    /// Parsing and building are separate steps
    /// so that every check runs before a proximity alarm's location
    /// goes to Maps.
    private struct ParsedAlarm {
        enum Trigger {
            case relative(minutes: Int)
            case absolute(Date)
            case proximity(Place, EKAlarmProximity, radius: Double)
        }

        enum Place {
            case query(String)
            case coordinate(title: String, CLLocationCoordinate2D)
            /// A street address resolved with the strict geocoder.
            case address(String, title: String?)
        }

        var trigger: Trigger
        var soundName: String?
        var emailAddress: String?
    }

    /// Parses and validates an alarm configuration object without I/O.
    /// Bare integers are minutes before the due date,
    /// the shape accepted before alarms grew structured configurations.
    private static func parsedAlarm(from value: Value) throws -> ParsedAlarm {
        // JSON Schema counts 30.0 as a valid integer for the bare form too.
        switch value {
        case .int(let minutes):
            return ParsedAlarm(trigger: .relative(minutes: minutes))
        case .double(let value) where value.rounded() == value:
            // Int(exactly:) instead of Int(_: an out-of-range integral
            // double is a recoverable error, not a trap.
            guard let minutes = Int(exactly: value) else {
                throw NSError(
                    domain: "RemindersError",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Alarm minutes \(value) is out of range."
                    ]
                )
            }
            return ParsedAlarm(trigger: .relative(minutes: minutes))
        case .string(let text):
            switch try RemindersQuery.parseAlarm(text) {
            case .relative(let minutes):
                return ParsedAlarm(trigger: .relative(minutes: minutes))
            case .absolute(let date):
                return ParsedAlarm(trigger: .absolute(date))
            case .clear:
                throw RemindersInputError(
                    code: "invalid_alarm",
                    message: "To remove alarms, pass null for alarms instead of an alarm string."
                )
            }
        default: break
        }
        guard case .object(let config) = value else {
            throw NSError(
                domain: "RemindersError",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Invalid alarm configuration. Pass a number of minutes or an object with type relative, absolute, or proximity."
                ]
            )
        }

        // inputSchema is advertised, not enforced: a present `type` of the
        // wrong shape is the caller's choice failing, not the relative
        // default, and the advertised `additionalProperties: false` means
        // unknown keys are errors instead of silently ignored fields.
        let alarmType: String
        switch config["type"] {
        case nil: alarmType = "relative"
        case .string(let type): alarmType = type
        default:
            throw NSError(
                domain: "RemindersError",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Alarm type must be a string; expected relative, absolute, or proximity."
                ]
            )
        }

        let allowedKeys: Set<String>
        switch alarmType {
        case "relative":
            allowedKeys = ["type", "minutes", "sound", "emailAddress"]
        case "absolute":
            allowedKeys = ["type", "datetime", "sound", "emailAddress"]
        case "proximity":
            allowedKeys = [
                "type", "proximity", "location", "address", "locationTitle", "latitude",
                "longitude", "radius", "sound", "emailAddress",
            ]
        default:
            throw NSError(
                domain: "RemindersError",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unknown alarm type \(alarmType). Expected relative, absolute, or proximity."
                ]
            )
        }
        if let unknownKey = config.keys.filter({ !allowedKeys.contains($0) }).sorted().first {
            throw NSError(
                domain: "RemindersError",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unknown \(alarmType) alarm property \"\(unknownKey)\"."
                ]
            )
        }

        let trigger: ParsedAlarm.Trigger
        switch alarmType {
        case "relative":
            // JSON Schema counts 30.0 as a valid integer, so bridge an
            // integral double like number() does for radius and coordinates.
            let minutes: Int
            switch config["minutes"] {
            case .some(.int(let value)): minutes = value
            case .some(.double(let value)) where value.rounded() == value:
                guard let asInt = Int(exactly: value) else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Alarm minutes \(value) is out of range."
                        ]
                    )
                }
                minutes = asInt
            default:
                throw NSError(
                    domain: "RemindersError",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Relative alarm requires integer minutes."
                    ]
                )
            }
            trigger = .relative(minutes: minutes)

        case "absolute":
            guard case .string(let datetimeString) = config["datetime"] else {
                throw NSError(
                    domain: "RemindersError",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Absolute alarm requires an ISO 8601 datetime string."
                    ]
                )
            }
            // Date-only values mean local midnight, like every other date
            // parameter of these tools (due, start) and like events_create.
            guard
                let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: datetimeString
                )
            else {
                throw NSError(
                    domain: "RemindersError",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Absolute alarm datetime is not a valid ISO 8601 datetime."
                    ]
                )
            }
            trigger = .absolute(
                Calendar.current.normalizedStartDate(
                    from: parsed.date,
                    isDateOnly: parsed.isDateOnly
                )
            )

        case "proximity":
            let place: ParsedAlarm.Place
            if let addressValue = config["address"] {
                guard case .string(let address) = addressValue, !address.isEmpty,
                    config["location"] == nil, config["latitude"] == nil,
                    config["longitude"] == nil
                else {
                    throw RemindersInputError(
                        code: "location_address_conflict",
                        message:
                            "A proximity alarm takes address alone (with an optional locationTitle), not together with location or coordinates."
                    )
                }
                var title: String?
                switch config["locationTitle"] {
                case nil: break
                case .string(let text): title = text
                default:
                    throw RemindersInputError(
                        code: "invalid_location_title",
                        message: "locationTitle must be a string."
                    )
                }
                let radius = try RemindersQuery.validatedGeofenceRadius(
                    Self.number(config["radius"])
                )
                if config["radius"] != nil, Self.number(config["radius"]) == nil {
                    throw RemindersInputError(
                        code: "invalid_location_radius",
                        message: "Proximity alarm radius must be a number of meters."
                    )
                }
                trigger = .proximity(
                    .address(address, title: title),
                    try Self.proximity(config["proximity"]),
                    radius: radius
                )
                return try Self.finishAlarm(ParsedAlarm(trigger: trigger), config: config)
            }
            switch config["location"] {
            case .some(.string(let query)):
                // The two advertised object shapes are alternatives: a
                // query or explicit coordinates, never a mix.
                if config["locationTitle"] != nil
                    || config["latitude"] != nil || config["longitude"] != nil
                {
                    throw NSError(
                        domain: "RemindersError",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Proximity alarm takes either location or locationTitle with coordinates, not both."
                        ]
                    )
                }
                // The query is only recorded here;
                // makeAlarm(from:) runs its Maps search.
                place = .query(query)
            case nil:
                guard case .string(let locationTitle) = config["locationTitle"] else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Proximity alarm requires a location query or a locationTitle with coordinates."
                        ]
                    )
                }
                guard
                    let latitude = Self.number(config["latitude"]),
                    let longitude = Self.number(config["longitude"])
                else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Proximity alarm requires numeric latitude and longitude alongside locationTitle."
                        ]
                    )
                }
                guard (-90.0 ... 90.0).contains(latitude) else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Latitude \(latitude) is outside the geographic range of -90 to 90 degrees."
                        ]
                    )
                }
                guard (-180.0 ... 180.0).contains(longitude) else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Longitude \(longitude) is outside the geographic range of -180 to 180 degrees."
                        ]
                    )
                }
                place = .coordinate(
                    title: locationTitle,
                    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                )
            default:
                throw NSError(
                    domain: "RemindersError",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Proximity alarm location must be a string."
                    ]
                )
            }
            // EventKit reads a radius of 0 as a request for the system default,
            // so an absent radius stays 0.
            let radius: Double
            switch config["radius"] {
            case nil: radius = 0
            case .int(let value): radius = Double(value)
            case .double(let value): radius = value
            default:
                throw NSError(
                    domain: "RemindersError",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Proximity alarm radius must be a number of meters."
                    ]
                )
            }
            guard radius >= 0 else {
                throw NSError(
                    domain: "RemindersError",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Radius \(radius) is negative; a geofence radius is zero or more meters."
                    ]
                )
            }

            let alarmProximity = try Self.proximity(config["proximity"])
            trigger = .proximity(place, alarmProximity, radius: radius)

        default:
            throw NSError(
                domain: "RemindersError",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unknown alarm type \(alarmType). Expected relative, absolute, or proximity."
                ]
            )
        }

        return try Self.finishAlarm(ParsedAlarm(trigger: trigger), config: config)
    }

    /// An unsupported proximity string must not fold into .enter;
    /// the geofence would trigger on the wrong side.
    private static func proximity(_ value: Value?) throws -> EKAlarmProximity {
        switch value {
        case nil: return .enter
        case .string("enter"), .string("arriving"): return .enter
        case .string("leave"), .string("leaving"): return .leave
        case .string(let proximity):
            throw NSError(
                domain: "RemindersError",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unknown proximity \"\(proximity)\". Expected enter, leave, arriving, or leaving."
                ]
            )
        default:
            throw NSError(
                domain: "RemindersError",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Proximity alarm proximity must be a string: enter or leave."
                ]
            )
        }
    }

    /// Applies the sound and email options every alarm type shares.
    private static func finishAlarm(
        _ alarm: ParsedAlarm,
        config: [String: Value]
    ) throws -> ParsedAlarm {
        var parsedAlarm = alarm

        switch config["sound"] {
        case nil: break
        case .string(let soundName):
            guard Sound(rawValue: soundName) != nil else {
                throw NSError(
                    domain: "RemindersError",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Unknown alarm sound \"\(soundName)\"."
                    ]
                )
            }
            parsedAlarm.soundName = soundName
        default:
            throw NSError(
                domain: "RemindersError",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Alarm sound must be a string."
                ]
            )
        }

        switch config["emailAddress"] {
        case nil: break
        case .string(let email) where !email.isEmpty:
            parsedAlarm.emailAddress = email
        case .string:
            throw NSError(
                domain: "RemindersError",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Alarm emailAddress cannot be empty; omit it to use the default sound alarm."
                ]
            )
        default:
            throw NSError(
                domain: "RemindersError",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Alarm emailAddress must be a string."
                ]
            )
        }

        return parsedAlarm
    }

    /// Builds an alarm from a parsed configuration.
    /// A proximity alarm with a location query
    /// resolves it here with a Maps search.
    private static func makeAlarm(from parsedAlarm: ParsedAlarm) async throws -> EKAlarm {
        let alarm: EKAlarm
        switch parsedAlarm.trigger {
        case .relative(let minutes):
            alarm = EKAlarm(relativeOffset: -Double(minutes) * 60)

        case .absolute(let date):
            alarm = EKAlarm(absoluteDate: date)

        case .proximity(let place, let proximity, let radius):
            let title: String
            let coordinate: CLLocationCoordinate2D
            switch place {
            case .query(let query):
                let mapItem = try await Self.searchLocation(query)
                title = mapItem.name ?? query
                coordinate = mapItem.placemark.coordinate
            case .coordinate(let locationTitle, let locationCoordinate):
                title = locationTitle
                coordinate = locationCoordinate
            case .address(let address, let customTitle):
                let match = try await Self.resolveAddress(address)
                title = customTitle ?? match.name ?? match.summary
                coordinate = CLLocationCoordinate2D(
                    latitude: match.latitude,
                    longitude: match.longitude
                )
            }
            let structuredLocation = EKStructuredLocation(title: title)
            structuredLocation.geoLocation = CLLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            structuredLocation.radius = radius

            alarm = EKAlarm()
            alarm.proximity = proximity
            alarm.structuredLocation = structuredLocation
        }

        if let soundName = parsedAlarm.soundName {
            alarm.soundName = soundName
        }

        if let emailAddress = parsedAlarm.emailAddress {
            alarm.emailAddress = emailAddress
        }

        return alarm
    }

    /// Geocodes a street address and accepts the result only when it is
    /// unambiguous, precise, and tied to what was typed.
    static func resolveAddress(_ address: String) async throws -> RemindersQuery.GeocodeCandidate {
        let candidates = try await geocode(address)
        do {
            return try RemindersQuery.judgeAddress(query: address, candidates: candidates)
        } catch let rejection as RemindersQuery.GeocodeRejection {
            var message = "\(rejection.message) (\(rejection.code))"
            if rejection.candidates.count > 1 {
                message +=
                    " Candidates: "
                    + rejection.candidates.map { "\($0.summary) [\($0.latitude), \($0.longitude)]" }
                    .joined(separator: "; ")
            }
            throw RemindersInputError(code: rejection.code, message: message)
        }
    }

    /// Apple's geocoder, with a 10-second limit.
    private static func geocode(
        _ address: String
    ) async throws -> [RemindersQuery.GeocodeCandidate] {
        let geocoder = CLGeocoder()
        return try await withThrowingTaskGroup(of: [RemindersQuery.GeocodeCandidate].self) { group in
            group.addTask {
                do {
                    let placemarks = try await geocoder.geocodeAddressString(address)
                    return placemarks.compactMap { placemark in
                        guard let location = placemark.location else { return nil }
                        return RemindersQuery.GeocodeCandidate(
                            name: placemark.name,
                            thoroughfare: placemark.thoroughfare,
                            subThoroughfare: placemark.subThoroughfare,
                            locality: placemark.locality,
                            postalCode: placemark.postalCode,
                            administrativeArea: placemark.administrativeArea,
                            country: placemark.country,
                            latitude: location.coordinate.latitude,
                            longitude: location.coordinate.longitude,
                            radiusMeters: (placemark.region as? CLCircularRegion)?.radius
                        )
                    }
                } catch let error as CLError {
                    switch error.code {
                    case .geocodeFoundNoResult: return []
                    case .denied:
                        throw RemindersInputError(
                            code: "location_lookup_denied",
                            message: "The geocoder refused the lookup (location_lookup_denied)."
                        )
                    default:
                        throw RemindersInputError(
                            code: "location_lookup_failed",
                            message:
                                "The geocoder failed: \(error.localizedDescription) (location_lookup_failed)."
                        )
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                geocoder.cancelGeocode()
                throw RemindersInputError(
                    code: "location_lookup_timeout",
                    message: "The geocoder did not answer within 10 seconds (location_lookup_timeout)."
                )
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { return [] }
            return result
        }
    }

    /// Resolves a free-text location query to a place, the way the Maps
    /// service does, so callers can name a place instead of knowing its
    /// coordinates.
    private static func searchLocation(_ query: String) async throws -> MKMapItem {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        return try await withCheckedThrowingContinuation { continuation in
            MKLocalSearch(request: request).start { response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let mapItem = response?.mapItems.first else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "RemindersError",
                            code: 4,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "No location found for \"\(query)\""
                            ]
                        )
                    )
                    return
                }
                continuation.resume(returning: mapItem)
            }
        }
    }

    /// JSON numbers arrive as `.int` or `.double` depending on whether they
    /// carry a fractional part, so both spell a number here.
    private static func number(_ value: Value?) -> Double? {
        switch value {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    /// Resolves a reminder list by identifier, falling back to a case-insensitive name match.
    private func list(_ arguments: [String: Value]) throws -> EKCalendar {
        let lists = eventStore.calendars(for: .reminder)

        // inputSchema is advertised, not enforced: a present identifier of the
        // wrong shape is the preferred selector failing, not permission to
        // fall through to the name.
        switch arguments["identifier"] {
        case .string(let identifier) where !identifier.isEmpty:
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
        case .string:
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Reminder list identifier cannot be empty."
                ]
            )
        case nil:
            break
        default:
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Reminder list identifier must be a string."
                ]
            )
        }

        switch arguments["name"] {
        case .string(let name) where !name.isEmpty:
            return try list(named: name)
        case .string:
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Reminder list name cannot be empty."
                ]
            )
        case nil:
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Reminder list identifier or name is required"
                ]
            )
        default:
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Reminder list name must be a string."
                ]
            )
        }
    }

    /// Resolves a reminder list by identifier or name. Case-insensitive on
    /// names, but ambiguous names are an error rather than a guess, because
    /// several lists can share a name across sources; an identifier from
    /// reminders_lists names exactly one.
    private func list(named name: String) throws -> EKCalendar {
        guard let matchingList = try listIfPresent(named: name) else {
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

    /// Resolves a reminder list by identifier or name, or nil when nothing
    /// matches, so callers that fall back to a default can keep doing so.
    /// Ambiguous names still throw; the identifier resolves them.
    private func listIfPresent(named name: String) throws -> EKCalendar? {
        // An identifier is unambiguous even where several lists share a
        // name across sources.
        if let byIdentifier = eventStore.calendars(for: .reminder)
            .first(where: { $0.calendarIdentifier == name })
        {
            return byIdentifier
        }
        let matchingLists = eventStore.calendars(for: .reminder).filter {
            $0.title.lowercased() == name.lowercased()
        }
        switch matchingLists.count {
        case 0:
            return nil
        case 1:
            return matchingLists[0]
        default:
            throw NSError(
                domain: "RemindersError",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(matchingLists.count) reminder lists are named \"\(name)\". Pass the identifier of the one you mean, as returned by reminders_lists."
                ]
            )
        }
    }
}
