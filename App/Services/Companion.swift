import Foundation
import OSLog

/// Serves the Health, Finance, and Alarms tools from iMCP Companion on the iPhone.
///
/// HealthKit, FinanceKit, and AlarmKit data stays on the phone,
/// so the companion app implements the tools from `CompanionTools`.
/// When the phone is connected, calls go to it live;
/// otherwise read-only calls answer from `CompanionCache`,
/// the copy of the data that the phone last sent,
/// and every answer says when that was.
actor CompanionService: CompanionBackend {
    static let shared = CompanionService()

    private let log = Logger.service("companion")
    private var cache: CompanionCache?
    private let reconnectGrace: Duration

    init(cache: CompanionCache? = nil, reconnectGrace: Duration = .seconds(5)) {
        self.cache = cache
        self.reconnectGrace = reconnectGrace
    }

    func start() async throws {
        _ = try openCache()
    }

    var isStarted: Bool { cache != nil }

    private func openCache() throws -> CompanionCache {
        if let cache { return cache }
        let cache = try CompanionCache.standard()
        self.cache = cache
        return cache
    }

    // MARK: - CompanionBackend

    func call(_ tool: String, _ input: [String: Value]) async throws -> Value {
        guard let definition = CompanionTools.all(backend: self).first(where: { $0.name == tool }) else {
            throw CompanionError("Unknown companion tool: \(tool)")
        }
        try ToolInput.validate(input, schema: definition.inputSchema)
        if tool == CompanionTools.statusTool { return try await status() }
        return try await cached(tool, CompanionArguments(input))
    }

    // MARK: - Cache

    private func cached(_ tool: String, _ args: CompanionArguments) async throws -> Value {
        guard let domain = CompanionTools.domain(of: tool) else {
            throw CompanionError("Unknown companion tool: \(tool)")
        }
        let cache = try openCache()
        let start = try args.date("start")
        let end = try args.date("end")
        let limit = args.limit()
        var note: String?
        let rows: [CompanionCache.Row]
        switch tool {
        case "health_fetch":
            let type = CompanionTools.healthTypeName(try args.required("type"))
            rows = try await cache.records(
                .healthSample,
                key: type,
                start: start,
                end: end,
                limit: limit,
                ascending: args.bool("ascending") ?? false
            )
            if rows.isEmpty {
                note =
                    "\(CompanionEnvelope.emptyHealthNote) The Mac keeps category samples, such as sleep, but not raw quantity samples, such as heart rate; use health_statistics for daily values."
            }
        case "health_statistics":
            let type = CompanionTools.healthTypeName(try args.required("type"))
            let interval = args.string("interval") ?? "day"
            guard interval == "day" else {
                throw CompanionError(
                    "The Mac keeps daily statistics only. Use interval day, or open iMCP Companion on the iPhone for \(interval) buckets."
                )
            }
            rows = try await cache.records(
                .healthStatistic,
                key: type,
                start: start ?? (end ?? Date()).addingTimeInterval(-CompanionTools.defaultStatisticsWindow),
                end: end,
                limit: 1000,
                ascending: true
            )
            if rows.isEmpty { note = CompanionEnvelope.emptyHealthNote }
        case "workouts_fetch":
            rows = try await cache.records(
                .workout,
                key: args.string("activity_type").map(CompanionTools.healthTypeName),
                start: start,
                end: end,
                limit: limit
            )
            if rows.isEmpty { note = CompanionEnvelope.emptyHealthNote }
        case "clinical_records_fetch":
            rows = try await cache.records(
                .clinicalRecord,
                key: args.string("type"),
                start: start,
                end: end,
                limit: limit
            )
            if rows.isEmpty { note = CompanionEnvelope.emptyHealthNote }
        case "finance_accounts_list":
            rows = try await cache.records(.account, ascending: true)
        case "finance_balances_fetch":
            rows = try await cache.records(
                .balance,
                key: try args.uuid("account")?.uuidString,
                start: start,
                end: end,
                limit: limit
            )
        case "finance_transactions_fetch":
            let status = args.string("status")
            let query = args.string("query")?.lowercased()
            let candidates = try await cache.records(
                .transaction,
                key: try args.uuid("account")?.uuidString,
                start: start,
                end: end,
                limit: status == nil && query == nil ? limit : nil
            )
            rows = Array(
                candidates.filter { row in
                    let object = row.payload.objectValue ?? [:]
                    if let status, object["status"]?.stringValue != status { return false }
                    if let query {
                        let text = [object["merchant_name"], object["description"]]
                            .compactMap { $0?.stringValue?.lowercased() }
                        if !text.contains(where: { $0.contains(query) }) { return false }
                    }
                    return true
                }
                .prefix(limit)
            )
        case "alarms_list":
            rows = try await cache.records(.alarm, ascending: true)
        default:
            throw CompanionError(
                "\(tool) needs iMCP Companion to be open on the iPhone and connected to this Mac."
            )
        }
        return CompanionEnvelope.make(
            domain: domain,
            source: .cache,
            syncedAt: await cache.syncedAt(domain),
            results: rows.map(\.payload),
            note: note
        )
    }

    // MARK: - Status

    private func status() async throws -> Value {
        let cache = try openCache()
        var services: [String: Value] = [:]
        for domain in CompanionDomain.allCases {
            let syncedAt = await cache.syncedAt(domain)
            var count = 0
            for kind in CompanionKind.allCases where kind.domain == domain {
                count += await cache.count(kind)
            }
            services[domain.rawValue] = .object([
                "synced_at": syncedAt.map { .string(CompanionArguments.format($0)) } ?? .null,
                "stale": .bool(CompanionEnvelope.isStale(domain, syncedAt: syncedAt, now: Date())),
                "cached_records": .int(count),
            ])
        }
        return .object([
            "connected": false,
            "services": .object(services),
        ])
    }
}

/// Health data from the paired iPhone's HealthKit store.
struct HealthService: Service {
    static let shared = HealthService()
    var tools: [Tool] { return CompanionTools.tools(for: .health, backend: CompanionService.shared) }
    var isActivated: Bool { get async { await CompanionService.shared.isStarted } }
    func activate() async throws { try await CompanionService.shared.start() }
}

/// Apple Card, Apple Cash, and Apple Savings data from the paired iPhone's Wallet.
struct FinanceService: Service {
    static let shared = FinanceService()
    var tools: [Tool] { return CompanionTools.tools(for: .finance, backend: CompanionService.shared) }
    var isActivated: Bool { get async { await CompanionService.shared.isStarted } }
    func activate() async throws { try await CompanionService.shared.start() }
}

/// Alarms and timers that iMCP Companion schedules with AlarmKit on the paired iPhone.
struct AlarmsService: Service {
    static let shared = AlarmsService()
    var tools: [Tool] { return CompanionTools.tools(for: .alarms, backend: CompanionService.shared) }
    var isActivated: Bool { get async { await CompanionService.shared.isStarted } }
    func activate() async throws { try await CompanionService.shared.start() }
}
