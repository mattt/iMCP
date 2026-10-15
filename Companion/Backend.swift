import Foundation
import JSONSchema
import MCP
import OSLog

/// One of the frameworks that iMCP Companion serves: HealthKit, FinanceKit, or AlarmKit.
protocol PhoneService: Sendable {
    var domain: CompanionDomain { get }
    /// Answers a tool call with live data.
    func call(_ tool: String, _ args: CompanionArguments) async throws -> Value
    /// Permissions and availability, for `companion_status` and the app's screen.
    func status() async -> Value
    /// Asks for the permissions the service needs.
    func requestAuthorization() async throws
    /// Queues changes since the last sync, or everything after a reset.
    /// Every write passes `generation`, so a sync that a reset overtakes stops
    /// with `CompanionOutbox.Superseded` instead of queuing changes from its stale anchors.
    func sync(into outbox: CompanionOutbox, generation: Int) async throws
    /// Registers for background delivery of changes, if the framework offers it.
    func startBackgroundDelivery() async
    /// Stops background delivery when the user turns the service off.
    func stopBackgroundDelivery() async
}

extension CompanionDomain {
    var title: String {
        switch self {
        case .health: return "Health"
        case .finance: return "Finance"
        case .alarms: return "Alarms"
        }
    }

    /// What turning the service on shares, in the words the app shows.
    var disclosure: String {
        switch self {
        case .health:
            return
                "Sends the Health data you allow to iMCP on your Mac. Any AI app that you approve in iMCP can read it while Health is on in iMCP."
        case .finance:
            return
                "Sends the Wallet accounts, balances, and transactions you allow to iMCP on your Mac. Any AI app that you approve in iMCP can read them while Finance is on in iMCP."
        case .alarms:
            return
                "Lets AI apps that you approve in iMCP set alarms and timers on this iPhone. They sound even in silent mode and Focus, and you can cancel them here."
        }
    }
}

/// Which services the user turned on in the app.
/// All of them start off.
enum PhoneSettings {
    static func isEnabled(_ domain: CompanionDomain) -> Bool {
        CompanionAppGroup.defaults.bool(forKey: "service.\(domain.rawValue)")
    }

    static func setEnabled(_ domain: CompanionDomain, _ enabled: Bool) {
        CompanionAppGroup.defaults.set(enabled, forKey: "service.\(domain.rawValue)")
    }

    static func lastSync(_ domain: CompanionDomain) -> Date? {
        CompanionAppGroup.defaults.object(forKey: "lastSync.\(domain.rawValue)") as? Date
    }

    static func setLastSync(_ domain: CompanionDomain, _ date: Date) {
        CompanionAppGroup.defaults.set(date, forKey: "lastSync.\(domain.rawValue)")
    }
}

/// Serves the companion tools on the iPhone.
actor PhoneBackend: CompanionBackend {
    static let shared = PhoneBackend()

    private let log = Logger(subsystem: "co.dododo.iMCP.Companion", category: "backend")
    nonisolated let services: [CompanionDomain: any PhoneService] = [
        .health: HealthPhoneService(),
        .finance: FinancePhoneService(),
        .alarms: AlarmsPhoneService(),
    ]
    private var outbox: CompanionOutbox?
    /// Syncs in progress, and domains that changed again while one ran.
    private var running: [CompanionDomain: Task<Void, Never>] = [:]
    private var dirty = Set<CompanionDomain>()

    func openOutbox() throws -> CompanionOutbox {
        if let outbox { return outbox }
        let outbox = try CompanionOutbox.shared()
        self.outbox = outbox
        return outbox
    }

    /// The tools that the Mac can call: the shared tools and the sync tools.
    nonisolated var tools: [Tool] {
        CompanionTools.all(backend: self) + [
            Tool(
                name: CompanionLink.pullTool,
                description: "Return the oldest queued batch of changes for the Mac's cache.",
                inputSchema: .object(
                    properties: ["cache": .string()],
                    required: ["cache"],
                    additionalProperties: false
                ),
                annotations: .init(readOnlyHint: false, openWorldHint: false)
            ) { input in
                try await self.pull(cacheID: input["cache"]?.stringValue ?? "")
            },
            Tool(
                name: CompanionLink.ackTool,
                description: "Drop queued batches that the Mac has stored.",
                inputSchema: .object(
                    properties: ["sequence": .integer(minimum: 1)],
                    required: ["sequence"],
                    additionalProperties: false
                ),
                annotations: .init(readOnlyHint: false, openWorldHint: false)
            ) { input in
                try await self.ack(Int64(input["sequence"]?.intValue ?? 0))
            },
        ]
    }

    func call(_ tool: String, _ input: [String: Value]) async throws -> Value {
        if tool == CompanionTools.statusTool { return await status() }
        guard let domain = CompanionTools.domain(of: tool), let service = services[domain] else {
            throw CompanionError("Unknown companion tool: \(tool)")
        }
        // Without the entitlement, Finance can't be turned on, so give the reason instead.
        if domain == .finance, let reason = FinanceCapability.current.reason {
            throw CompanionError(reason)
        }
        guard PhoneSettings.isEnabled(domain) else {
            throw CompanionError(
                "\(domain.title) is off in iMCP Companion on the iPhone. Turn it on there to use \(tool)."
            )
        }
        return try await service.call(tool, CompanionArguments(input))
    }

    // MARK: - Sync

    private func pull(cacheID: String) async throws -> Value {
        let pull = try await openOutbox().pull(cacheID: cacheID)
        if pull.reset {
            log.notice("The Mac's cache changed; sending all data again")
            Task { await self.syncAll() }
        }
        return try JSONDecoder().decode(Value.self, from: CompanionCoding.encoder.encode(pull.batch))
    }

    private func ack(_ sequence: Int64) async throws -> Value {
        try await openOutbox().ack(sequence)
        return ["ok": true]
    }

    /// Queues changes from every service that is on.
    func syncAll() async {
        for domain in CompanionDomain.allCases where PhoneSettings.isEnabled(domain) {
            await sync(domain)
        }
    }

    /// Queues one service's changes.
    /// Calls that arrive while its sync runs wait for one more run instead of starting another,
    /// so a burst of HealthKit wakes reads each anchor once.
    func sync(_ domain: CompanionDomain) async {
        guard PhoneSettings.isEnabled(domain), let service = services[domain] else { return }
        if let task = running[domain] {
            dirty.insert(domain)
            await task.value
            return
        }
        let task = Task {
            repeat {
                dirty.remove(domain)
                await run(service)
            } while dirty.contains(domain)
            running[domain] = nil
        }
        running[domain] = task
        await task.value
    }

    private func run(_ service: any PhoneService) async {
        guard let outbox = try? openOutbox() else { return }
        do {
            try await service.sync(into: outbox, generation: await outbox.generation)
            PhoneSettings.setLastSync(service.domain, Date())
        } catch is CompanionOutbox.Superseded {
            // The Mac's cache was reset during this sync; start over from no anchors.
            dirty.insert(service.domain)
        } catch {
            log.error(
                "\(service.domain.title, privacy: .public) sync failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func startBackgroundDelivery() async {
        for domain in CompanionDomain.allCases where PhoneSettings.isEnabled(domain) {
            await services[domain]?.startBackgroundDelivery()
        }
    }

    /// Turns a service on or off.
    /// Turning one off stops its background delivery but keeps what the Mac has;
    /// the user deletes that in iMCP on the Mac.
    func setEnabled(_ domain: CompanionDomain, _ enabled: Bool) async throws {
        guard let service = services[domain] else { return }
        if enabled {
            try await service.requestAuthorization()
            PhoneSettings.setEnabled(domain, true)
            await service.startBackgroundDelivery()
            await sync(domain)
        } else {
            PhoneSettings.setEnabled(domain, false)
            await service.stopBackgroundDelivery()
        }
    }

    var pendingBatches: Int {
        get async { (try? await openOutbox().pendingCount) ?? 0 }
    }

    // MARK: - Status

    func status() async -> Value {
        var services: [String: Value] = [:]
        for domain in CompanionDomain.allCases {
            var object: [String: Value] = ["enabled": .bool(PhoneSettings.isEnabled(domain))]
            if let service = self.services[domain], case .object(let details) = await service.status() {
                object.merge(details) { _, new in new }
            }
            if let date = PhoneSettings.lastSync(domain) {
                object["last_queued"] = .string(CompanionArguments.format(date))
            }
            services[domain.rawValue] = .object(object)
        }
        return .object([
            "app_version": .string(Bundle.main.shortVersionString ?? "unknown"),
            "queued_batches": .int(await pendingBatches),
            "services": .object(services),
        ])
    }
}
