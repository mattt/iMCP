import AppKit
import CoreLocation
import EventKit
import Foundation
import OSLog
import Ontology

private let log = Logger.service("calendar")

final class CalendarService: Service {
    private let eventStore = EKEventStore()

    static let shared = CalendarService()

    var isActivated: Bool {
        get async {
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        }
    }

    func activate() async throws {
        try await eventStore.requestFullAccessToEvents()
    }

    var tools: [Tool] {
        Tool(
            name: "calendars_list",
            description: "List available calendars",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Calendars",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard try await self.eventStore.requestFullAccessToEvents() else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            let calendars = self.eventStore.calendars(for: .event)

            return calendars.map { calendar in
                Value.object([
                    "title": .string(calendar.title),
                    "source": .string(calendar.source.title),
                    "color": .string(calendar.color.accessibilityName),
                    "isEditable": .bool(calendar.allowsContentModifications),
                    "isSubscribed": .bool(calendar.isSubscribed),
                ])
            }
        }

        Tool(
            name: "events_fetch",
            description: "Get events from the calendar with flexible filtering options",
            inputSchema: .object(
                properties: [
                    "start": .string(
                        description:
                            "Start date/time (defaults to now; if end is date-only and start is omitted, uses end's local midnight). If timezone is omitted, local time is assumed.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End date/time (defaults to one week from start; one day if start is date-only). If timezone is omitted, local time is assumed. A date-only value includes that whole day.",
                        format: .dateTime
                    ),
                    "calendars": .array(
                        description:
                            "Names of calendars to fetch from; if empty, fetches from all calendars",
                        items: .string(),
                    ),
                    "query": .string(
                        description: "Text to search for in event titles and locations"
                    ),
                    "includeAllDay": .boolean(
                        default: true
                    ),
                    "status": .string(
                        description: "Filter by event status",
                        enum: ["none", "tentative", "confirmed", "canceled"]
                    ),
                    "availability": .string(
                        description: "Filter by availability status",
                        enum: EKEventAvailability.allCases.map { .string($0.stringValue) }
                    ),
                    "hasAlarms": .boolean(),
                    "isRecurring": .boolean(),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Events",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard try await self.eventStore.requestFullAccessToEvents() else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            // Filter calendars based on provided names
            var calendars = self.eventStore.calendars(for: .event)
            if case .array(let calendarNames) = arguments["calendars"],
                !calendarNames.isEmpty
            {
                let requestedNames = Set(calendarNames.compactMap { $0.stringValue?.lowercased() })
                calendars = calendars.filter { requestedNames.contains($0.title.lowercased()) }
            }

            // Parse dates and set defaults
            let now = Date()
            let calendar = Calendar.current
            var startDate = now
            var endDate = calendar.date(byAdding: .weekOfYear, value: 1, to: now)!
            var hasStart = false
            var hasEnd = false
            var startIsDateOnly = false
            var endIsDateOnly = false

            if case .string(let start) = arguments["start"] {
                guard
                    let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: start
                    )
                else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Invalid start date format. Expected ISO 8601 format."
                        ]
                    )
                }
                hasStart = true
                startDate = parsedStart.date
                startIsDateOnly = parsedStart.isDateOnly
            }

            if case .string(let end) = arguments["end"],
                let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: end
                )
            {
                hasEnd = true
                endDate = parsedEnd.date
                endIsDateOnly = parsedEnd.isDateOnly
            }

            if !hasStart, endIsDateOnly {
                startDate = endDate
                startIsDateOnly = true
            }

            startDate = calendar.normalizedStartDate(from: startDate, isDateOnly: startIsDateOnly)

            if endIsDateOnly {
                endDate = calendar.normalizedEndDate(from: endDate, isDateOnly: true)
            } else if !hasEnd {
                if startIsDateOnly {
                    endDate = calendar.normalizedEndDate(from: startDate, isDateOnly: true)
                } else if let nextWeek = calendar.date(
                    byAdding: .weekOfYear,
                    value: 1,
                    to: startDate
                ) {
                    endDate = nextWeek
                }
            }

            // Create base predicate for date range and calendars
            let predicate = self.eventStore.predicateForEvents(
                withStart: startDate,
                end: endDate,
                calendars: calendars
            )

            // Fetch events
            var events = self.eventStore.events(matching: predicate)

            // Apply additional filters
            if case .bool(let includeAllDay) = arguments["includeAllDay"],
                !includeAllDay
            {
                events = events.filter { !$0.isAllDay }
            }

            if case .string(let searchText) = arguments["query"],
                !searchText.isEmpty
            {
                events = events.filter {
                    ($0.title?.localizedCaseInsensitiveContains(searchText) == true)
                        || ($0.location?.localizedCaseInsensitiveContains(searchText) == true)
                }
            }

            if case .string(let status) = arguments["status"] {
                let statusValue = EKEventStatus(status)
                events = events.filter { $0.status == statusValue }
            }

            if case .string(let availability) = arguments["availability"] {
                let availabilityValue = EKEventAvailability(availability)
                events = events.filter { $0.availability == availabilityValue }
            }

            if case .bool(let hasAlarms) = arguments["hasAlarms"] {
                events = events.filter { ($0.hasAlarms) == hasAlarms }
            }

            if case .bool(let isRecurring) = arguments["isRecurring"] {
                events = events.filter { ($0.hasRecurrenceRules) == isRecurring }
            }

            return events.map { event -> Event in
                var e = Event(event)
                e.identifier = event.eventIdentifier
                return e
            }
        }
        Tool(
            name: "events_create",
            description: "Create a new calendar event with specified properties",
            inputSchema: .object(
                properties: [
                    "title": .string(),
                    "start": .string(
                        description:
                            "Start date/time for the event. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End date/time for the event. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "calendar": .string(
                        description: "Calendar to use (uses default if not specified)"
                    ),
                    "location": .string(),
                    "notes": .string(),
                    "url": .string(
                        format: .uri
                    ),
                    "isAllDay": .boolean(
                        default: false
                    ),
                    "availability": .string(
                        description: "Availability status",
                        default: .string(EKEventAvailability.busy.stringValue),
                        enum: EKEventAvailability.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": .array(
                        description: "Alarm configurations for the event",
                        items: .anyOf(
                            [
                                // Relative alarm (minutes before event)
                                .object(
                                    properties: [
                                        "type": .string(
                                            const: "relative",
                                        ),
                                        "minutes": .integer(
                                            description:
                                                "Minutes offset from event start (negative for before, positive for after)"
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
                                            const: "absolute",
                                        ),
                                        "datetime": .string(
                                            description:
                                                "Alarm date/time. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
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
                                // Proximity alarm (location-based)
                                .object(
                                    properties: [
                                        "type": .string(
                                            const: "proximity",
                                        ),
                                        "proximity": .string(
                                            description: "Proximity trigger type",
                                            default: "enter",
                                            enum: ["enter", "leave"]
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
                                    required: ["type", "locationTitle", "latitude", "longitude"],
                                    additionalProperties: false
                                ),
                            ]
                        )
                    ),
                    "hasAlarms": .boolean(),
                    "isRecurring": .boolean(),
                ],
                required: ["title", "start", "end"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Event",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard try await self.eventStore.requestFullAccessToEvents() else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            // Create new event
            let event = EKEvent(eventStore: self.eventStore)

            // Set required properties
            guard case .string(let title) = arguments["title"] else {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Event title is required"]
                )
            }
            event.title = title

            // Parse dates
            guard case .string(let startDateStr) = arguments["start"],
                let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: startDateStr
                ),
                case .string(let endDateStr) = arguments["end"],
                let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: endDateStr
                )
            else {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Invalid start or end date format. Expected ISO 8601 format."
                    ]
                )
            }

            let calendar = Calendar.current
            let startDate = calendar.normalizedStartDate(
                from: parsedStart.date,
                isDateOnly: parsedStart.isDateOnly
            )
            let endDate = calendar.normalizedStartDate(
                from: parsedEnd.date,
                isDateOnly: parsedEnd.isDateOnly
            )

            // For all-day events, ensure we use local midnight
            if case .bool(true) = arguments["isAllDay"] {
                var startComponents = calendar.dateComponents(
                    [.year, .month, .day],
                    from: startDate
                )
                startComponents.hour = 0
                startComponents.minute = 0
                startComponents.second = 0

                var endComponents = calendar.dateComponents([.year, .month, .day], from: endDate)
                endComponents.hour = 23
                endComponents.minute = 59
                endComponents.second = 59

                event.startDate = calendar.date(from: startComponents)!
                event.endDate = calendar.date(from: endComponents)!
                event.isAllDay = true
            } else {
                event.startDate = startDate
                event.endDate = endDate
            }

            // Set calendar
            var targetCalendar = self.eventStore.defaultCalendarForNewEvents
            if case .string(let calendarName) = arguments["calendar"] {
                if let matchingCalendar = self.eventStore.calendars(for: .event)
                    .first(where: { $0.title.lowercased() == calendarName.lowercased() })
                {
                    targetCalendar = matchingCalendar
                }
            }
            event.calendar = targetCalendar

            // Set optional properties
            if case .string(let location) = arguments["location"] {
                event.location = location
            }

            if case .string(let notes) = arguments["notes"] {
                event.notes = notes
            }

            if case .string(let urlString) = arguments["url"],
                let url = URL(string: urlString)
            {
                event.url = url
            }

            if case .string(let availability) = arguments["availability"] {
                event.availability = EKEventAvailability(availability)
            }

            // Set alarms
            if case .array(let alarmConfigs) = arguments["alarms"] {
                event.alarms = alarmConfigs.compactMap { Self.alarm(from: $0) }
            }

            // Save the event
            try self.eventStore.save(event, span: .thisEvent)

            var result = Event(event)
            result.identifier = event.eventIdentifier
            return result
        }

        Tool(
            name: "events_delete",
            description:
                "Delete a calendar event by identifier. For a recurring event, pass the start date of the occurrence to delete.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(description: "The event identifier"),
                    "start": .string(
                        description:
                            "Start date of the occurrence to delete (ISO 8601). Required for recurring events, since every occurrence shares the same identifier."
                    ),
                    "span": .string(
                        description:
                            "For recurring events: delete only this occurrence, or this and all future events",
                        default: .string("thisEvent"),
                        enum: ["thisEvent", "futureEvents"]
                    ),
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Event",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard try await self.eventStore.requestFullAccessToEvents() else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            guard case .string(let identifier) = arguments["identifier"] else {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Event identifier is required"]
                )
            }

            let span: EKSpan
            switch arguments["span"]?.stringValue {
            case nil, "thisEvent":
                span = .thisEvent
            case "futureEvents":
                span = .futureEvents
            case let other?:
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Invalid span \"\(other)\". Expected \"thisEvent\" or \"futureEvents\"."
                    ]
                )
            }

            // Every occurrence of a recurring event shares one identifier,
            // and `event(withIdentifier:)` always resolves it to the first occurrence.
            // When a start date is given,
            // refetch that exact occurrence so `thisEvent` removes the right one
            // and `futureEvents` starts from it rather than from the whole series.
            // Detached-exception identifiers carry an occurrence suffix
            // ("<series>/RID=<n>"); the shared resolver falls back to the
            // series prefix, and the start date still selects the exact
            // occurrence.
            guard
                let resolved = self.eventPossiblyDetached(identifier)
            else {
                throw NSError(
                    domain: "CalendarError",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey: "No event found with identifier \(identifier)"
                    ]
                )
            }
            let anyOccurrence = resolved.event
            let seriesIdentifier = resolved.seriesIdentifier

            let event: EKEvent
            if case .string(let startString) = arguments["start"] {
                guard
                    let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: startString
                    )
                else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Invalid start date format. Expected ISO 8601 format."
                        ]
                    )
                }
                let startDate = Calendar.current.normalizedStartDate(
                    from: parsedStart.date,
                    isDateOnly: parsedStart.isDateOnly
                )
                guard
                    let occurrence = self.occurrence(
                        ofEventWithIdentifier: seriesIdentifier,
                        startingAt: startDate
                    )
                else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 3,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "No occurrence of event \(identifier) starts at \(startString)"
                        ]
                    )
                }
                event = occurrence
            } else if anyOccurrence.hasRecurrenceRules {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Event \(identifier) is recurring. Pass the start date of the occurrence to delete."
                    ]
                )
            } else {
                event = anyOccurrence
            }

            try self.eventStore.remove(event, span: span, commit: true)

            return Value.object([
                "deleted": .bool(true),
                "identifier": .string(identifier),
            ])
        }

        Tool(
            name: "events_update",
            description:
                "Update an existing calendar event. Only provide values for properties that need to be changed; omit any properties that should remain unchanged. Passing null clears title, location, notes, url, or alarms. For a recurring event, pass the start date of the occurrence to update.",
            inputSchema: .object(
                properties: [
                    "identifier": .string(description: "The event identifier"),
                    "title": .anyOf([
                        .string(),
                        .null,
                    ]),
                    "start": .string(
                        description:
                            "New start date/time for the event. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "New end date/time for the event. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "occurrence": .string(
                        description:
                            "Start date of the occurrence to update, since every occurrence of a recurring event shares the same identifier. Required for recurring events.",
                        format: .dateTime
                    ),
                    "calendar": .string(
                        description: "Calendar to move the event to, matched by title"
                    ),
                    "location": .anyOf([
                        .string(description: "Location text. Pass null to clear."),
                        .null,
                    ]),
                    "notes": .anyOf([
                        .string(description: "Event notes. Pass null to clear."),
                        .null,
                    ]),
                    "url": .anyOf([
                        .string(
                            description: "URL attached to the event. Pass null to clear.",
                            format: .uri
                        ),
                        .null,
                    ]),
                    "isAllDay": .boolean(
                        description: "Whether the event spans the whole day"
                    ),
                    "availability": .string(
                        description: "Availability status",
                        enum: EKEventAvailability.allCases.map { .string($0.stringValue) }
                    ),
                    "alarms": .anyOf([
                        .array(
                            description:
                                "Alarm configurations for the event, replacing any existing alarms. Pass null to remove all alarms.",
                            items: .anyOf([
                                // Relative alarm (minutes before event)
                                .object(
                                    properties: [
                                        "type": .string(
                                            const: "relative"
                                        ),
                                        "minutes": .integer(
                                            description:
                                                "Minutes offset from event start (negative for before, positive for after)"
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
                                                "Alarm date/time. If timezone is omitted, local time is assumed. Date-only uses local midnight.",
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
                                // Proximity alarm (location-based)
                                .object(
                                    properties: [
                                        "type": .string(
                                            const: "proximity"
                                        ),
                                        "proximity": .string(
                                            description: "Proximity trigger type",
                                            default: "enter",
                                            enum: ["enter", "leave"]
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
                                    required: ["type", "locationTitle", "latitude", "longitude"],
                                    additionalProperties: false
                                ),
                            ])
                        ),
                        .null,
                    ]),
                    "span": .string(
                        description:
                            "For recurring events: update only this occurrence, or this and all future events",
                        default: .string("thisEvent"),
                        enum: ["thisEvent", "futureEvents"]
                    ),
                ],
                required: ["identifier"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Update Event",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard try await self.eventStore.requestFullAccessToEvents() else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            guard case .string(let identifier) = arguments["identifier"] else {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Event identifier is required"]
                )
            }

            let span: EKSpan
            switch arguments["span"]?.stringValue {
            case nil, "thisEvent":
                span = .thisEvent
            case "futureEvents":
                span = .futureEvents
            case let other?:
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Invalid span \"\(other)\". Expected \"thisEvent\" or \"futureEvents\"."
                    ]
                )
            }

            // Every occurrence of a recurring event shares one identifier,
            // and `event(withIdentifier:)` always resolves it to the first occurrence.
            // When an occurrence date is given, refetch that exact occurrence so
            // `thisEvent` updates the right one and `futureEvents` starts from it.
            // Detached-exception identifiers carry an occurrence suffix
            // ("<series>/RID=<n>"); the shared resolver falls back to the
            // series prefix, and the occurrence date still selects the
            // exact occurrence.
            guard
                let resolved = self.eventPossiblyDetached(identifier)
            else {
                throw NSError(
                    domain: "CalendarError",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey: "No event found with identifier \(identifier)"
                    ]
                )
            }
            let anyOccurrence = resolved.event
            let seriesIdentifier = resolved.seriesIdentifier

            let event: EKEvent
            if case .string(let occurrenceString) = arguments["occurrence"] {
                guard
                    let parsedOccurrence = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: occurrenceString
                    )
                else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Invalid occurrence date format. Expected ISO 8601 format."
                        ]
                    )
                }
                let occurrenceDate = Calendar.current.normalizedStartDate(
                    from: parsedOccurrence.date,
                    isDateOnly: parsedOccurrence.isDateOnly
                )
                guard
                    let occurrence = self.occurrence(
                        ofEventWithIdentifier: seriesIdentifier,
                        startingAt: occurrenceDate
                    )
                else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 3,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "No occurrence of event \(identifier) starts at \(occurrenceString)"
                        ]
                    )
                }
                event = occurrence
            } else if anyOccurrence.hasRecurrenceRules {
                throw NSError(
                    domain: "CalendarError",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Event \(identifier) is recurring. Pass the occurrence parameter: the start date of the occurrence to update."
                    ]
                )
            } else {
                event = anyOccurrence
            }

            // Validate everything before touching the event: EventKit keeps
            // unsaved mutations in its shared store, so an error thrown
            // halfway through would otherwise be committed by the next
            // successful save of anything.
            var newStartDate: Date? = nil
            if case .string(let startDateString) = arguments["start"] {
                guard
                    let parsedStart = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: startDateString
                    )
                else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Invalid start date format. Expected ISO 8601 format."
                        ]
                    )
                }
                newStartDate = Calendar.current.normalizedStartDate(
                    from: parsedStart.date,
                    isDateOnly: parsedStart.isDateOnly
                )
            }

            var newEndDate: Date? = nil
            if case .string(let endDateString) = arguments["end"] {
                guard
                    let parsedEnd = ISO8601DateFormatter.parsedLenientISO8601Date(
                        fromISO8601String: endDateString
                    )
                else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Invalid end date format. Expected ISO 8601 format."
                        ]
                    )
                }
                newEndDate = Calendar.current.normalizedStartDate(
                    from: parsedEnd.date,
                    isDateOnly: parsedEnd.isDateOnly
                )
            }

            // Move to another calendar when requested; an unmatched name is an error
            // rather than a silent default.
            var targetCalendar: EKCalendar? = nil
            if case .string(let calendarName) = arguments["calendar"] {
                // Editability joins the match so a read-only target (a
                // subscribed calendar, say) throws here, before any
                // mutation: a move into it would otherwise sit unsaved in
                // the shared store until the next successful save of
                // anything commits it.
                guard
                    let matchingCalendar = self.eventStore.calendars(for: .event)
                        .first(where: {
                            $0.title.lowercased() == calendarName.lowercased()
                                && $0.allowsContentModifications
                        })
                else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey: "No calendar named \"\(calendarName)\""
                        ]
                    )
                }
                targetCalendar = matchingCalendar
            }

            var newURL: URL? = nil
            if case .string(let urlString) = arguments["url"] {
                guard let url = URL(string: urlString) else {
                    throw NSError(
                        domain: "CalendarError",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Invalid URL \"\(urlString)\""
                        ]
                    )
                }
                newURL = url
            }

            if case .string(let title) = arguments["title"] {
                event.title = title
            } else if case .null = arguments["title"] {
                event.title = nil
            }

            if let targetCalendar {
                event.calendar = targetCalendar
            }

            if case .string(let location) = arguments["location"] {
                event.location = location
            } else if case .null = arguments["location"] {
                event.location = nil
            }

            if case .string(let notes) = arguments["notes"] {
                event.notes = notes
            } else if case .null = arguments["notes"] {
                event.notes = nil
            }

            if let newURL {
                event.url = newURL
            } else if case .null = arguments["url"] {
                event.url = nil
            }

            if case .string(let availability) = arguments["availability"] {
                event.availability = EKEventAvailability(availability)
            }

            if let newStartDate {
                event.startDate = newStartDate
            }
            if let newEndDate {
                event.endDate = newEndDate
            }

            // For all-day events, ensure whole-day boundaries, mirroring events_create
            if case .bool(let isAllDay) = arguments["isAllDay"] {
                if isAllDay {
                    let calendar = Calendar.current
                    var startComponents = calendar.dateComponents(
                        [.year, .month, .day],
                        from: event.startDate
                    )
                    startComponents.hour = 0
                    startComponents.minute = 0
                    startComponents.second = 0

                    var endComponents = calendar.dateComponents(
                        [.year, .month, .day],
                        from: event.endDate
                    )
                    endComponents.hour = 23
                    endComponents.minute = 59
                    endComponents.second = 59

                    event.startDate = calendar.date(from: startComponents)!
                    event.endDate = calendar.date(from: endComponents)!
                }
                event.isAllDay = isAllDay
            }

            switch arguments["alarms"] {
            case .array(let alarmConfigs):
                event.alarms = alarmConfigs.compactMap { Self.alarm(from: $0) }
            case .null:
                event.alarms = []
            default:
                break
            }

            try self.eventStore.save(event, span: span)

            var result = Event(event)
            result.identifier = event.eventIdentifier
            return result
        }
    }

    private static func alarm(from value: Value) -> EKAlarm? {
        guard case .object(let config) = value else { return nil }

        var alarm: EKAlarm?

        let alarmType = config["type"]?.stringValue ?? "relative"
        switch alarmType {
        case "relative":
            if case .int(let minutes) = config["minutes"] {
                alarm = EKAlarm(relativeOffset: -Double(minutes) * 60)
            }

        case "absolute":
            if case .string(let datetimeString) = config["datetime"] {
                // Date-only values mean local midnight, like every other
                // date parameter of these tools.
                if let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(
                    fromISO8601String: datetimeString
                ) {
                    alarm = EKAlarm(
                        absoluteDate: Calendar.current.normalizedStartDate(
                            from: parsed.date,
                            isDateOnly: parsed.isDateOnly
                        )
                    )
                }
            }

        case "proximity":
            // .number() validates integers too, and whole-degree
            // coordinates are common; bridge them instead of dropping.
            if case .string(let locationTitle) = config["locationTitle"],
                let latitude = Self.number(config["latitude"]),
                let longitude = Self.number(config["longitude"])
            {
                alarm = EKAlarm()

                let structuredLocation = EKStructuredLocation(title: locationTitle)
                structuredLocation.geoLocation = CLLocation(
                    latitude: latitude,
                    longitude: longitude
                )

                if let radius = Self.number(config["radius"]) {
                    structuredLocation.radius = radius
                }

                let proximityType = config["proximity"]?.stringValue ?? "enter"
                alarm?.proximity = proximityType == "enter" ? .enter : .leave
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

    /// The double a JSON Schema "number" accepts, whether the decoder
    /// produced an Int (no fraction) or a Double.
    private static func number(_ value: Value?) -> Double? {
        switch value {
        case .double(let double): return double
        case .int(let int): return Double(int)
        default: return nil
        }
    }

    /// Resolves the exact occurrence of a recurring event at a start date. Detached
    /// exceptions from earlier `thisEvent` edits carry `<series-id>/RID=<n>` instead of
    /// the series identifier, so match that prefix as well.
    private func occurrence(ofEventWithIdentifier identifier: String, startingAt date: Date) -> EKEvent? {
        let predicate = eventStore.predicateForEvents(
            withStart: date,
            end: date.addingTimeInterval(1),
            calendars: nil
        )
        return eventStore.events(matching: predicate).first {
            guard let occurrenceIdentifier = $0.eventIdentifier else { return false }
            return
                (occurrenceIdentifier == identifier || occurrenceIdentifier.hasPrefix(identifier + "/"))
                && abs($0.startDate.timeIntervalSince(date)) < 1
        }
    }
    /// Resolves an event identifier that may carry a detached-exception
    /// suffix ("<series>/RID=<n>"), which `event(withIdentifier:)` does not
    /// resolve, returning the event and the series identifier its occurrences
    /// are addressed by.
    private func eventPossiblyDetached(_ identifier: String) -> (event: EKEvent, seriesIdentifier: String)? {
        if let event = eventStore.event(withIdentifier: identifier) {
            return (event, identifier)
        }
        guard let separator = identifier.range(of: "/RID=") else { return nil }
        let prefix = String(identifier[..<separator.lowerBound])
        guard let event = eventStore.event(withIdentifier: prefix) else { return nil }
        return (event, prefix)
    }
}
