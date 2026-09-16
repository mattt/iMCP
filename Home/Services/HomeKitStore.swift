import Foundation
import HomeKit

@MainActor
final class HomeKitStore: NSObject, HMHomeManagerDelegate {
    private(set) var manager: HMHomeManager?
    private var loaded = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var activeReads: Set<UUID> = []
    private var reads: [UUID: CheckedContinuation<Value, Error>] = [:]

    var homes: [HMHome] { manager?.homes ?? [] }

    func ensureLoaded(timeout: Duration = .seconds(10)) async throws {
        if manager == nil {
            manager = HMHomeManager()
            manager?.delegate = self
        }
        try checkAuthorization()
        if !loaded {
            let id = UUID()
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.waiters.removeValue(forKey: id)?.resume(
                        throwing: HomeError(
                            "HomeKit did not load within 10 seconds. Grant HomeKit access, then retry."
                        )
                    )
                }
            }
        }
        try checkAuthorization()
        guard manager?.authorizationStatus.contains(.authorized) == true else {
            throw HomeError(
                "HomeKit access is not authorized. Enable iMCP Home in System Settings → Privacy & Security → HomeKit."
            )
        }
    }

    private func checkAuthorization() throws {
        guard let status = manager?.authorizationStatus else { return }
        if status.contains(.restricted) || (status.contains(.determined) && !status.contains(.authorized)) {
            throw HomeError(
                "HomeKit access is not authorized. Enable iMCP Home in System Settings → Privacy & Security → HomeKit."
            )
        }
    }

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            loaded = true
            let pending = waiters
            waiters.removeAll()
            for continuation in pending.values { continuation.resume() }
        }
    }

    func home(_ id: String?) throws -> HMHome {
        if let id { return try find(homes, id, id: \.uniqueIdentifier, kind: "home") }
        guard homes.count == 1, let home = homes.first else {
            throw HomeError(
                homes.isEmpty ? "No homes are available." : "Specify a home UUID when more than one home exists."
            )
        }
        return home
    }

    func accessory(_ id: String) throws -> HMAccessory {
        try find(homes.flatMap(\.accessories), id, id: \.uniqueIdentifier, kind: "accessory")
    }
    func rooms(_ home: HMHome) -> [HMRoom] {
        let all = home.roomForEntireHome()
        return home.rooms.contains(where: { $0.uniqueIdentifier == all.uniqueIdentifier })
            ? home.rooms : home.rooms + [all]
    }
    func room(_ id: String) throws -> (HMHome, HMRoom) {
        for home in homes {
            if let room = rooms(home).first(where: { $0.uniqueIdentifier == UUID(uuidString: id) }) {
                return (home, room)
            }
        }
        throw HomeError("Room not found: \(id)")
    }
    func zone(_ id: String) throws -> (HMHome, HMZone) {
        for home in homes {
            if let zone = home.zones.first(where: { $0.uniqueIdentifier == UUID(uuidString: id) }) {
                return (home, zone)
            }
        }
        throw HomeError("Zone not found: \(id)")
    }
    func service(_ id: String) throws -> HMService {
        try find(homes.flatMap(\.accessories).flatMap(\.services), id, id: \.uniqueIdentifier, kind: "service")
    }
    func characteristic(_ id: String) throws -> HMCharacteristic {
        try find(
            homes.flatMap(\.accessories).flatMap(\.services).flatMap(\.characteristics),
            id,
            id: \.uniqueIdentifier,
            kind: "characteristic"
        )
    }
    func actionSet(_ id: String) throws -> (HMHome, HMActionSet) {
        for home in homes {
            // Home app automations can own action sets absent from home.actionSets.
            let scenes = home.actionSets + home.triggers.flatMap(\.actionSets)
            if let scene = scenes.first(where: { $0.uniqueIdentifier == UUID(uuidString: id) }) { return (home, scene) }
        }
        throw HomeError("Scene not found: \(id)")
    }
    func trigger(_ id: String) throws -> (HMHome, HMTrigger) {
        for home in homes {
            if let trigger = home.triggers.first(where: { $0.uniqueIdentifier == UUID(uuidString: id) }) {
                return (home, trigger)
            }
        }
        throw HomeError("Automation not found: \(id)")
    }
    private func find<T>(_ values: [T], _ id: String, id key: KeyPath<T, UUID>, kind: String) throws -> T {
        guard let uuid = UUID(uuidString: id), let value = values.first(where: { $0[keyPath: key] == uuid }) else {
            throw HomeError("\(kind.capitalized) not found: \(id)")
        }
        return value
    }

    /// Limits outstanding HomeKit reads, including reads whose callers have timed out.
    func read(_ characteristic: HMCharacteristic) async throws -> Value {
        guard characteristic.properties.contains(HMCharacteristicPropertyReadable) else {
            throw HomeError("The characteristic is not readable.")
        }
        guard activeReads.count < 4 else {
            throw HomeError("Four HomeKit reads are still pending. Retry after the devices respond.")
        }
        let id = UUID()
        activeReads.insert(id)
        return try await withCheckedThrowingContinuation { continuation in
            reads[id] = continuation
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.reads.removeValue(forKey: id)?.resume(
                    throwing: HomeError("The characteristic read timed out after 5 seconds.")
                )
            }
            characteristic.readValue { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    timeout.cancel()
                    self.activeReads.remove(id)
                    let continuation = self.reads.removeValue(forKey: id)
                    if let error {
                        continuation?.resume(throwing: error)
                    } else {
                        continuation?.resume(returning: HomeValue.encode(characteristic.value))
                    }
                }
            }
        }
    }
}
