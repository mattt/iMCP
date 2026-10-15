import Foundation
import JSONSchema
import MCP

/// Handles calls to the mobile tools.
///
/// The iOS app implements it with HealthKit, FinanceKit, and AlarmKit.
/// The Mac app implements it by forwarding calls to the phone
/// or answering from its cache when the phone isn't connected.
protocol MobileBackend: Sendable {
    func call(_ tool: String, _ input: [String: Value]) async throws -> Value
}

struct MobileError: LocalizedError, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    var description: String { message }
}

/// Tool definitions shared by the Mac app and the iOS app.
enum MobileTools {
    static let statusTool = "mobile_status"
    /// The device's error when iOS protects HealthKit data because the device is locked.
    /// The Mac answers such reads from its cache.
    static let lockedMessage = "HealthKit data is protected while the iPhone or iPad is locked."

    static let clinicalTypes = [
        "allergyRecord", "clinicalNoteRecord", "conditionRecord", "coverageRecord", "immunizationRecord",
        "labResultRecord", "medicationRecord", "procedureRecord", "vitalSignRecord",
    ]
    static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    static let transactionStatuses = ["authorized", "memo", "pending", "booked", "rejected"]
    static let statisticsIntervals = ["hour", "day", "week", "month"]
    /// How far back health_statistics looks when the call gives no start.
    static let defaultStatisticsWindow: TimeInterval = 30 * 86_400

    private static let sync =
        "Results include synced_at and stale. When the iPhone or iPad isn't connected, answers come from the Mac's copy of the data it last sent."
    private static let start = JSONSchema.string(
        description: "Start of the date range, as an ISO 8601 timestamp or a YYYY-MM-DD day in the Mac's time zone.",
        format: .dateTime
    )
    private static let end = JSONSchema.string(
        description: "End of the date range, as an ISO 8601 timestamp or a YYYY-MM-DD day. Defaults to now.",
        format: .dateTime
    )
    private static let limit = JSONSchema.integer(
        description: "Maximum number of results. Defaults to 100.",
        minimum: 1,
        maximum: 1000
    )
    private static let identifier = JSONSchema.string(description: "UUID")

    static func all(backend: any MobileBackend) -> [Tool] {
        var seen = Set<String>()
        return MobileDomain.allCases.flatMap { tools(for: $0, backend: backend) }
            .filter { seen.insert($0.name).inserted }
    }

    /// The tools of one service, followed by `mobile_status`,
    /// which every mobile service includes.
    static func tools(for domain: MobileDomain, backend: any MobileBackend) -> [Tool] {
        func tool(
            _ name: String,
            _ description: String,
            _ properties: [String: JSONSchema] = [:],
            required: [String] = [],
            read: Bool = false,
            idempotent: Bool = false,
            destructive: Bool = false
        ) -> Tool {
            Tool(
                name: name,
                description: description,
                inputSchema: .object(
                    properties: .init(uniqueKeysWithValues: properties.sorted { $0.key < $1.key }),
                    required: required,
                    additionalProperties: false
                ),
                annotations: annotations(read: read, idempotent: idempotent, destructive: destructive)
            ) { input in
                try await backend.call(name, input)
            }
        }
        let healthType = JSONSchema.string(
            description:
                "HealthKit type, such as stepCount, heartRate, or sleepAnalysis. HKQuantityTypeIdentifier and HKCategoryTypeIdentifier names also work."
        )
        let account = JSONSchema.string(description: "FinanceKit account UUID. Omit for all accounts.")

        var tools: [Tool]
        switch domain {
        case .health:
            tools = [
                tool(
                    "health_fetch",
                    "Fetch HealthKit samples of one type, newest first. HealthKit doesn't tell apps when read access is denied, so an empty result means no samples or denied access. Raw quantity samples, such as heart rate, need iMCP on the iPhone or iPad to be reachable; use health_statistics for daily totals at other times. \(sync)",
                    [
                        "type": healthType, "start": start, "end": end, "limit": limit,
                        "ascending": .boolean(description: "Return the oldest samples first.", default: false),
                    ],
                    required: ["type"],
                    read: true
                ),
                tool(
                    "health_statistics",
                    "Summarize a HealthKit quantity type by hour, day, week, or month: sums for cumulative types such as steps, and average, minimum, and maximum for discrete types such as heart rate. Daily values for the last two years are available when the iPhone or iPad isn't connected. \(sync)",
                    [
                        "type": healthType, "start": start, "end": end,
                        "interval": .string(
                            description: "Bucket size. Defaults to day.",
                            enum: statisticsIntervals.map { .string($0) }
                        ),
                    ],
                    required: ["type"],
                    read: true
                ),
                tool(
                    "workouts_fetch",
                    "Fetch workouts with activity type, duration, energy, and distance, newest first. \(sync)",
                    [
                        "activity_type": .string(
                            description: "HKWorkoutActivityType name, such as running or cycling."
                        ),
                        "start": start, "end": end, "limit": limit,
                    ],
                    read: true
                ),
                tool(
                    "clinical_records_fetch",
                    "Fetch health records from connected health institutions as FHIR JSON. \(sync)",
                    [
                        "type": .string(
                            description: "Clinical record type. Omit for all types.",
                            enum: clinicalTypes.map { .string($0) }
                        ),
                        "start": start, "end": end, "limit": limit,
                    ],
                    read: true
                ),
            ]
        case .finance:
            tools = [
                tool(
                    "finance_accounts_list",
                    "List Apple Card, Apple Cash, and Apple Savings accounts from Wallet on the iPhone or iPad. \(sync)",
                    read: true
                ),
                tool(
                    "finance_balances_fetch",
                    "Fetch account balances, newest first. \(sync)",
                    ["account": account, "start": start, "end": end, "limit": limit],
                    read: true
                ),
                tool(
                    "finance_transactions_fetch",
                    "Fetch Wallet transactions, newest first, with merchant, amount, status, and category code. \(sync)",
                    [
                        "account": account, "start": start, "end": end, "limit": limit,
                        "status": .string(enum: transactionStatuses.map { .string($0) }),
                        "query": .string(description: "Case-insensitive text to find in the merchant or description."),
                    ],
                    read: true
                ),
            ]
        case .alarms:
            let id = JSONSchema.string(
                description:
                    "Optional UUID for the new alarm. A retried call with the same ID returns the existing alarm instead of creating another."
            )
            let title = JSONSchema.string(description: "Text that the alarm shows.")
            tools = [
                tool(
                    "alarms_list",
                    "List the alarms and timers that iMCP created on the user's iPhone or iPad. AlarmKit doesn't give apps access to Clock app alarms. When the iPhone or iPad isn't connected, the list is the last state it sent. Results include synced_at and stale.",
                    read: true
                ),
                Tool(
                    name: "alarms_create",
                    description:
                        "Schedule an alarm on the user's iPhone or iPad. It sounds even in silent mode and Focus, and the user can cancel it in iMCP on that device. Give fire_at for a one-time alarm on a date, or hour and minute for the next occurrence of a time, with optional weekdays to repeat weekly. Needs iMCP on the iPhone or iPad to be reachable.",
                    inputSchema: .anyOf([
                        .object(
                            properties: [
                                "fire_at": .string(
                                    description: "Future ISO 8601 timestamp with a time zone.",
                                    format: .dateTime
                                ),
                                "id": id,
                                "title": title,
                            ],
                            required: ["title", "fire_at"],
                            additionalProperties: false
                        ),
                        .object(
                            properties: [
                                "hour": .integer(minimum: 0, maximum: 23),
                                "id": id,
                                "minute": .integer(minimum: 0, maximum: 59),
                                "title": title,
                                "weekdays": .array(
                                    items: .string(enum: weekdays.map { .string($0) }),
                                    minItems: 1,
                                    uniqueItems: true
                                ),
                            ],
                            required: ["title", "hour", "minute"],
                            additionalProperties: false
                        ),
                    ]),
                    annotations: annotations(read: false, idempotent: false, destructive: false)
                ) { input in
                    try await backend.call("alarms_create", input)
                },
                tool(
                    "timers_create",
                    "Start a countdown timer on the user's iPhone or iPad that alerts when it ends, even in silent mode and Focus. Needs iMCP on the iPhone or iPad to be reachable.",
                    [
                        "id": id, "title": title,
                        "duration_seconds": .integer(description: "Length of the timer.", minimum: 1, maximum: 86_400),
                    ],
                    required: ["title", "duration_seconds"]
                ),
                tool(
                    "alarms_cancel",
                    "Cancel an alarm or timer that iMCP on the iPhone or iPad created. Needs iMCP on the iPhone or iPad to be reachable.",
                    ["id": identifier],
                    required: ["id"],
                    idempotent: true,
                    destructive: true
                ),
            ]
        }
        tools.append(
            tool(
                statusTool,
                "Report whether an iPhone or iPad is paired and connected, and when each service last synced.",
                read: true
            )
        )
        return tools
    }

    /// The service that owns a tool, or nil for `mobile_status`, which all of them share.
    static func domain(of tool: String) -> MobileDomain? {
        switch tool {
        case "health_fetch", "health_statistics", "workouts_fetch", "clinical_records_fetch": return .health
        case "finance_accounts_list", "finance_balances_fetch", "finance_transactions_fetch": return .finance
        case "alarms_list", "alarms_create", "timers_create", "alarms_cancel": return .alarms
        default: return nil
        }
    }

    /// The short name of a HealthKit type, such as `stepCount`,
    /// from either that name or the framework identifier.
    static func healthTypeName(_ name: String) -> String {
        var name = name
        for prefix in [
            "HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier", "HKClinicalTypeIdentifier",
            "HKCorrelationTypeIdentifier", "HKWorkoutActivityType",
        ] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        guard let first = name.first else { return name }
        return first.lowercased() + name.dropFirst()
    }

    private static func annotations(read: Bool, idempotent: Bool, destructive: Bool) -> MCP.Tool.Annotations {
        .init(
            readOnlyHint: read,
            destructiveHint: destructive,
            idempotentHint: read || idempotent,
            openWorldHint: false
        )
    }
}

/// Typed access to validated tool arguments.
struct MobileArguments: Sendable {
    let values: [String: Value]
    init(_ values: [String: Value]) { self.values = values }

    func string(_ key: String) -> String? { values[key]?.stringValue }

    func required(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else { throw MobileError("Missing argument: \(key)") }
        return value
    }

    func int(_ key: String) -> Int? { values[key]?.intValue }

    func bool(_ key: String) -> Bool? { values[key]?.boolValue }

    func strings(_ key: String) -> [String]? { values[key]?.arrayValue?.compactMap(\.stringValue) }

    func limit(default fallback: Int = 100) -> Int { int("limit") ?? fallback }

    /// A timestamp, or the start of a day in the current time zone.
    func date(_ key: String) throws -> Date? {
        guard let text = string(key) else { return nil }
        if let date = Self.parse(text) { return date }
        throw MobileError("\(key) must be an ISO 8601 timestamp or a YYYY-MM-DD day.")
    }

    func uuid(_ key: String) throws -> UUID? {
        guard let text = string(key) else { return nil }
        guard let uuid = UUID(uuidString: text) else { throw MobileError("\(key) must be a UUID.") }
        return uuid
    }

    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = Calendar(identifier: .gregorian)
        day.timeZone = .current
        day.dateFormat = "yyyy-MM-dd"
        day.isLenient = false
        return day.date(from: text)
    }

    static func format(_ date: Date) -> String { MobileCoding.format(date) }
}

/// The shape of every mobile read result:
/// where the answer came from, when the phone collected it, and whether it is stale.
enum MobileEnvelope {
    enum Source: String { case live, cache }

    /// How old cached data can be before answers mark it stale.
    /// HealthKit wakes the app at most hourly for common types,
    /// and FinanceKit delivers changes at most hourly.
    static let staleAfter: [MobileDomain: TimeInterval] = [
        .health: 4 * 3_600,
        .finance: 26 * 3_600,
        .alarms: 3_600,
    ]

    static let emptyHealthNote =
        "No samples were found. HealthKit doesn't tell apps whether read access was denied, so this can also mean that access to this type is off in the Health app or in iMCP on the iPhone or iPad."

    static func isStale(_ domain: MobileDomain, syncedAt: Date?, now: Date) -> Bool {
        guard let syncedAt else { return true }
        return now.timeIntervalSince(syncedAt) > staleAfter[domain, default: 3_600]
    }

    static func make(
        domain: MobileDomain,
        source: Source,
        syncedAt: Date?,
        now: Date = Date(),
        results: [Value],
        note: String? = nil
    ) -> Value {
        var object: [String: Value] = [
            "source": .string(source.rawValue),
            "synced_at": syncedAt.map { .string(MobileArguments.format($0)) } ?? .null,
            "stale": .bool(source == .cache && isStale(domain, syncedAt: syncedAt, now: now)),
            "results": .array(results),
        ]
        var notes: [String] = []
        if source == .cache {
            notes.append(
                syncedAt == nil
                    ? "The iPhone or iPad hasn't sent this data to the Mac yet."
                    : "The iPhone or iPad isn't connected, so this is the data it last sent."
            )
        }
        if let note { notes.append(note) }
        if !notes.isEmpty { object["note"] = .string(notes.joined(separator: " ")) }
        return .object(object)
    }
}
