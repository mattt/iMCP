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
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
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
                            "Start date/time of the range (defaults to now). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
                        format: .dateTime
                    ),
                    "end": .string(
                        description:
                            "End date/time of the range (defaults to one week from start; one day if start is date-only). If timezone is omitted, local time is assumed. Date-only uses local midnight.",
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
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
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
            var hasEnd = false
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
                hasEnd = true
                endDate = parsedEnd.date
                endIsDateOnly = parsedEnd.isDateOnly
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

            return events.map { Event($0) }
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
                                    required: ["datetime"],
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
                                    required: ["locationTitle", "latitude", "longitude"],
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
            try await self.activate()

            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
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
                var alarms: [EKAlarm] = []

                for alarmConfig in alarmConfigs {
                    guard case .object(let config) = alarmConfig else { continue }

                    var alarm: EKAlarm?

                    let alarmType = config["type"]?.stringValue ?? "relative"
                    switch alarmType {
                    case "relative":
                        if case .int(let minutes) = config["minutes"] {
                            alarm = EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
                        }

                    case "absolute":
                        if case .string(let datetimeStr) = config["datetime"] {
                            if ISO8601DateFormatter.isDateOnlyISO8601String(datetimeStr) {
                                log.error(
                                    "Absolute alarm datetime must include time component: \(datetimeStr, privacy: .public)"
                                )
                            } else if let absoluteDate = ISO8601DateFormatter.lenientDate(
                                fromISO8601String: datetimeStr
                            ) {
                                alarm = EKAlarm(absoluteDate: absoluteDate)
                            }
                        }

                    case "proximity":
                        if case .string(let locationTitle) = config["locationTitle"],
                            case .double(let latitude) = config["latitude"],
                            case .double(let longitude) = config["longitude"]
                        {
                            alarm = EKAlarm()

                            // Create structured location
                            let structuredLocation = EKStructuredLocation(title: locationTitle)
                            structuredLocation.geoLocation = CLLocation(
                                latitude: latitude,
                                longitude: longitude
                            )

                            if case .double(let radius) = config["radius"] {
                                structuredLocation.radius = radius
                            } else if case .int(let radiusInt) = config["radius"] {
                                structuredLocation.radius = Double(radiusInt)
                            }

                            // Set proximity type
                            let proximityType = config["proximity"]?.stringValue ?? "enter"
                            let proximity: EKAlarmProximity =
                                proximityType == "enter" ? .enter : .leave
                            alarm?.proximity = proximity
                            alarm?.structuredLocation = structuredLocation
                        }

                    default:
                        log.error(
                            "Unexpected alarm type encountered: \(alarmType, privacy: .public)"
                        )
                        continue
                    }

                    guard let alarm = alarm else { continue }

                    if case .string(let soundName) = config["sound"],
                        Sound(rawValue: soundName) != nil
                    {
                        alarm.soundName = soundName
                    }

                    if case .string(let email) = config["emailAddress"], !email.isEmpty {
                        alarm.emailAddress = email
                    }

                    alarms.append(alarm)
                }

                event.alarms = alarms
            }

            // Save the event
            try self.eventStore.save(event, span: .thisEvent)

            return Event(event)
        }
    }
}
