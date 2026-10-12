import CoreLocation
import EventKit
import Foundation
import JSONSchema
import MapKit
import OSLog
import Ontology
import OrderedCollections

private let log = Logger.service("reminders")

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
                "Due date/time for the reminder. If timezone is omitted, local time is assumed. Date-only uses local midnight. Pass null to clear.",
            format: .dateTime
        ),
        .null,
    ]),
    "priority": .string(
        default: .string(EKReminderPriority.none.stringValue),
        enum: EKReminderPriority.allCases.map { .string($0.stringValue) }
    ),
    "alarms": .anyOf([
        .array(
            description: "Alarm configurations for the reminder. Pass null to remove all alarms.",
            items: .anyOf([
                // Relative alarm in minutes, as accepted before alarms took
                // structured configurations (kept for compatibility)
                .integer(description: "Minutes before the due date"),
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
                                enum: [.string("enter"), .string("leave")]
                            ),
                            "location": .string(
                                description:
                                    "Place name or address to trigger on, resolved with Maps"
                            ),
                            "radius": .number(
                                description: "Radius in meters",
                                default: .int(200),
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
                                enum: [.string("enter"), .string("leave")]
                            ),
                            "locationTitle": .string(),
                            "latitude": .number(
                                minimum: -90,
                                maximum: 90
                            ),
                            "longitude": .number(
                                minimum: -180,
                                maximum: 180
                            ),
                            "radius": .number(
                                description: "Radius in meters",
                                default: .int(200),
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
                .merging(reminderProperties, uniquingKeysWith: { _, new in new })
                .merging(
                    [
                        // The shared entries carry create-specific behavior;
                        // for an update, omission means "leave unchanged", so
                        // advertising create's priority default would have
                        // clients wipe priorities they never meant to touch,
                        // and create's unmatched-list fallback is an error.
                        "priority": .string(
                            description: "Priority; omit to leave unchanged",
                            enum: EKReminderPriority.allCases.map { .string($0.stringValue) }
                        ),
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
                        )
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
        let newStart = try Self.dateComponentsChange(arguments["start"], description: "start")
        let newDue = try Self.dateComponentsChange(arguments["due"], description: "due")
        let newPriority = try Self.priorityChange(arguments["priority"])
        let newCompleted = try Self.boolChange(arguments["completed"], description: "completed")

        // inputSchema is advertised, not enforced: a present value with the
        // wrong shape is an error, not a silent no-op.
        let newAlarms: PropertyChange<[EKAlarm]>
        switch arguments["alarms"] {
        case .array(let alarmConfigs):
            var alarms: [EKAlarm] = []
            for alarmConfig in alarmConfigs {
                alarms.append(try await Self.alarm(from: alarmConfig))
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
            reminder.priority = Int(priority.rawValue)
        }

        if case .set(let alarms) = newAlarms {
            reminder.alarms = alarms
        }

        if case .set(let completed) = newCompleted {
            reminder.isCompleted = completed
        }
    }

    /// A property as the update tools see it: untouched, changed, or cleared.
    private enum PropertyChange<Value> {
        case absent
        case set(Value)
        case clear
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
            guard let url = URL(string: urlString) else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid URL \"\(urlString)\""]
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
        description: String
    ) throws -> PropertyChange<DateComponents> {
        switch value {
        case nil: return .absent
        case .string(let dateString):
            return .set(
                try Self.dateComponents(fromDateString: dateString, description: description)
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

    /// The lenient `from(string:)` folds unknowns into `.none`; an update
    /// needs a typo to report an error rather than silently clear priority.
    private static func priorityChange(_ value: Value?) throws -> PropertyChange<EKReminderPriority> {
        switch value {
        case nil: return .absent
        case .string(let string):
            guard let priority = EKReminderPriority.from(exactString: string) else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Priority must be one of \(EKReminderPriority.allCases.map(\.stringValue).joined(separator: ", "))."
                    ]
                )
            }
            return .set(priority)
        default:
            throw NSError(
                domain: "RemindersError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Priority must be a string."]
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

    /// Builds an alarm from an alarm configuration object. Bare integers are
    /// minutes before the due date, the shape accepted before alarms grew
    /// structured configurations.
    private static func alarm(from value: Value) async throws -> EKAlarm {
        // JSON Schema counts 30.0 as a valid integer for the bare form too.
        switch value {
        case .int(let minutes):
            return EKAlarm(relativeOffset: -Double(minutes) * 60)
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
            return EKAlarm(relativeOffset: -Double(minutes) * 60)
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

        var alarm: EKAlarm
        let alarmType = config["type"]?.stringValue ?? "relative"
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
            alarm = EKAlarm(relativeOffset: -Double(minutes) * 60)

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
            guard !ISO8601DateFormatter.isDateOnlyISO8601String(datetimeString) else {
                throw NSError(
                    domain: "RemindersError",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Absolute alarm datetime must include a time component."
                    ]
                )
            }
            guard let absoluteDate = ISO8601DateFormatter.lenientDate(fromISO8601String: datetimeString) else {
                throw NSError(
                    domain: "RemindersError",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Absolute alarm datetime is not a valid ISO 8601 datetime."
                    ]
                )
            }
            alarm = EKAlarm(absoluteDate: absoluteDate)

        case "proximity":
            let title: String
            let coordinate: CLLocationCoordinate2D
            if case .string(let query) = config["location"] {
                let mapItem = try await Self.searchLocation(query)
                title = mapItem.name ?? query
                coordinate = mapItem.placemark.coordinate
            } else {
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
                guard (-90.0...90.0).contains(latitude) else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Latitude \(latitude) is outside the geographic range of -90 to 90 degrees."
                        ]
                    )
                }
                guard (-180.0...180.0).contains(longitude) else {
                    throw NSError(
                        domain: "RemindersError",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Longitude \(longitude) is outside the geographic range of -180 to 180 degrees."
                        ]
                    )
                }
                title = locationTitle
                coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
            let structuredLocation = EKStructuredLocation(title: title)
            structuredLocation.geoLocation = CLLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            // The schema advertises a 200 m default; EKStructuredLocation
            // alone would leave a zero-radius geofence. Zero stays valid:
            // EventKit reads it as a request for the system default radius.
            let radius = Self.number(config["radius"]) ?? 200
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
            structuredLocation.radius = radius

            alarm = EKAlarm()
            alarm.proximity = config["proximity"]?.stringValue == "leave" ? .leave : .enter
            alarm.structuredLocation = structuredLocation

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

        if case .string(let soundName) = config["sound"] {
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
            alarm.soundName = soundName
        }

        if case .string(let email) = config["emailAddress"], !email.isEmpty {
            alarm.emailAddress = email
        }

        return alarm
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
            return try list(named: name)
        }

        throw NSError(
            domain: "RemindersError",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: "Reminder list identifier or name is required"
            ]
        )
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
