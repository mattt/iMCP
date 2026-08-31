import Contacts
import CoreLocation
import EventKit
import Foundation
import OSLog
import Ontology

private let log = Logger.service("reminders")

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

    /// Build a location-based proximity `EKAlarm` from a `location` argument
    /// object. Coordinates come from explicit latitude/longitude, or by
    /// resolving `address` — first as a saved place ("home"/"work"/custom
    /// label) on the user's contact card, then as a free-form address.
    private func makeLocationAlarm(from location: [String: Value]) async throws -> EKAlarm {
        var coordinate: CLLocationCoordinate2D? = nil
        var locationTitle = location["title"]?.stringValue

        if let latitude = location["latitude"]?.doubleValue,
            let longitude = location["longitude"]?.doubleValue
        {
            coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        } else if case .string(let address) = location["address"], !address.isEmpty {
            let geocoder = CLGeocoder()

            let savedAddress = try? await ContactsService.shared.savedPostalAddress(
                named: address
            )

            let placemarks: [CLPlacemark]
            if let savedAddress {
                placemarks = try await geocoder.geocodePostalAddress(savedAddress)
                if locationTitle == nil {
                    locationTitle = address.capitalized
                }
            } else {
                placemarks = try await geocoder.geocodeAddressString(address)
            }

            guard let placemark = placemarks.first,
                let geoLocation = placemark.location
            else {
                throw NSError(
                    domain: "RemindersError",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Could not resolve location: \(address)"
                    ]
                )
            }
            coordinate = geoLocation.coordinate
            if locationTitle == nil {
                locationTitle = placemark.name ?? address
            }
        }

        guard let resolvedCoordinate = coordinate else {
            throw NSError(
                domain: "RemindersError",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Location trigger requires either an address or latitude/longitude"
                ]
            )
        }

        let structuredLocation = EKStructuredLocation(title: locationTitle ?? "Location")
        structuredLocation.geoLocation = CLLocation(
            latitude: resolvedCoordinate.latitude,
            longitude: resolvedCoordinate.longitude
        )
        if let radius = location["radius"]?.doubleValue {
            structuredLocation.radius = radius
        }

        log.notice(
            "Reminder location trigger resolved to \(locationTitle ?? "Location", privacy: .public) at \(resolvedCoordinate.latitude, privacy: .private),\(resolvedCoordinate.longitude, privacy: .private)"
        )

        let locationAlarm = EKAlarm()
        locationAlarm.structuredLocation = structuredLocation
        locationAlarm.proximity =
            location["proximity"]?.stringValue?.lowercased() == "leaving"
            ? .leave : .enter
        return locationAlarm
    }

    /// Fetch reminders, optionally restricted to a single list by name.
    private func fetchReminders(inListNamed listName: String?) async throws -> [EKReminder] {
        var lists = self.eventStore.calendars(for: .reminder)
        if let listName {
            lists = lists.filter { $0.title.lowercased() == listName.lowercased() }
        }
        let predicate = self.eventStore.predicateForReminders(in: lists)
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[EKReminder], Error>) in
            self.eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    /// Locate a single reminder by its stable identifier (preferred), or by an
    /// exact case-insensitive title match (optionally restricted to a list).
    /// Throws if nothing matches, or if a title matches more than one reminder.
    private func locateReminder(
        identifier: String?,
        title: String?,
        listName: String?
    ) async throws -> EKReminder {
        if let identifier, !identifier.isEmpty {
            guard
                let reminder = self.eventStore.calendarItem(withIdentifier: identifier)
                    as? EKReminder
            else {
                throw NSError(
                    domain: "RemindersError",
                    code: 5,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "No reminder found with identifier: \(identifier)"
                    ]
                )
            }
            return reminder
        }

        guard let title, !title.isEmpty else {
            throw NSError(
                domain: "RemindersError",
                code: 6,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Provide an identifier or a title to locate the reminder"
                ]
            )
        }

        let matches = try await self.fetchReminders(inListNamed: listName).filter {
            $0.title?.lowercased() == title.lowercased()
        }

        guard let first = matches.first else {
            throw NSError(
                domain: "RemindersError",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "No reminder found with title: \(title)"]
            )
        }
        guard matches.count == 1 else {
            throw NSError(
                domain: "RemindersError",
                code: 8,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Found \(matches.count) reminders titled \"\(title)\"; pass an identifier (from reminders_fetch) to choose one"
                ]
            )
        }
        return first
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
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
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
                            "End date/time range for fetching reminders. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
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
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
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

            // Create predicate based on completion status
            let predicate: NSPredicate
            if case .bool(let completed) = arguments["completed"] {
                if completed {
                    predicate = self.eventStore.predicateForCompletedReminders(
                        withCompletionDateStarting: startDate,
                        ending: endDate,
                        calendars: reminderLists
                    )
                } else {
                    predicate = self.eventStore.predicateForIncompleteReminders(
                        withDueDateStarting: startDate,
                        ending: endDate,
                        calendars: reminderLists
                    )
                }
            } else {
                // If completion status not specified, use incomplete predicate as default
                predicate = self.eventStore.predicateForReminders(in: reminderLists)
            }

            // Fetch reminders
            let reminders = try await withCheckedThrowingContinuation { continuation in
                self.eventStore.fetchReminders(matching: predicate) { fetchedReminders in
                    continuation.resume(returning: fetchedReminders ?? [])
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

            return filteredReminders.map { reminder -> PlanAction in
                var action = PlanAction(reminder)
                action.identifier = reminder.calendarItemIdentifier
                return action
            }
        }

        Tool(
            name: "reminders_create",
            description:
                "Create a new reminder with specified properties, including an optional location-based trigger that fires when arriving at or leaving a place (e.g. \"when I arrive home\")",
            inputSchema: .object(
                properties: [
                    "title": .string(),
                    "due": .string(
                        description:
                            "Due date/time for the reminder. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "list": .string(
                        description: "Reminder list name (uses default if not specified)"
                    ),
                    "notes": .string(),
                    "priority": .string(
                        default: .string(EKReminderPriority.none.stringValue),
                        enum: EKReminderPriority.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": .array(
                        description: "Minutes before due date to set alarms",
                        items: .integer()
                    ),
                    "location": .object(
                        description:
                            "Location-based trigger that fires when arriving at or leaving a place. Provide either an address to geocode, or explicit latitude/longitude coordinates.",
                        properties: [
                            "address": .string(
                                description:
                                    "Address to geocode, or a saved place name from the user's contact card such as \"home\" or \"work\" (use this or latitude/longitude)"
                            ),
                            "latitude": .number(
                                description: "Latitude, used together with longitude"
                            ),
                            "longitude": .number(
                                description: "Longitude, used together with latitude"
                            ),
                            "radius": .number(
                                description: "Trigger radius in meters",
                                default: .double(100)
                            ),
                            "proximity": .string(
                                description:
                                    "Whether the reminder fires when arriving at or leaving the location",
                                default: .string("arriving"),
                                enum: [.string("arriving"), .string("leaving")]
                            ),
                            "title": .string(
                                description: "Display name for the location (e.g. \"Home\")"
                            ),
                        ],
                        additionalProperties: false
                    ),
                ],
                required: ["title"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Reminder",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            let reminder = EKReminder(eventStore: self.eventStore)

            // Set required properties
            guard case .string(let title) = arguments["title"] else {
                throw NSError(
                    domain: "RemindersError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Reminder title is required"]
                )
            }
            reminder.title = title

            // Set calendar (list)
            var calendar = self.eventStore.defaultCalendarForNewReminders()
            if case .string(let listName) = arguments["list"] {
                if let matchingCalendar = self.eventStore.calendars(for: .reminder)
                    .first(where: { $0.title.lowercased() == listName.lowercased() })
                {
                    calendar = matchingCalendar
                }
            }
            reminder.calendar = calendar

            // Set optional properties
            if case .string(let dueDateStr) = arguments["due"],
                let parsedDueDate = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: dueDateStr
                )
            {
                let calendar = Calendar.current
                let dueDate = calendar.normalizedStartDate(
                    from: parsedDueDate.date,
                    isDateOnly: parsedDueDate.isDateOnly
                )
                reminder.dueDateComponents = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: dueDate
                )
            }

            if case .string(let notes) = arguments["notes"] {
                reminder.notes = notes
            }

            if case .string(let priorityStr) = arguments["priority"] {
                reminder.priority = Int(EKReminderPriority.from(string: priorityStr).rawValue)
            }

            // Set alarms
            if case .array(let alarmMinutes) = arguments["alarms"] {
                reminder.alarms = alarmMinutes.compactMap {
                    guard case .int(let minutes) = $0 else { return nil }
                    return EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
                }
            }

            // Set location-based trigger (proximity alarm)
            if case .object(let location) = arguments["location"] {
                reminder.addAlarm(try await self.makeLocationAlarm(from: location))
            }

            // Save the reminder
            try self.eventStore.save(reminder, commit: true)

            var action = PlanAction(reminder)
            action.identifier = reminder.calendarItemIdentifier
            return action
        }

        Tool(
            name: "reminders_update",
            description:
                "Update an existing reminder. Locate it by \"identifier\" (from reminders_fetch, recommended) or by \"title\". Only provide the properties you want to change; omitted properties are left unchanged. When locating by identifier, passing \"title\" renames the reminder.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description:
                            "Stable identifier of the reminder to update (from reminders_fetch). Preferred over title."
                    ),
                    "title": .string(
                        description:
                            "If \"identifier\" is omitted, the exact title used to locate the reminder. If \"identifier\" is provided, the new title to rename it to."
                    ),
                    "due": .string(
                        description:
                            "New due date/time. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "list": .string(
                        description: "Move the reminder to this list"
                    ),
                    "notes": .string(),
                    "completed": .boolean(
                        description: "Mark the reminder complete (true) or incomplete (false)"
                    ),
                    "priority": .string(
                        enum: EKReminderPriority.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": .array(
                        description:
                            "Replace time-based alarms with these (minutes before due date). Location triggers are preserved.",
                        items: .integer()
                    ),
                    "location": .object(
                        description:
                            "Replace the location-based trigger. Provide either an address to geocode (incl. saved places like \"home\"/\"work\"), or explicit latitude/longitude coordinates.",
                        properties: [
                            "address": .string(
                                description:
                                    "Address to geocode, or a saved place name from the user's contact card such as \"home\" or \"work\" (use this or latitude/longitude)"
                            ),
                            "latitude": .number(
                                description: "Latitude, used together with longitude"
                            ),
                            "longitude": .number(
                                description: "Longitude, used together with latitude"
                            ),
                            "radius": .number(
                                description: "Trigger radius in meters",
                                default: .double(100)
                            ),
                            "proximity": .string(
                                description:
                                    "Whether the reminder fires when arriving at or leaving the location",
                                default: .string("arriving"),
                                enum: [.string("arriving"), .string("leaving")]
                            ),
                            "title": .string(
                                description: "Display name for the location (e.g. \"Home\")"
                            ),
                        ],
                        additionalProperties: false
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Update Reminder",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            let identifier = arguments["identifier"]?.stringValue
            let titleArg = arguments["title"]?.stringValue

            let reminder = try await self.locateReminder(
                identifier: identifier,
                title: (identifier == nil) ? titleArg : nil,
                listName: nil
            )

            // When located by identifier, a title argument renames the reminder
            if identifier != nil, let newTitle = titleArg, !newTitle.isEmpty {
                reminder.title = newTitle
            }

            // Move to another list
            if case .string(let listName) = arguments["list"],
                let matchingCalendar = self.eventStore.calendars(for: .reminder)
                    .first(where: { $0.title.lowercased() == listName.lowercased() })
            {
                reminder.calendar = matchingCalendar
            }

            if case .string(let dueDateStr) = arguments["due"],
                let parsedDueDate = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: dueDateStr
                )
            {
                let calendar = Calendar.current
                let dueDate = calendar.normalizedStartDate(
                    from: parsedDueDate.date,
                    isDateOnly: parsedDueDate.isDateOnly
                )
                reminder.dueDateComponents = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: dueDate
                )
            }

            if case .string(let notes) = arguments["notes"] {
                reminder.notes = notes
            }

            if case .bool(let completed) = arguments["completed"] {
                reminder.isCompleted = completed
            }

            if case .string(let priorityStr) = arguments["priority"] {
                reminder.priority = Int(EKReminderPriority.from(string: priorityStr).rawValue)
            }

            // Replace time-based alarms, preserving any location triggers
            if case .array(let alarmMinutes) = arguments["alarms"] {
                let locationAlarms = (reminder.alarms ?? []).filter {
                    $0.structuredLocation != nil
                }
                let timeAlarms = alarmMinutes.compactMap { value -> EKAlarm? in
                    guard case .int(let minutes) = value else { return nil }
                    return EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
                }
                reminder.alarms = locationAlarms + timeAlarms
            }

            // Replace the location trigger, preserving any time-based alarms
            if case .object(let location) = arguments["location"] {
                let nonLocationAlarms = (reminder.alarms ?? []).filter {
                    $0.structuredLocation == nil
                }
                let locationAlarm = try await self.makeLocationAlarm(from: location)
                reminder.alarms = nonLocationAlarms + [locationAlarm]
            }

            try self.eventStore.save(reminder, commit: true)

            var action = PlanAction(reminder)
            action.identifier = reminder.calendarItemIdentifier
            return action
        }

        Tool(
            name: "reminders_delete",
            description:
                "Delete a reminder. Locate it by \"identifier\" (from reminders_fetch, recommended) or by \"title\". If a title matches more than one reminder, an identifier is required.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(
                        description:
                            "Stable identifier of the reminder to delete (from reminders_fetch). Preferred over title."
                    ),
                    "title": .string(
                        description: "Exact title of the reminder to delete (if identifier omitted)"
                    ),
                    "list": .string(
                        description: "Restrict a title match to this list"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Reminder",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                log.error("Reminders access not authorized")
                throw NSError(
                    domain: "RemindersError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Reminders access not authorized"]
                )
            }

            let reminder = try await self.locateReminder(
                identifier: arguments["identifier"]?.stringValue,
                title: arguments["title"]?.stringValue,
                listName: arguments["list"]?.stringValue
            )

            // Capture details before removal
            let deletedIdentifier = reminder.calendarItemIdentifier
            let deletedTitle = reminder.title ?? ""
            let listTitle = reminder.calendar?.title ?? ""

            try self.eventStore.remove(reminder, commit: true)

            return Value.object([
                "deleted": .bool(true),
                "identifier": .string(deletedIdentifier),
                "title": .string(deletedTitle),
                "list": .string(listTitle),
            ])
        }
    }
}
