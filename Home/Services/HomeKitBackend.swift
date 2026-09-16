import Foundation
import HomeKit

@MainActor
final class HomeKitBackend: HomeBackend {
    let store = HomeKitStore()

    func call(_ tool: String, _ input: [String: Value]) async throws -> Value {
        do {
            try await store.ensureLoaded()
            return try await dispatch(tool, HomeArguments(input))
        } catch {
            throw HomeError(homeErrorMessage(error))
        }
    }

    private func dispatch(_ tool: String, _ args: HomeArguments) async throws -> Value {
        switch tool {
        case "homes_list":
            return .object([
                "authorizationStatus": .int(Int(store.manager?.authorizationStatus.rawValue ?? 0)),
                "homes": try Value(store.homes.map(homeSummary)),
            ])
        case "home_export":
            let home = try store.home(args.string("home"))
            let include = try args.bool("include_values") ?? false
            var accessories: [AccessoryDetail] = []
            for accessory in home.accessories {
                accessories.append(await accessoryDetail(accessory, includeValues: include))
            }
            return .object([
                "home": try Value(homeSummary(home)),
                "rooms": try Value(store.rooms(home).map { roomSummary($0, home: home) }),
                "zones": try Value(home.zones.map(zoneSummary)),
                "accessories": try Value(accessories),
                "scenes": try Value(allScenes(home).map(sceneSummary)),
                "automations": try Value(home.triggers.map(automationSummary)),
            ])
        case "rooms_list":
            let home = try store.home(args.string("home"))
            return try Value(store.rooms(home).map { roomSummary($0, home: home) })
        case "zones_list": return try Value(store.home(args.string("home")).zones.map(zoneSummary))
        case "accessories_list": return try listAccessories(args)
        case "accessories_get":
            return try await Value(
                accessoryDetail(
                    store.accessory(args.required("accessory")),
                    includeValues: args.bool("include_values") ?? false
                )
            )
        case "characteristics_read": return try Value(await readBatch(args.ids("characteristics", required: true)))
        case "scenes_list": return try Value(allScenes(store.home(args.string("home"))).map(sceneSummary))
        case "automations_list": return try Value(store.home(args.string("home")).triggers.map(automationSummary))
        case "accessories_identify":
            let accessory = try store.accessory(args.required("accessory"))
            guard accessory.supportsIdentify else { throw HomeError("The accessory does not support identification.") }
            try await accessory.identify()
            return try Value(accessorySummary(accessory))
        case "accessories_rename":
            let accessory = try store.accessory(args.required("accessory"))
            try await accessory.updateName(args.name())
            return try Value(accessorySummary(accessory))
        case "services_rename":
            let service = try store.service(args.required("service"))
            try await service.updateName(args.name())
            return try Value(serviceSummary(service))
        case "accessories_assign_room": return try await assignRoom(args)
        case "accessories_remove":
            let accessory = try store.accessory(args.required("accessory"))
            guard let home = accessory.home else { throw HomeError("The accessory has no home.") }
            try await home.removeAccessory(accessory)
            return removed(accessory.uniqueIdentifier)
        case "rooms_create":
            let home = try store.home(args.string("home"))
            return try await Value(roomSummary(home.addRoom(named: args.name()), home: home))
        case "rooms_rename":
            let (home, room) = try store.room(args.required("room"))
            try await room.updateName(args.name())
            return try Value(roomSummary(room, home: home))
        case "rooms_remove":
            let (home, room) = try store.room(args.required("room"))
            try await home.removeRoom(room)
            return removed(room.uniqueIdentifier)
        case "zones_create": return try await createZone(args)
        case "zones_update": return try await updateZone(args)
        case "zones_remove":
            let (home, zone) = try store.zone(args.required("zone"))
            try await home.removeZone(zone)
            return removed(zone.uniqueIdentifier)
        case "characteristics_write":
            let characteristic = try store.characteristic(args.required("characteristic"))
            let value = try args.value("value")
            try await characteristic.writeValue(HomeValue.decode(value, for: characteristic))
            return .object(["id": .string(characteristic.uniqueIdentifier.uuidString), "value": value])
        case "scenes_create": return try await createScene(args)
        case "scenes_update": return try await updateScene(args)
        case "scenes_execute":
            let (home, scene) = try store.actionSet(args.required("scene"))
            try await home.executeActionSet(scene)
            return try Value(sceneSummary(scene))
        case "scenes_remove":
            let (home, scene) = try store.actionSet(args.required("scene"))
            try await home.removeActionSet(scene)
            return removed(scene.uniqueIdentifier)
        case "automations_update":
            let (_, trigger) = try store.trigger(args.required("automation"))
            let name = try args.optionalName()
            let enabled = try args.bool("enabled")
            if let name { try await trigger.updateName(name) }
            if let enabled { try await trigger.enable(enabled) }
            return try Value(automationSummary(trigger))
        case "automations_remove":
            let (home, trigger) = try store.trigger(args.required("automation"))
            try await home.removeTrigger(trigger)
            return removed(trigger.uniqueIdentifier)
        case "automations_create": return try await createAutomation(args)
        default: throw HomeError("Unknown Home tool: \(tool)")
        }
    }

    private func listAccessories(_ args: HomeArguments) throws -> Value {
        let home = try store.home(args.string("home"))
        let room = try args.string("room")
        if let room { try requireSameHome(store.room(room).0, home) }
        let category = try args.string("category")
        let reachable = try args.bool("reachable")
        let bridged = try args.bool("bridged")
        let inDefault = try args.bool("in_default_room")
        let name = try args.string("name_contains")
        let accessories = home.accessories.filter { accessory in
            (room == nil || accessory.room?.uniqueIdentifier == UUID(uuidString: room!))
                && (category == nil || accessory.category.categoryType == category
                    || accessory.category.localizedDescription.localizedCaseInsensitiveCompare(category!)
                        == .orderedSame)
                && (reachable == nil || accessory.isReachable == reachable)
                && (bridged == nil || accessory.isBridged == bridged)
                && (inDefault == nil
                    || (accessory.room?.uniqueIdentifier == home.roomForEntireHome().uniqueIdentifier) == inDefault)
                && (name == nil || accessory.name.localizedCaseInsensitiveContains(name!))
        }
        return try Value(accessories.map(accessorySummary))
    }

    private func assignRoom(_ args: HomeArguments) async throws -> Value {
        let (home, room) = try store.room(args.required("room"))
        var results: [BatchResult] = []
        for id in try args.ids("accessories", required: true) {
            do {
                let accessory = try store.accessory(id)
                try requireSameHome(accessory.home, home)
                if accessory.room?.uniqueIdentifier != room.uniqueIdentifier {
                    try await home.assignAccessory(accessory, to: room)
                }
                results.append(BatchResult(id: id, ok: true))
            } catch { results.append(BatchResult(id: id, ok: false, error: homeErrorMessage(error))) }
        }
        return try Value(results)
    }

    private func createZone(_ args: HomeArguments) async throws -> Value {
        let home = try store.home(args.string("home"))
        let rooms = try args.ids("rooms").map { id -> HMRoom in
            let (owner, room) = try store.room(id)
            try requireSameHome(owner, home)
            return room
        }
        let zone = try await home.addZone(named: args.name())
        do { for room in rooms { try await zone.addRoom(room) } } catch {
            let original = error
            do { try await home.removeZone(zone) } catch {
                throw HomeError(
                    "Zone setup failed: \(homeErrorMessage(original)). Cleanup failed for zone \(zone.uniqueIdentifier): \(homeErrorMessage(error))"
                )
            }
            throw original
        }
        return try Value(zoneSummary(zone))
    }

    private func updateZone(_ args: HomeArguments) async throws -> Value {
        let (home, zone) = try store.zone(args.required("zone"))
        let name = try args.optionalName()
        func rooms(_ key: String) throws -> [HMRoom] {
            try args.ids(key).map { id in
                let (owner, room) = try store.room(id)
                try requireSameHome(owner, home)
                return room
            }
        }
        let add = try rooms("add_rooms")
        let remove = try rooms("remove_rooms")
        if let name { try await zone.updateName(name) }
        for room in remove where zone.rooms.contains(where: { $0.uniqueIdentifier == room.uniqueIdentifier }) {
            try await zone.removeRoom(room)
        }
        for room in add where !zone.rooms.contains(where: { $0.uniqueIdentifier == room.uniqueIdentifier }) {
            try await zone.addRoom(room)
        }
        return try Value(zoneSummary(zone))
    }

    private func preparedActions(_ input: [Value], home: HMHome) throws -> [(HMCharacteristic, NSCopying)] {
        var seen: Set<UUID> = []
        return try input.map { value in
            guard case .object(let object) = value else { throw HomeError("Each action must be an object.") }
            let args = HomeArguments(object)
            let characteristic = try store.characteristic(args.required("characteristic"))
            try requireSameHome(characteristic.service?.accessory?.home, home)
            guard seen.insert(characteristic.uniqueIdentifier).inserted else {
                throw HomeError("Actions must use distinct characteristic IDs.")
            }
            return (characteristic, try HomeValue.decode(args.value("value"), for: characteristic))
        }
    }

    private func createScene(_ args: HomeArguments) async throws -> Value {
        let home = try store.home(args.string("home"))
        let actions = try preparedActions(args.array("actions", required: true), home: home)
        let scene = try await home.addActionSet(named: args.name())
        do {
            for (characteristic, value) in actions {
                try await scene.addAction(
                    HMCharacteristicWriteAction(characteristic: characteristic, targetValue: value)
                )
            }
        } catch {
            let original = error
            do { try await home.removeActionSet(scene) } catch {
                throw HomeError(
                    "Scene setup failed: \(homeErrorMessage(original)). Cleanup failed for scene \(scene.uniqueIdentifier): \(homeErrorMessage(error))"
                )
            }
            throw original
        }
        return try Value(sceneSummary(scene))
    }

    private func updateScene(_ args: HomeArguments) async throws -> Value {
        let (home, scene) = try store.actionSet(args.required("scene"))
        let name = try args.optionalName()
        let actions = try preparedActions(args.array("add_actions"), home: home)
        let remove = try Set(
            args.ids("remove_characteristics").map { id -> UUID in
                let characteristic = try store.characteristic(id)
                try requireSameHome(characteristic.service?.accessory?.home, home)
                return characteristic.uniqueIdentifier
            }
        )
        if let name { try await scene.updateName(name) }
        for action in scene.actions {
            if let write = action as? HMCharacteristicWriteAction<NSCopying>,
                remove.contains(write.characteristic.uniqueIdentifier)
            {
                try await scene.removeAction(action)
            }
        }
        for (characteristic, value) in actions {
            if let existing = scene.actions.compactMap({ $0 as? HMCharacteristicWriteAction<NSCopying> }).first(where: {
                $0.characteristic.uniqueIdentifier == characteristic.uniqueIdentifier
            }) {
                try await existing.updateTargetValue(value)
            } else {
                try await scene.addAction(
                    HMCharacteristicWriteAction(characteristic: characteristic, targetValue: value)
                )
            }
        }
        return try Value(sceneSummary(scene))
    }

    private func createAutomation(_ args: HomeArguments) async throws -> Value {
        let home = try store.home(args.string("home"))
        let name = try args.name()
        let scenes = try args.ids("scenes", required: true).map { id in
            let (owner, scene) = try store.actionSet(id)
            try requireSameHome(owner, home)
            return scene
        }
        guard !scenes.isEmpty else { throw HomeError("An automation requires at least one scene.") }
        guard case .object(let object) = try args.value("trigger") else {
            throw HomeError("trigger must be an object.")
        }
        let triggerArgs = HomeArguments(object)
        let selectors = ["fire_at", "characteristic", "event"].filter { object[$0] != nil }
        guard selectors.count == 1 else {
            throw HomeError("Specify exactly one trigger kind: fire_at, characteristic, or event.")
        }
        let trigger: HMTrigger
        if let fireAt = try triggerArgs.string("fire_at") {
            guard
                let date = ISO8601DateFormatter().date(from: fireAt)
                    ?? ISO8601DateFormatter.fractional.date(from: fireAt), date > Date()
            else {
                throw HomeError("fire_at must be a future ISO 8601 timestamp with a time zone.")
            }
            guard date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0 else {
                throw HomeError(
                    "fire_at must be on a whole-minute boundary (seconds and fractional seconds must be zero)."
                )
            }
            if let recurrence = object["recurrence"], case .array(let weekdays) = recurrence {
                guard !weekdays.isEmpty else { throw HomeError("The weekday recurrence must not be empty.") }
                let days = try weekdays.map { value -> DateComponents in
                    guard case .int(let day) = value, (1 ... 7).contains(day) else {
                        throw HomeError("Weekdays must be integers from 1 (Sunday) through 7 (Saturday).")
                    }
                    return DateComponents(weekday: day)
                }
                let components = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
                // A date condition prevents a weekly event from firing before fire_at.
                trigger = HMEventTrigger(
                    name: name,
                    events: [HMCalendarEvent(fire: components)],
                    end: nil,
                    recurrences: days,
                    predicate: HMEventTrigger.predicateForEvaluatingTrigger(
                        occurringAfter: Calendar.current.dateComponents(
                            [.year, .month, .day, .hour, .minute, .second],
                            from: date
                        )
                    )
                )
            } else {
                var recurrence: DateComponents?
                if let value = object["recurrence"] {
                    guard value.stringValue == "daily" else {
                        throw HomeError("recurrence must be daily or an array of weekday numbers.")
                    }
                    recurrence = DateComponents(day: 1)
                }
                trigger = HMTimerTrigger(name: name, fireDate: date, recurrence: recurrence)
            }
        } else if let id = try triggerArgs.string("characteristic") {
            let characteristic = try store.characteristic(id)
            try requireSameHome(characteristic.service?.accessory?.home, home)
            let value = try HomeValue.decode(triggerArgs.value("value"), for: characteristic, writable: false)
            trigger = HMEventTrigger(
                name: name,
                events: [HMCharacteristicEvent(characteristic: characteristic, triggerValue: value)],
                predicate: nil
            )
        } else {
            let event = try triggerArgs.required("event")
            guard event == "sunrise" || event == "sunset" else { throw HomeError("event must be sunrise or sunset.") }
            var offset: DateComponents?
            if let value = object["offset_minutes"] {
                guard case .int(let minutes) = value else { throw HomeError("offset_minutes must be an integer.") }
                offset = DateComponents(minute: minutes)
            }
            trigger = HMEventTrigger(
                name: name,
                events: [
                    HMSignificantTimeEvent(significantEvent: event == "sunrise" ? .sunrise : .sunset, offset: offset)
                ],
                predicate: nil
            )
        }
        try await home.addTrigger(trigger)
        do {
            for scene in scenes { try await trigger.addActionSet(scene) }
            try await trigger.enable(true)
        } catch {
            let original = error
            do { try await home.removeTrigger(trigger) } catch {
                throw HomeError(
                    "Automation setup failed: \(homeErrorMessage(original)). Cleanup failed for automation \(trigger.uniqueIdentifier): \(homeErrorMessage(error))"
                )
            }
            throw original
        }
        return try Value(automationSummary(trigger))
    }

    private func requireSameHome(_ owner: HMHome?, _ home: HMHome) throws {
        guard owner?.uniqueIdentifier == home.uniqueIdentifier else {
            throw HomeError("All objects in this operation must belong to the same home.")
        }
    }
    private func removed(_ id: UUID) -> Value { .object(["id": .string(id.uuidString), "removed": .bool(true)]) }
}

private struct HomeArguments {
    let input: [String: Value]
    init(_ input: [String: Value]) { self.input = input }
    func value(_ key: String) throws -> Value {
        guard let value = input[key], !value.isNull else { throw HomeError("Missing argument: \(key)") }
        return value
    }
    func string(_ key: String) throws -> String? {
        guard let value = input[key] else { return nil }
        guard case .string(let string) = value else { throw HomeError("\(key) must be a string.") }
        return string
    }
    func required(_ key: String) throws -> String {
        guard let value = try string(key), !value.isEmpty else { throw HomeError("\(key) is required.") }
        return value
    }
    func optionalName() throws -> String? {
        guard let value = try string("name") else { return nil }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HomeError("name must not be empty.")
        }
        return value
    }
    func name() throws -> String {
        guard let name = try optionalName() else { throw HomeError("name is required.") }; return name
    }
    func bool(_ key: String) throws -> Bool? {
        guard let value = input[key] else { return nil }
        guard case .bool(let bool) = value else { throw HomeError("\(key) must be a Boolean.") }
        return bool
    }
    func array(_ key: String, required: Bool = false) throws -> [Value] {
        guard let value = input[key] else {
            if required { throw HomeError("\(key) is required.") }
            return []
        }
        guard case .array(let array) = value else { throw HomeError("\(key) must be an array.") }
        return array
    }
    func ids(_ key: String, required: Bool = false) throws -> [String] {
        try array(key, required: required).map { value in
            guard case .string(let id) = value else { throw HomeError("\(key) must contain UUID strings.") }
            return id
        }
    }
}

extension ISO8601DateFormatter {
    fileprivate static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
