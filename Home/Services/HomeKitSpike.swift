import Foundation
import HomeKit

/// Exercises HomeKit access before the helper is connected to iMCP.
@MainActor
final class HomeKitSpike: NSObject, ObservableObject, HMHomeManagerDelegate {
    @Published private(set) var status = "Waiting for HomeKit access…"
    private var manager: HMHomeManager?
    private var loaded = false
    private var started = false
    private var waiter: CheckedContinuation<Void, Error>?
    private var loadTimeout: Task<Void, Never>?

    func run() async {
        guard !started else { return }
        started = true
        let start = Date()
        do {
            let manager = HMHomeManager()
            self.manager = manager
            manager.delegate = self
            try await waitForHomes()
            guard manager.authorizationStatus.contains(.authorized) else {
                throw SpikeError.message(
                    "HomeKit access is denied. Check System Settings → Privacy & Security → HomeKit."
                )
            }
            let folder = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let destination = folder.appendingPathComponent("homekit-spike.json")
            let report: [String: Any] = [
                "loadedInSeconds": Date().timeIntervalSince(start),
                "authorizationStatus": manager.authorizationStatus.rawValue,
                "homes": manager.homes.map(home),
            ]
            let data = try JSONSerialization.data(
                withJSONObject: jsonValue(report),
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: destination, options: .atomic)
            print(String(decoding: data, as: UTF8.self))
            status = "Loaded \(manager.homes.count) homes. Export: \(destination.path)"

            // A specific UUID keeps repeated diagnostic launches from changing arbitrary devices.
            if let index = CommandLine.arguments.firstIndex(of: "--rename-accessory") {
                guard CommandLine.arguments.indices.contains(index + 1),
                    let id = UUID(uuidString: CommandLine.arguments[index + 1]),
                    let accessory = manager.homes.flatMap(\.accessories).first(where: {
                        $0.uniqueIdentifier == id
                    })
                else { throw SpikeError.message("Specify an existing accessory UUID after --rename-accessory.") }
                let original = accessory.name
                let recovery = folder.appendingPathComponent("rename-recovery.json")
                guard !FileManager.default.fileExists(atPath: recovery.path) else {
                    throw SpikeError.message(
                        "A previous rename test needs review. Restore the name saved in \(recovery.path), then remove that file before another test."
                    )
                }
                let recoveryData = try JSONSerialization.data(
                    withJSONObject: [
                        "accessory": id.uuidString, "originalName": original,
                    ],
                    options: [.sortedKeys]
                )
                // Preserve the original name even if the process exits during the write test.
                try recoveryData.write(to: recovery, options: .atomic)
                try await accessory.updateName(original + " Test")
                do {
                    try await accessory.updateName(original)
                    try FileManager.default.removeItem(at: recovery)
                    status += "\nRename and restore succeeded for \(id.uuidString)."
                } catch {
                    throw SpikeError.message(
                        "Restore failed for \(id.uuidString). Restore its name to '\(original)' in Home. \(error.localizedDescription)"
                    )
                }
            }
        } catch {
            status = "HomeKit check failed: \(error.localizedDescription)"
        }
        print(status)
        fflush(stdout)
    }

    private func waitForHomes() async throws {
        if loaded { return }
        try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
            loadTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.finishLoading(
                    .failure(
                        SpikeError.message(
                            "HomeKit did not load within 10 seconds. Grant access, then restart the helper."
                        )
                    )
                )
            }
        }
    }

    private func finishLoading(_ result: Result<Void, Error>) {
        loadTimeout?.cancel()
        loadTimeout = nil
        let continuation = waiter
        waiter = nil
        continuation?.resume(with: result)
    }

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor [weak self] in
            self?.loaded = true
            self?.finishLoading(.success(()))
        }
    }

    private func home(_ home: HMHome) -> [String: Any] {
        let defaultRoom = home.roomForEntireHome()
        var rooms = home.rooms
        if !rooms.contains(where: { $0.uniqueIdentifier == defaultRoom.uniqueIdentifier }) {
            rooms.append(defaultRoom)
        }
        return [
            "id": home.uniqueIdentifier.uuidString,
            "name": home.name,
            "isPrimary": home.isPrimary,
            "rooms": rooms.map { room in
                [
                    "id": room.uniqueIdentifier.uuidString, "name": room.name,
                    "isDefaultRoom": room.uniqueIdentifier == defaultRoom.uniqueIdentifier,
                    "accessories": room.accessories.map { $0.uniqueIdentifier.uuidString },
                ] as [String: Any]
            },
            "zones": home.zones.map { zone in
                [
                    "id": zone.uniqueIdentifier.uuidString, "name": zone.name,
                    "rooms": zone.rooms.map { $0.uniqueIdentifier.uuidString },
                ] as [String: Any]
            },
            "accessories": home.accessories.map(accessory),
            "scenes": home.actionSets.map { scene in
                [
                    "id": scene.uniqueIdentifier.uuidString, "name": scene.name,
                    "type": scene.actionSetType,
                    "actions": scene.actions.map { action -> [String: Any] in
                        var result: [String: Any] = [
                            "id": action.uniqueIdentifier.uuidString,
                            "kind": String(describing: type(of: action)),
                        ]
                        if let write = action as? HMCharacteristicWriteAction<NSCopying> {
                            result["characteristic"] = write.characteristic.uniqueIdentifier.uuidString
                            result["target"] = jsonValue(write.targetValue)
                        }
                        return result
                    },
                ] as [String: Any]
            },
            "automations": home.triggers.map { trigger in
                var result: [String: Any] = [
                    "id": trigger.uniqueIdentifier.uuidString, "name": trigger.name,
                    "kind": String(describing: type(of: trigger)), "isEnabled": trigger.isEnabled,
                    "scenes": trigger.actionSets.map { $0.uniqueIdentifier.uuidString },
                    // Apple deprecated lastFireDate in Mac Catalyst 17 without a replacement.
                    "lastFireDate": NSNull(),
                ]
                if let event = trigger as? HMEventTrigger {
                    result["events"] = event.events.map { String(describing: $0) }
                    result["endEvents"] = event.endEvents.map { String(describing: $0) }
                    result["predicate"] = event.predicate?.predicateFormat as Any? ?? NSNull()
                    result["recurrences"] = event.recurrences?.map { String(describing: $0) }
                }
                if let timer = trigger as? HMTimerTrigger {
                    result["fireDate"] = timer.fireDate.ISO8601Format()
                    result["recurrence"] = timer.recurrence.map { String(describing: $0) }
                }
                return result
            },
        ]
    }

    private func accessory(_ accessory: HMAccessory) -> [String: Any] {
        [
            "id": accessory.uniqueIdentifier.uuidString, "name": accessory.name,
            "room": accessory.room?.uniqueIdentifier.uuidString as Any? ?? NSNull(),
            "category": accessory.category.categoryType,
            "categoryDescription": accessory.category.localizedDescription,
            "manufacturer": accessory.manufacturer as Any? ?? NSNull(),
            "model": accessory.model as Any? ?? NSNull(),
            "firmware": accessory.firmwareVersion as Any? ?? NSNull(),
            "isReachable": accessory.isReachable, "isBridged": accessory.isBridged,
            "uniqueIdentifiersForBridgedAccessories": accessory.uniqueIdentifiersForBridgedAccessories?.map(
                \.uuidString
            ) ?? [],
            "services": accessory.services.map { service in
                [
                    "id": service.uniqueIdentifier.uuidString, "name": service.name,
                    "type": service.serviceType, "description": service.localizedDescription,
                    "characteristics": service.characteristics.map { characteristic in
                        let metadata = characteristic.metadata
                        return [
                            "id": characteristic.uniqueIdentifier.uuidString,
                            "type": characteristic.characteristicType,
                            "description": characteristic.localizedDescription,
                            "properties": characteristic.properties,
                            "metadata": [
                                "format": metadata?.format as Any? ?? NSNull(),
                                "units": metadata?.units as Any? ?? NSNull(),
                                "minimumValue": metadata?.minimumValue as Any? ?? NSNull(),
                                "maximumValue": metadata?.maximumValue as Any? ?? NSNull(),
                                "stepValue": metadata?.stepValue as Any? ?? NSNull(),
                                "validValues": metadata?.validValues as Any? ?? NSNull(),
                                "maxLength": metadata?.maxLength as Any? ?? NSNull(),
                                "manufacturerDescription": metadata?.manufacturerDescription as Any? ?? NSNull(),
                            ],
                        ] as [String: Any]
                    },
                ] as [String: Any]
            },
        ]
    }

    private func jsonValue(_ value: Any) -> Any {
        if let data = value as? Data { return data.base64EncodedString() }
        if let number = value as? NSNumber {
            return number.doubleValue.isFinite ? number : NSNull()
        }
        if let object = value as? [String: Any] { return object.mapValues(jsonValue) }
        if let array = value as? [Any] { return array.map(jsonValue) }
        if value is NSNull || value is String { return value }
        return String(describing: value)
    }
}

private enum SpikeError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}
