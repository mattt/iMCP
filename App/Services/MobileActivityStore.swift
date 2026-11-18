import Foundation

/// Bounded ring-buffer activity log on the Mac, persisted in Application Support.
actor MobileActivityStore {
    static let maxEvents = 500

    private struct Snapshot: Codable {
        var nextSequence: Int64
        var events: [MobileActivityEvent]
        var ackedByDevice: [String: Int64]
    }

    private let url: URL
    private let maxEvents: Int
    private var nextSequence: Int64 = 1
    private var events: [MobileActivityEvent] = []
    private var ackedByDevice: [String: Int64] = [:]

    init(url: URL, maxEvents: Int = MobileActivityStore.maxEvents) throws {
        self.url = url
        self.maxEvents = max(1, maxEvents)
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if let snapshot = try? MobileCoding.decoder.decode(Snapshot.self, from: data) {
                self.nextSequence = max(1, snapshot.nextSequence)
                self.events = Array(snapshot.events.suffix(self.maxEvents))
                self.ackedByDevice = snapshot.ackedByDevice
                if let maxSeq = self.events.map(\.sequence).max(), self.nextSequence <= maxSeq {
                    self.nextSequence = maxSeq + 1
                }
            }
        }
    }

    static func standard() throws -> MobileActivityStore {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Mobile", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try MobileActivityStore(url: directory.appendingPathComponent("activity.json"))
    }

    @discardableResult
    func record(_ event: MobileActivityEvent) -> MobileActivityEvent {
        var recorded = event
        recorded.sequence = nextSequence
        nextSequence += 1
        events.append(recorded)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        save()
        return recorded
    }

    func allEvents() -> [MobileActivityEvent] {
        events
    }

    func ackedSequence(for deviceID: String) -> Int64 {
        ackedByDevice[deviceID] ?? 0
    }

    func pendingEvents(for deviceID: String, limit: Int = 100) -> [MobileActivityEvent] {
        let floor = ackedByDevice[deviceID] ?? 0
        return Array(events.filter { $0.sequence > floor }.prefix(max(1, limit)))
    }

    func acknowledge(_ sequence: Int64, for deviceID: String) {
        let current = ackedByDevice[deviceID] ?? 0
        guard sequence > current else { return }
        ackedByDevice[deviceID] = sequence
        save()
    }

    func resetAcknowledgement(for deviceID: String) {
        guard ackedByDevice.removeValue(forKey: deviceID) != nil else { return }
        save()
    }

    func clear() {
        events.removeAll()
        save()
    }

    private func save() {
        let snapshot = Snapshot(nextSequence: nextSequence, events: events, ackedByDevice: ackedByDevice)
        guard let data = try? MobileCoding.encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
