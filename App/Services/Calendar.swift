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
            name: "events.fetch",
            description: "Get events from the calendar with flexible filtering options",
            inputSchema: .object(
                properties: [
                    "startDate": .string(
                        description: "Start date of the range (defaults to now)",
                        format: .dateTime
                    ),
                    "endDate": .string(
                        description: "End date of the range (defaults to one week from start)",
                        format: .dateTime
                    ),
                    "calendarNames": .array(
                        description:
                            "Names of calendars to fetch from; if empty, fetches from all calendars",
                        items: .string(),
                    ),
                    "searchText": .string(
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
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            // Filter calendars based on provided names
            var calendars = self.eventStore.calendars(for: .event)
            if case let .array(calendarNames) = arguments["calendarNames"],
                !calendarNames.isEmpty
            {
                let requestedNames = Set(calendarNames.compactMap { $0.stringValue?.lowercased() })
                calendars = calendars.filter { requestedNames.contains($0.title.lowercased()) }
            }

            // Parse dates and set defaults
            let now = Date()
            var startDate = now
            var endDate = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: now)!

            if case let .string(start) = arguments["startDate"],
                let parsedStart = ISO8601DateFormatter.parseFlexibleISODate(start)
            {
                startDate = parsedStart
            }

            if case let .string(end) = arguments["endDate"],
                let parsedEnd = ISO8601DateFormatter.parseFlexibleISODate(end)
            {
                endDate = parsedEnd
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
            if case let .bool(includeAllDay) = arguments["includeAllDay"],
                !includeAllDay
            {
                events = events.filter { !$0.isAllDay }
            }

            if case let .string(searchText) = arguments["searchText"],
                !searchText.isEmpty
            {
                events = events.filter {
                    ($0.title?.localizedCaseInsensitiveContains(searchText) == true)
                        || ($0.location?.localizedCaseInsensitiveContains(searchText) == true)
                }
            }

            if case let .string(status) = arguments["status"] {
                let statusValue = EKEventStatus(status)
                events = events.filter { $0.status == statusValue }
            }

            if case let .string(availability) = arguments["availability"] {
                let availabilityValue = EKEventAvailability(availability)
                events = events.filter { $0.availability == availabilityValue }
            }

            if case let .bool(hasAlarms) = arguments["hasAlarms"] {
                events = events.filter { ($0.hasAlarms) == hasAlarms }
            }

            if case let .bool(isRecurring) = arguments["isRecurring"] {
                events = events.filter { ($0.hasRecurrenceRules) == isRecurring }
            }

            return events.map { Event($0) }
        }
        Tool(
            name: "events.create",
            description: "Create a new calendar event with specified properties",
            inputSchema: .object(
                properties: [
                    "title": .string(),
                    "startDate": .string(
                        format: .dateTime
                    ),
                    "endDate": .string(
                        format: .dateTime
                    ),
                    "calendarName": .string(
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
                        description: "Minutes before event to set alarms",
                        items: .integer()
                    ),
                    "hasAlarms": .boolean(),
                    "isRecurring": .boolean(),
                ],
                required: ["title", "startDate", "endDate"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Event",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                log.error("Calendar access not authorized")
                throw NSError(
                    domain: "CalendarError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Calendar access not authorized"]
                )
            }

            // Create new event
            let event = EKEvent(eventStore: self.eventStore)

            // Set required properties
            guard case let .string(title) = arguments["title"] else {
                throw NSError(
                    domain: "CalendarError", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Event title is required"]
                )
            }
            event.title = title

            // Parse dates
            guard case let .string(startDateStr) = arguments["startDate"],
                let startDate = ISO8601DateFormatter.parseFlexibleISODate(startDateStr),
                case let .string(endDateStr) = arguments["endDate"],
                let endDate = ISO8601DateFormatter.parseFlexibleISODate(endDateStr)
            else {
                throw NSError(
                    domain: "CalendarError", code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Invalid start or end date format. Expected ISO 8601 format."
                    ]
                )
            }

            // For all-day events, ensure we use local midnight
            if case .bool(true) = arguments["isAllDay"] {
                let calendar = Calendar.current
                var startComponents = calendar.dateComponents(
                    [.year, .month, .day], from: startDate)
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
            var calendar = self.eventStore.defaultCalendarForNewEvents
            if case let .string(calendarName) = arguments["calendarName"] {
                if let matchingCalendar = self.eventStore.calendars(for: .event)
                    .first(where: { $0.title.lowercased() == calendarName.lowercased() })
                {
                    calendar = matchingCalendar
                }
            }
            event.calendar = calendar

            // Set optional properties
            if case let .string(location) = arguments["location"] {
                event.location = location
            }

            if case let .string(notes) = arguments["notes"] {
                event.notes = notes
            }

            if case let .string(urlString) = arguments["url"],
                let url = URL(string: urlString)
            {
                event.url = url
            }

            if case let .string(availability) = arguments["availability"] {
                event.availability = EKEventAvailability(availability)
            }

            // Set alarms
            if case let .array(alarmMinutes) = arguments["alarms"] {
                event.alarms = alarmMinutes.compactMap {
                    guard case let .int(minutes) = $0 else { return nil }
                    return EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
                }
            }

            // Save the event
            try self.eventStore.save(event, span: .thisEvent)

            return Event(event)
        }
    }
}
