import Foundation
import HomeKit

extension HomeKitBackend {
    func homeSummary(_ home: HMHome) -> HomeSummary {
        HomeSummary(
            id: home.uniqueIdentifier.uuidString,
            name: home.name,
            isPrimary: home.isPrimary,
            rooms: store.rooms(home).count,
            zones: home.zones.count,
            accessories: home.accessories.count,
            scenes: allScenes(home).count,
            automations: home.triggers.count
        )
    }
    func roomSummary(_ room: HMRoom, home: HMHome) -> RoomSummary {
        RoomSummary(
            id: room.uniqueIdentifier.uuidString,
            name: room.name,
            accessoryCount: room.accessories.count,
            isDefaultRoom: room.uniqueIdentifier == home.roomForEntireHome().uniqueIdentifier
        )
    }
    func zoneSummary(_ zone: HMZone) -> ZoneSummary {
        ZoneSummary(
            id: zone.uniqueIdentifier.uuidString,
            name: zone.name,
            rooms: zone.rooms.map { $0.uniqueIdentifier.uuidString }
        )
    }
    func serviceSummary(_ service: HMService) -> ServiceSummary {
        ServiceSummary(
            id: service.uniqueIdentifier.uuidString,
            name: service.name,
            type: service.serviceType,
            description: service.localizedDescription
        )
    }
    func accessorySummary(_ accessory: HMAccessory) -> AccessorySummary {
        let bridge = accessory.home?.accessories.first {
            $0.uniqueIdentifiersForBridgedAccessories?.contains(accessory.uniqueIdentifier) == true
        }
        return AccessorySummary(
            id: accessory.uniqueIdentifier.uuidString,
            name: accessory.name,
            home: accessory.home?.uniqueIdentifier.uuidString,
            room: accessory.room?.uniqueIdentifier.uuidString,
            category: accessory.category.categoryType,
            categoryDescription: accessory.category.localizedDescription,
            manufacturer: accessory.manufacturer,
            model: accessory.model,
            firmware: accessory.firmwareVersion,
            isReachable: accessory.isReachable,
            isBridged: accessory.isBridged,
            bridgedBy: bridge?.uniqueIdentifier.uuidString,
            services: accessory.services.map(serviceSummary)
        )
    }
    func accessoryDetail(_ accessory: HMAccessory, includeValues: Bool) async -> AccessoryDetail {
        var values: [String: BatchResult] = [:]
        if includeValues {
            let ids = accessory.services.flatMap(\.characteristics).map { $0.uniqueIdentifier.uuidString }
            for row in await readBatch(ids) { values[row.id] = row }
        }
        let services = accessory.services.map { service in
            ServiceDetail(
                service: serviceSummary(service),
                characteristics: service.characteristics.map { characteristic in
                    let metadata = characteristic.metadata
                    let row = values[characteristic.uniqueIdentifier.uuidString]
                    return CharacteristicDetail(
                        id: characteristic.uniqueIdentifier.uuidString,
                        type: characteristic.characteristicType,
                        description: characteristic.localizedDescription,
                        properties: characteristic.properties,
                        metadata: [
                            "format": HomeValue.encode(metadata?.format), "units": HomeValue.encode(metadata?.units),
                            "minimumValue": HomeValue.encode(metadata?.minimumValue),
                            "maximumValue": HomeValue.encode(metadata?.maximumValue),
                            "stepValue": HomeValue.encode(metadata?.stepValue),
                            "validValues": HomeValue.encode(metadata?.validValues),
                            "maxLength": HomeValue.encode(metadata?.maxLength),
                            "manufacturerDescription": HomeValue.encode(metadata?.manufacturerDescription),
                        ],
                        value: row?.value,
                        error: row?.error
                    )
                }
            )
        }
        return AccessoryDetail(
            accessory: accessorySummary(accessory),
            uniqueIdentifiersForBridgedAccessories: accessory.uniqueIdentifiersForBridgedAccessories?.map(\.uuidString)
                ?? [],
            services: services
        )
    }
    func readBatch(_ ids: [String]) async -> [BatchResult] {
        var rows: [BatchResult] = []
        // Each chunk preserves request order while permitting four concurrent reads.
        for start in stride(from: 0, to: ids.count, by: 4) {
            let chunk = Array(ids[start ..< min(start + 4, ids.count)])
            let results = await withTaskGroup(of: (Int, BatchResult).self) { group in
                for (index, id) in chunk.enumerated() {
                    group.addTask { @MainActor in
                        do {
                            let value = try await self.store.read(self.store.characteristic(id))
                            return (index, BatchResult(id: id, ok: true, value: value))
                        } catch { return (index, BatchResult(id: id, ok: false, error: homeErrorMessage(error))) }
                    }
                }
                var result: [(Int, BatchResult)] = []
                for await row in group { result.append(row) }
                return result.sorted { $0.0 < $1.0 }.map(\.1)
            }
            rows += results
        }
        return rows
    }
    func allScenes(_ home: HMHome) -> [HMActionSet] {
        var seen: Set<UUID> = []
        return (home.actionSets + home.triggers.flatMap(\.actionSets)).filter {
            seen.insert($0.uniqueIdentifier).inserted
        }
    }
    func sceneSummary(_ scene: HMActionSet) -> SceneSummary {
        SceneSummary(
            id: scene.uniqueIdentifier.uuidString,
            name: scene.name,
            type: scene.actionSetType,
            actions: scene.actions.map { action in
                var object: [String: Value] = [
                    "id": .string(action.uniqueIdentifier.uuidString),
                    "kind": .string(String(describing: type(of: action))),
                ]
                if let write = action as? HMCharacteristicWriteAction<NSCopying> {
                    object["characteristic"] = .string(write.characteristic.uniqueIdentifier.uuidString)
                    object["service"] = HomeValue.encode(write.characteristic.service?.uniqueIdentifier.uuidString)
                    object["accessory"] = HomeValue.encode(
                        write.characteristic.service?.accessory?.uniqueIdentifier.uuidString
                    )
                    object["accessoryName"] = HomeValue.encode(write.characteristic.service?.accessory?.name)
                    object["target"] = HomeValue.encode(write.targetValue)
                } else {
                    object["supported"] = .bool(false)
                }
                return .object(object)
            }
        )
    }
    func automationSummary(_ trigger: HMTrigger) -> AutomationSummary {
        var details: [String: Value] = [:]
        if let timer = trigger as? HMTimerTrigger {
            details["fire_at"] = .string(timer.fireDate.ISO8601Format())
            details["recurrence"] = timer.recurrence.map(dateComponents) ?? .null
        }
        if let event = trigger as? HMEventTrigger {
            details["events"] = .array(event.events.map(eventSummary))
            details["endEvents"] = .array(event.endEvents.map(eventSummary))
            details["predicate"] = HomeValue.encode(event.predicate?.predicateFormat)
            details["recurrences"] = event.recurrences.map { .array($0.map(dateComponents)) } ?? .null
            details["executeOnce"] = .bool(event.executeOnce)
        }
        return AutomationSummary(
            id: trigger.uniqueIdentifier.uuidString,
            name: trigger.name,
            kind: trigger is HMTimerTrigger
                ? "timer" : trigger is HMEventTrigger ? "event" : String(describing: type(of: trigger)),
            isEnabled: trigger.isEnabled,
            scenes: trigger.actionSets.map { $0.uniqueIdentifier.uuidString },
            details: details
        )
    }
    private func dateComponents(_ components: DateComponents) -> Value {
        var result: [String: Value] = [:]
        for (name, number) in [
            ("year", components.year), ("month", components.month), ("day", components.day),
            ("hour", components.hour), ("minute", components.minute), ("second", components.second),
            ("weekday", components.weekday),
        ] {
            if let number { result[name] = .int(number) }
        }
        if let zone = components.timeZone { result["timeZone"] = .string(zone.identifier) }
        return .object(result)
    }
    private func eventSummary(_ event: HMEvent) -> Value {
        var result: [String: Value] = [
            "id": .string(event.uniqueIdentifier.uuidString), "kind": .string(String(describing: type(of: event))),
        ]
        if let characteristic = event as? HMCharacteristicEvent<NSCopying> {
            result["characteristic"] = .string(characteristic.characteristic.uniqueIdentifier.uuidString)
            result["value"] = HomeValue.encode(characteristic.triggerValue)
        } else if let time = event as? HMSignificantTimeEvent {
            result["event"] = .string(time.significantEvent.rawValue)
            result["offset"] = time.offset.map(dateComponents) ?? .null
        } else if let calendar = event as? HMCalendarEvent {
            result["fireDateComponents"] = dateComponents(calendar.fireDateComponents)
        } else {
            result["supported"] = .bool(false)
            result["description"] = .string(String(describing: event))
        }
        return .object(result)
    }
}
