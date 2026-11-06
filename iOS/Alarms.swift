import AlarmKit
import Foundation
import OSLog
import SwiftUI

/// What the app remembers about an alarm it scheduled.
/// AlarmKit returns an alarm's schedule and state but not its title.
struct AlarmLabel: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var isTimer: Bool
    var fireAt: Date?
    var hour: Int?
    var minute: Int?
    var weekdays: [Int]?
    var durationSeconds: Int?
    var createdAt: Date

    init(id: UUID, title: String, isTimer: Bool, createdAt: Date) {
        self.id = id
        self.title = title
        self.isTimer = isTimer
        self.createdAt = createdAt
    }

    init(_ request: MobileAlarmRequest, createdAt: Date = Date()) {
        id = request.id
        title = request.title
        self.createdAt = createdAt
        isTimer = false
        switch request.schedule {
        case .fixed(let date):
            fireAt = date
        case .relative(let hour, let minute, let weekdays):
            self.hour = hour
            self.minute = minute
            self.weekdays = weekdays
        case .timer(let seconds):
            isTimer = true
            durationSeconds = seconds
        }
    }

    private static let key = "alarm.labels"

    static func all() -> [UUID: AlarmLabel] {
        guard let data = MobileAppGroup.defaults.data(forKey: key),
            let labels = try? JSONDecoder().decode([AlarmLabel].self, from: data)
        else { return [:] }
        return Dictionary(labels.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    static func save(_ labels: [UUID: AlarmLabel]) {
        let sorted = labels.values.sorted { $0.createdAt < $1.createdAt }
        MobileAppGroup.defaults.set(try? JSONEncoder().encode(sorted), forKey: key)
    }
}

/// Schedules and cancels alarms and timers with AlarmKit for the Alarms tools.
///
/// AlarmKit manages only the alarms that this app creates,
/// so the tools can't see or change Clock app alarms.
/// The phone sends its list to the Mac whenever it changes,
/// so the Mac can list alarms while the phone is away.
struct AlarmsPhoneService: PhoneService {
    let domain = MobileDomain.alarms

    private static let log = Logger(subsystem: "co.dododo.iMCP.iOS", category: "alarms")
    private var manager: AlarmManager { .shared }

    /// The alarms that this app scheduled, or none if AlarmKit can't say.
    static func alarms() -> [Alarm] {
        (try? AlarmManager.shared.alarms) ?? []
    }

    // MARK: - Tools

    func call(_ tool: String, _ args: MobileArguments) async throws -> Value {
        switch tool {
        case "alarms_list":
            return MobileEnvelope.make(domain: .alarms, source: .live, syncedAt: Date(), results: Self.snapshot())
        case "alarms_create", "timers_create":
            return try await create(MobileAlarmRequest(tool: tool, args))
        case "alarms_cancel":
            return try await cancel(try args.uuid("id") ?? UUID())
        default:
            throw MobileError("Unknown Alarms tool: \(tool)")
        }
    }

    private func create(_ request: MobileAlarmRequest) async throws -> Value {
        var labels = AlarmLabel.all()
        // A retried call carries the same ID; return the alarm it already created.
        if let label = labels[request.id] {
            return Self.payload(label, alarm: Self.alarms().first { $0.id == request.id })
        }
        guard manager.authorizationState == .authorized else {
            throw MobileError(
                "iMCP isn't allowed to schedule alarms. Allow it in Settings > Apps > iMCP on the iPhone or iPad."
            )
        }
        let metadata = MobileAlarmMetadata(title: request.title, isTimer: false)
        // iOS 26.1 ignores stopButton, but the initializer without it
        // isn't in the iOS 26.0 SDK that CI also builds with.
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: request.title),
            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")
        )
        let configuration: AlarmManager.AlarmConfiguration<MobileAlarmMetadata>
        switch request.schedule {
        case .timer(let seconds):
            var timerMetadata = metadata
            timerMetadata.isTimer = true
            configuration = .timer(
                duration: TimeInterval(seconds),
                attributes: AlarmAttributes(
                    presentation: AlarmPresentation(
                        alert: alert,
                        countdown: AlarmPresentation.Countdown(
                            title: LocalizedStringResource(stringLiteral: request.title)
                        )
                    ),
                    metadata: timerMetadata,
                    tintColor: .orange
                )
            )
        case .fixed(let date):
            configuration = .alarm(
                schedule: .fixed(date),
                attributes: AlarmAttributes(
                    presentation: AlarmPresentation(alert: alert),
                    metadata: metadata,
                    tintColor: .orange
                )
            )
        case .relative(let hour, let minute, let weekdays):
            let days = weekdays.compactMap(Self.weekday)
            configuration = .alarm(
                schedule: .relative(
                    Alarm.Schedule.Relative(
                        time: .init(hour: hour, minute: minute),
                        repeats: days.isEmpty ? .never : .weekly(days)
                    )
                ),
                attributes: AlarmAttributes(
                    presentation: AlarmPresentation(alert: alert),
                    metadata: metadata,
                    tintColor: .orange
                )
            )
        }
        let alarm: Alarm
        do {
            alarm = try await manager.schedule(id: request.id, configuration: configuration)
        } catch AlarmManager.AlarmError.maximumLimitReached {
            throw MobileError("iMCP has reached AlarmKit's limit of alarms. Cancel one and try again.")
        }
        let label = AlarmLabel(request)
        labels = AlarmLabel.all()
        labels[request.id] = label
        AlarmLabel.save(labels)
        await PhoneBackend.shared.sync(.alarms)
        return Self.payload(label, alarm: alarm)
    }

    private func cancel(_ id: UUID) async throws -> Value {
        let existed = Self.alarms().contains { $0.id == id }
        if existed { try manager.cancel(id: id) }
        var labels = AlarmLabel.all()
        let label = labels.removeValue(forKey: id)
        AlarmLabel.save(labels)
        await PhoneBackend.shared.sync(.alarms)
        return .object([
            "id": .string(id.uuidString),
            "cancelled": .bool(existed),
            "title": label.map { .string($0.title) } ?? .null,
        ])
    }

    /// Cancels an alarm from the app's own list.
    static func cancelFromApp(_ id: UUID) async throws {
        _ = try await AlarmsPhoneService().cancel(id)
    }

    // MARK: - Snapshot

    /// The app's alarms, joined with their labels.
    /// Labels for alarms that AlarmKit no longer has, such as one-time alarms that ended, are dropped.
    static func snapshot() -> [Value] {
        let alarms = Self.alarms()
        var labels = AlarmLabel.all()
        let live = Set(alarms.map(\.id))
        let stale = labels.keys.filter { !live.contains($0) }
        if !stale.isEmpty {
            for id in stale { labels.removeValue(forKey: id) }
            AlarmLabel.save(labels)
        }
        return alarms.map { alarm in
            payload(labels[alarm.id] ?? fallbackLabel(alarm), alarm: alarm)
        }
    }

    /// A label for an alarm whose label is missing, such as one from an earlier install.
    private static func fallbackLabel(_ alarm: Alarm) -> AlarmLabel {
        AlarmLabel(
            id: alarm.id,
            title: "Alarm",
            isTimer: alarm.countdownDuration != nil && alarm.schedule == nil,
            createdAt: Date()
        )
    }

    static func payload(_ label: AlarmLabel, alarm: Alarm?) -> Value {
        var object: [String: Value] = [
            "id": .string(label.id.uuidString),
            "title": .string(label.title),
            "kind": .string(label.isTimer ? "timer" : "alarm"),
            "created_at": .string(MobileArguments.format(label.createdAt)),
            "state": .string(alarm.map { state($0.state) } ?? "ended"),
        ]
        if let date = label.fireAt { object["fire_at"] = .string(MobileArguments.format(date)) }
        if let hour = label.hour { object["hour"] = .int(hour) }
        if let minute = label.minute { object["minute"] = .int(minute) }
        if let weekdays = label.weekdays, !weekdays.isEmpty {
            object["weekdays"] = .array(weekdays.map { .string(MobileTools.weekdays[$0 - 1]) })
        }
        if let seconds = label.durationSeconds { object["duration_seconds"] = .int(seconds) }
        return .object(object)
    }

    private static func state(_ state: Alarm.State) -> String {
        switch state {
        case .scheduled: return "scheduled"
        case .countdown: return "countdown"
        case .paused: return "paused"
        case .alerting: return "alerting"
        @unknown default: return "unknown"
        }
    }

    private static func weekday(_ number: Int) -> Locale.Weekday? {
        switch number {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        case 7: return .saturday
        default: return nil
        }
    }

    // MARK: - PhoneService

    func status() async -> Value {
        let state: String
        switch manager.authorizationState {
        case .authorized: state = "authorized"
        case .denied: state = "denied"
        case .notDetermined: state = "notDetermined"
        @unknown default: state = "unknown"
        }
        var object: [String: Value] = ["authorization": .string(state), "alarms": .int(Self.alarms().count)]
        if manager.authorizationState == .denied {
            object["note"] = "Alarms are off for iMCP. Allow them in Settings > Apps > iMCP."
        }
        return .object(object)
    }

    func requestAuthorization() async throws {
        let state = try await manager.requestAuthorization()
        guard state == .authorized else {
            throw MobileError("Allow alarms for iMCP in Settings > Apps > iMCP.")
        }
    }

    func sync(into outbox: MobileOutbox, generation: Int) async throws {
        let records = try Self.snapshot().map { value -> MobileRecord in
            let object = value.objectValue ?? [:]
            let start =
                object["fire_at"]?.stringValue.flatMap(MobileArguments.parse)
                ?? object["created_at"]?.stringValue.flatMap(MobileArguments.parse)
            return MobileRecord(
                kind: .alarm,
                id: object["id"]?.stringValue ?? UUID().uuidString,
                key: object["kind"]?.stringValue,
                start: start,
                end: nil,
                payload: try JSONEncoder().encode(value)
            )
        }
        try await outbox.enqueue(records, syncedAt: [.alarms: Date()], replacing: [.alarm], generation: generation)
    }

    func startBackgroundDelivery() async {
        await AlarmObserver.shared.start()
    }

    func stopBackgroundDelivery() async {
        await AlarmObserver.shared.stop()
    }
}

/// Sends the alarm list to the Mac when AlarmKit reports a change,
/// such as an alarm that fired or that the user stopped.
actor AlarmObserver {
    static let shared = AlarmObserver()
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task {
            for await _ in AlarmManager.shared.alarmUpdates {
                await PhoneBackend.shared.sync(.alarms)
                await PhoneConnection.shared.flush(timeout: .seconds(5))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

// MARK: - View

/// The alarms and timers that AI apps created, with a way to cancel each.
struct AlarmListView: View {
    @State private var alarms: [Value] = []
    @State private var error: String?

    var body: some View {
        List {
            if alarms.isEmpty {
                Text("No alarms or timers.").foregroundStyle(.secondary)
            }
            ForEach(alarms.indices, id: \.self) { index in
                let object = alarms[index].objectValue ?? [:]
                VStack(alignment: .leading, spacing: 2) {
                    Text(object["title"]?.stringValue ?? "Alarm")
                    Text(detail(object)).font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Cancel", role: .destructive) {
                        guard let id = object["id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return }
                        Task {
                            do {
                                try await AlarmsPhoneService.cancelFromApp(id)
                            } catch {
                                self.error = error.localizedDescription
                            }
                            refresh()
                        }
                    }
                }
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .navigationTitle("Alarms and Timers")
        .task {
            refresh()
            for await _ in AlarmManager.shared.alarmUpdates { refresh() }
        }
    }

    private func refresh() {
        alarms = AlarmsPhoneService.snapshot()
    }

    private func detail(_ object: [String: Value]) -> String {
        var parts = [object["kind"]?.stringValue == "timer" ? "Timer" : "Alarm"]
        if let fireAt = object["fire_at"]?.stringValue.flatMap(MobileArguments.parse) {
            parts.append(fireAt.formatted(date: .abbreviated, time: .shortened))
        } else if let hour = object["hour"]?.intValue, let minute = object["minute"]?.intValue {
            parts.append(String(format: "%02d:%02d", hour, minute))
            if let days = object["weekdays"]?.arrayValue?.compactMap(\.stringValue), !days.isEmpty {
                parts.append(days.map { $0.prefix(3).capitalized }.joined(separator: ", "))
            }
        } else if let seconds = object["duration_seconds"]?.intValue {
            parts.append(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds])))
        }
        parts.append(object["state"]?.stringValue ?? "")
        return parts.joined(separator: " · ")
    }
}
