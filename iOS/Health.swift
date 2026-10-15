import Foundation
import HealthKit
import OSLog
import SwiftUI

/// Groups of HealthKit types that the user allows together from the app.
enum HealthGroup: String, CaseIterable, Identifiable, Sendable {
    case activity, heart, body, vitals, sleep, nutrition, workouts, records

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: return "Activity"
        case .heart: return "Heart"
        case .body: return "Body Measurements"
        case .vitals: return "Vitals"
        case .sleep: return "Sleep and Mindfulness"
        case .nutrition: return "Nutrition"
        case .workouts: return "Workouts"
        case .records: return "Health Records"
        }
    }

    var quantityTypes: [HKQuantityTypeIdentifier] {
        switch self {
        case .activity:
            return [
                .stepCount, .distanceWalkingRunning, .distanceCycling, .activeEnergyBurned, .basalEnergyBurned,
                .flightsClimbed, .appleExerciseTime, .appleStandTime,
            ]
        case .heart:
            return [.heartRate, .restingHeartRate, .walkingHeartRateAverage, .heartRateVariabilitySDNN]
        case .body:
            return [.bodyMass, .bodyMassIndex, .bodyFatPercentage, .height, .leanBodyMass]
        case .vitals:
            return [
                .oxygenSaturation, .respiratoryRate, .bloodPressureSystolic, .bloodPressureDiastolic,
                .bodyTemperature, .bloodGlucose,
            ]
        case .nutrition:
            return [
                .dietaryEnergyConsumed, .dietaryWater, .dietaryProtein, .dietaryCarbohydrates, .dietaryFatTotal,
                .dietaryCaffeine,
            ]
        case .sleep, .workouts, .records: return []
        }
    }

    var categoryTypes: [HKCategoryTypeIdentifier] {
        self == .sleep ? [.sleepAnalysis, .mindfulSession] : []
    }

    var clinicalTypes: [HKClinicalTypeIdentifier] {
        guard self == .records else { return [] }
        return MobileTools.clinicalTypes.map {
            HKClinicalTypeIdentifier(rawValue: "HKClinicalTypeIdentifier" + $0.capitalizedFirst)
        }
    }

    var objectTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        types.formUnion(quantityTypes.map { HKQuantityType($0) })
        types.formUnion(categoryTypes.map { HKCategoryType($0) })
        types.formUnion(clinicalTypes.compactMap { HKObjectType.clinicalType(forIdentifier: $0) })
        if self == .workouts { types.insert(HKObjectType.workoutType()) }
        return types
    }

    /// Groups the user has asked iOS for, which are the ones the app syncs.
    static var requested: Set<HealthGroup> {
        get {
            Set((MobileAppGroup.defaults.stringArray(forKey: "health.groups") ?? []).compactMap(HealthGroup.init))
        }
        set { MobileAppGroup.defaults.set(newValue.map(\.rawValue).sorted(), forKey: "health.groups") }
    }
}

/// Reads HealthKit for the Health tools and queues changes for the Mac.
///
/// HealthKit hides whether read access was denied, so an empty result is a valid answer.
/// Quantity types sync as daily statistics for two years, because raw heart rate
/// and step samples can number in the millions; their raw samples are available live.
/// Category samples, workouts, and health records sync in full.
/// Each type keeps a persisted anchor, so a sync sends only new and deleted objects.
struct HealthPhoneService: PhoneService {
    let domain = MobileDomain.health

    private static let store = HKHealthStore()
    private static let log = Logger(subsystem: "co.dododo.iMCP.iOS", category: "health")
    private static let statisticsYears = 2
    private static let pageSize = 5_000

    private var store: HKHealthStore { Self.store }

    // MARK: - Tools

    func call(_ tool: String, _ args: MobileArguments) async throws -> Value {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw MobileError("HealthKit isn't available on this device.")
        }
        do {
            switch tool {
            case "health_fetch": return try await fetch(args)
            case "health_statistics": return try await statistics(args)
            case "workouts_fetch": return try await workouts(args)
            case "clinical_records_fetch": return try await clinicalRecords(args)
            default: throw MobileError("Unknown Health tool: \(tool)")
            }
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            throw MobileError(MobileTools.lockedMessage)
        }
    }

    private func envelope(_ results: [Value], note: String? = nil) -> Value {
        MobileEnvelope.make(
            domain: .health,
            source: .live,
            syncedAt: Date(),
            results: results,
            note: results.isEmpty
                ? [MobileEnvelope.emptyHealthNote, note].compactMap { $0 }.joined(separator: " ") : note
        )
    }

    private func dateRange(_ args: MobileArguments) throws -> NSPredicate? {
        let start = try args.date("start")
        let end = try args.date("end")
        guard start != nil || end != nil else { return nil }
        return HKQuery.predicateForSamples(withStart: start, end: end, options: [])
    }

    private func fetch(_ args: MobileArguments) async throws -> Value {
        let name = MobileTools.healthTypeName(try args.required("type"))
        let order: SortOrder = args.bool("ascending") == true ? .forward : .reverse
        let predicate = try dateRange(args)
        let limit = args.limit()
        if let type = Self.quantityType(name) {
            let unit = try await unit(for: type)
            let samples = try await HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: type, predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate, order: order)],
                limit: limit
            ).result(for: store)
            return envelope(samples.map { Self.payload($0, name: name, unit: unit) })
        }
        if let type = Self.categoryType(name) {
            let samples = try await HKSampleQueryDescriptor(
                predicates: [.categorySample(type: type, predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate, order: order)],
                limit: limit
            ).result(for: store)
            return envelope(samples.map { Self.payload($0, name: name) })
        }
        throw MobileError(
            "\(name) isn't a HealthKit quantity or category type. Use names such as stepCount, heartRate, or sleepAnalysis."
        )
    }

    private func statistics(_ args: MobileArguments) async throws -> Value {
        let name = MobileTools.healthTypeName(try args.required("type"))
        guard let type = Self.quantityType(name) else {
            throw MobileError("\(name) isn't a HealthKit quantity type, so it has no statistics.")
        }
        let end = try args.date("end") ?? Date()
        let start = try args.date("start") ?? end.addingTimeInterval(-MobileTools.defaultStatisticsWindow)
        let interval = args.string("interval") ?? "day"
        let calendar = Calendar.current
        var components = DateComponents()
        var anchor = calendar.startOfDay(for: start)
        switch interval {
        case "hour":
            components.hour = 1
            anchor = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        case "week":
            components.day = 7
            anchor = calendar.dateInterval(of: .weekOfYear, for: start)?.start ?? anchor
        case "month":
            components.month = 1
            anchor = calendar.dateInterval(of: .month, for: start)?.start ?? anchor
        default:
            components.day = 1
        }
        let unit = try await unit(for: type)
        let results = try await Self.statistics(
            type: type,
            name: name,
            unit: unit,
            from: anchor,
            to: end,
            interval: components,
            store: store
        )
        return envelope(results.map(\.payload))
    }

    private func workouts(_ args: MobileArguments) async throws -> Value {
        var predicates = [try dateRange(args)].compactMap { $0 }
        if let name = args.string("activity_type") {
            guard let type = WorkoutActivity.type(named: MobileTools.healthTypeName(name)) else {
                throw MobileError("\(name) isn't a workout activity type, such as running or cycling.")
            }
            predicates.append(HKQuery.predicateForWorkouts(with: type))
        }
        let workouts = try await HKSampleQueryDescriptor(
            predicates: [
                .workout(predicates.isEmpty ? nil : NSCompoundPredicate(andPredicateWithSubpredicates: predicates))
            ],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: args.limit()
        ).result(for: store)
        return envelope(workouts.map(Self.payload))
    }

    private func clinicalRecords(_ args: MobileArguments) async throws -> Value {
        guard store.supportsHealthRecords() else {
            throw MobileError("This device doesn't support health records.")
        }
        let names = args.string("type").map { [$0] } ?? MobileTools.clinicalTypes
        let predicate = try dateRange(args)
        let limit = args.limit()
        var records: [HKClinicalRecord] = []
        for name in names {
            guard let type = Self.clinicalType(name) else { continue }
            records += try await HKSampleQueryDescriptor(
                predicates: [.clinicalRecord(type: type, predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
                limit: limit
            ).result(for: store)
        }
        records.sort { $0.startDate > $1.startDate }
        return envelope(records.prefix(limit).map(Self.payload))
    }

    // MARK: - Status and authorization

    func status() async -> Value {
        let groups = HealthGroup.requested
        var object: [String: Value] = [
            "available": .bool(HKHealthStore.isHealthDataAvailable()),
            "requested_groups": .array(HealthGroup.allCases.filter(groups.contains).map { .string($0.rawValue) }),
            "health_records_supported": .bool(HKHealthStore.isHealthDataAvailable() && store.supportsHealthRecords()),
        ]
        if groups.isEmpty {
            object["note"] = "Choose which Health data to share in Health Data Access."
        }
        return .object(object)
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw MobileError("HealthKit isn't available on this device.")
        }
    }

    /// Shows the HealthKit permission sheet for one group.
    func requestAccess(to group: HealthGroup) async throws {
        try await store.requestAuthorization(toShare: [], read: group.objectTypes)
        HealthGroup.requested.insert(group)
        await startBackgroundDelivery()
    }

    // MARK: - Background delivery

    private var syncedTypes: [HKSampleType] {
        HealthGroup.requested.flatMap { group in
            group.objectTypes.compactMap { $0 as? HKSampleType }
        }
    }

    func startBackgroundDelivery() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        await HealthObservers.shared.start(types: syncedTypes, store: store)
    }

    func stopBackgroundDelivery() async {
        await HealthObservers.shared.stop(store: store)
    }

    // MARK: - Sync

    func sync(into outbox: MobileOutbox, generation: Int) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let groups = HealthGroup.requested
        do {
            for group in HealthGroup.allCases where groups.contains(group) {
                for identifier in group.quantityTypes {
                    try await syncStatistics(HKQuantityType(identifier), into: outbox, generation: generation)
                }
                for identifier in group.categoryTypes {
                    let type = HKCategoryType(identifier)
                    let name = MobileTools.healthTypeName(identifier.rawValue)
                    try await syncSamples(
                        .categorySample(type: type),
                        anchorKey: "health.anchor.\(name)",
                        kind: .healthSample,
                        into: outbox,
                        generation: generation
                    ) { sample in
                        MobileRecord(
                            kind: .healthSample,
                            id: sample.uuid.uuidString,
                            key: name,
                            start: sample.startDate,
                            end: sample.endDate,
                            payload: try? Self.data(Self.payload(sample, name: name))
                        )
                    }
                }
                if group == .workouts {
                    try await syncSamples(
                        .workout(),
                        anchorKey: "health.anchor.workouts",
                        kind: .workout,
                        into: outbox,
                        generation: generation
                    ) { workout in
                        MobileRecord(
                            kind: .workout,
                            id: workout.uuid.uuidString,
                            key: WorkoutActivity.name(of: workout.workoutActivityType),
                            start: workout.startDate,
                            end: workout.endDate,
                            payload: try? Self.data(Self.payload(workout))
                        )
                    }
                }
                if group == .records, store.supportsHealthRecords() {
                    for name in MobileTools.clinicalTypes {
                        guard let type = Self.clinicalType(name) else { continue }
                        try await syncSamples(
                            .clinicalRecord(type: type),
                            anchorKey: "health.anchor.\(name)",
                            kind: .clinicalRecord,
                            into: outbox,
                            generation: generation
                        ) { record in
                            MobileRecord(
                                kind: .clinicalRecord,
                                id: record.uuid.uuidString,
                                key: name,
                                start: record.startDate,
                                end: record.endDate,
                                payload: try? Self.data(Self.payload(record))
                            )
                        }
                    }
                }
            }
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            // The store is encrypted while the phone is locked; the next unlock syncs.
            Self.log.notice("HealthKit is locked; sync waits for the next unlock")
            return
        }
        try await outbox.enqueue([], syncedAt: [.health: Date()], generation: generation)
    }

    /// Queues added and deleted objects since the type's anchor, a page at a time,
    /// saving each page's anchor with its records.
    private func syncSamples<Sample: HKSample>(
        _ predicate: HKSamplePredicate<Sample>,
        anchorKey: String,
        kind: MobileKind,
        into outbox: MobileOutbox,
        generation: Int,
        record: (Sample) -> MobileRecord
    ) async throws {
        var anchor = await outbox.state(anchorKey).flatMap(Self.anchor)
        while true {
            let result = try await HKAnchoredObjectQueryDescriptor(
                predicates: [predicate],
                anchor: anchor,
                limit: Self.pageSize
            ).result(for: store)
            let records =
                result.addedSamples.map(record)
                + result.deletedObjects.map { MobileRecord.deletion(kind: kind, id: $0.uuid.uuidString) }
            try await outbox.enqueue(
                records,
                syncedAt: [:],
                state: [anchorKey: Self.archive(result.newAnchor)],
                generation: generation
            )
            anchor = result.newAnchor
            if result.addedSamples.count + result.deletedObjects.count < Self.pageSize { break }
        }
    }

    /// Recomputes the daily statistics that new or deleted samples could change.
    ///
    /// The first sync computes every day of the last two years.
    /// Later syncs read the anchored changes to find the days with new samples.
    /// A deleted sample carries no date, so a deletion recomputes every day.
    private func syncStatistics(_ type: HKQuantityType, into outbox: MobileOutbox, generation: Int) async throws {
        let name = MobileTools.healthTypeName(type.identifier)
        let anchorKey = "health.anchor.\(name)"
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let earliest = calendar.date(byAdding: .year, value: -Self.statisticsYears, to: today) ?? today
        var anchor = await outbox.state(anchorKey).flatMap(Self.anchor)
        var days = Set<Date>()
        var everyDay = anchor == nil
        let window = HKQuery.predicateForSamples(withStart: earliest, end: nil, options: [])
        if everyDay {
            // Start the anchor at the store's current position without reading every sample.
            anchor =
                try await HKAnchoredObjectQueryDescriptor(
                    predicates: [
                        .quantitySample(
                            type: type,
                            predicate: HKQuery.predicateForSamples(withStart: .distantFuture, end: nil, options: [])
                        )
                    ],
                    anchor: nil,
                    limit: 1
                ).result(for: store).newAnchor
        } else {
            while true {
                let result = try await HKAnchoredObjectQueryDescriptor(
                    predicates: [.quantitySample(type: type, predicate: window)],
                    anchor: anchor,
                    limit: Self.pageSize * 4
                ).result(for: store)
                anchor = result.newAnchor
                if !result.deletedObjects.isEmpty { everyDay = true }
                if !everyDay {
                    for sample in result.addedSamples {
                        var day = calendar.startOfDay(for: max(sample.startDate, earliest))
                        while day <= sample.endDate {
                            days.insert(day)
                            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                            day = next
                        }
                    }
                }
                if result.addedSamples.count + result.deletedObjects.count < Self.pageSize * 4 { break }
            }
        }
        guard everyDay || !days.isEmpty else {
            if let anchor { try await outbox.setState(anchorKey, Self.archive(anchor), generation: generation) }
            return
        }
        let from = everyDay ? earliest : (days.min() ?? today)
        let unit = try await unit(for: type)
        let buckets = try await Self.statistics(
            type: type,
            name: name,
            unit: unit,
            from: from,
            to: Date(),
            interval: DateComponents(day: 1),
            store: store,
            includeEmpty: true
        )
        let records = buckets.compactMap { bucket -> MobileRecord? in
            let id = "\(name)|\(Self.dayFormatter.string(from: bucket.start))"
            if !everyDay, !days.contains(bucket.start) { return nil }
            guard bucket.hasData else { return MobileRecord.deletion(kind: .healthStatistic, id: id) }
            return MobileRecord(
                kind: .healthStatistic,
                id: id,
                key: name,
                start: bucket.start,
                end: bucket.end,
                payload: try? Self.data(bucket.payload)
            )
        }
        try await outbox.enqueue(
            records,
            syncedAt: [:],
            state: [anchorKey: anchor.flatMap(Self.archive)],
            generation: generation
        )
    }

    // MARK: - Statistics

    struct Bucket {
        let start: Date
        let end: Date
        let hasData: Bool
        let payload: Value
    }

    private static func statistics(
        type: HKQuantityType,
        name: String,
        unit: HKUnit,
        from start: Date,
        to end: Date,
        interval: DateComponents,
        store: HKHealthStore,
        includeEmpty: Bool = false
    ) async throws -> [Bucket] {
        let cumulative = type.aggregationStyle == .cumulative
        let collection = try await HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: start, end: end)),
            options: cumulative ? .cumulativeSum : [.discreteAverage, .discreteMin, .discreteMax],
            anchorDate: start,
            intervalComponents: interval
        ).result(for: store)
        var buckets: [Bucket] = []
        collection.enumerateStatistics(from: start, to: end) { statistics, _ in
            var object: [String: Value] = [
                "type": .string(name),
                "start": .string(MobileArguments.format(statistics.startDate)),
                "end": .string(MobileArguments.format(statistics.endDate)),
                "unit": .string(unit.unitString),
            ]
            if cumulative {
                if let sum = statistics.sumQuantity() { object["sum"] = .double(sum.doubleValue(for: unit)) }
            } else {
                if let value = statistics.averageQuantity() {
                    object["average"] = .double(value.doubleValue(for: unit))
                }
                if let value = statistics.minimumQuantity() {
                    object["minimum"] = .double(value.doubleValue(for: unit))
                }
                if let value = statistics.maximumQuantity() {
                    object["maximum"] = .double(value.doubleValue(for: unit))
                }
            }
            let hasData = object.count > 4
            if hasData || includeEmpty {
                buckets.append(
                    Bucket(
                        start: statistics.startDate,
                        end: statistics.endDate,
                        hasData: hasData,
                        payload: .object(object)
                    )
                )
            }
        }
        return buckets
    }

    // MARK: - Types and units

    static func quantityType(_ name: String) -> HKQuantityType? {
        HKObjectType.quantityType(
            forIdentifier: HKQuantityTypeIdentifier(rawValue: "HKQuantityTypeIdentifier" + name.capitalizedFirst)
        )
    }

    static func categoryType(_ name: String) -> HKCategoryType? {
        HKObjectType.categoryType(
            forIdentifier: HKCategoryTypeIdentifier(rawValue: "HKCategoryTypeIdentifier" + name.capitalizedFirst)
        )
    }

    static func clinicalType(_ name: String) -> HKClinicalType? {
        HKObjectType.clinicalType(
            forIdentifier: HKClinicalTypeIdentifier(rawValue: "HKClinicalTypeIdentifier" + name.capitalizedFirst)
        )
    }

    private func unit(for type: HKQuantityType) async throws -> HKUnit {
        if let unit = try await store.preferredUnits(for: [type])[type] { return unit }
        throw MobileError("HealthKit has no unit for \(type.identifier).")
    }

    // MARK: - Payloads

    private static func payload(_ sample: HKQuantitySample, name: String, unit: HKUnit) -> Value {
        var object = common(sample, name: name)
        object["value"] = .double(sample.quantity.doubleValue(for: unit))
        object["unit"] = .string(unit.unitString)
        return .object(object)
    }

    private static func payload(_ sample: HKCategorySample, name: String) -> Value {
        var object = common(sample, name: name)
        object["value"] = .int(sample.value)
        if sample.categoryType.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue {
            object["value_name"] = .string(sleepStage(sample.value))
        }
        return .object(object)
    }

    private static func payload(_ workout: HKWorkout) -> Value {
        var object = common(workout, name: "workout")
        object["activity_type"] = .string(WorkoutActivity.name(of: workout.workoutActivityType))
        object["duration_seconds"] = .double(workout.duration)
        if let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() {
            object["energy_kcal"] = .double(energy.doubleValue(for: .kilocalorie()))
        }
        let distances: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceDownhillSnowSports,
        ]
        for identifier in distances {
            if let distance = workout.statistics(for: HKQuantityType(identifier))?.sumQuantity() {
                object["distance_m"] = .double(distance.doubleValue(for: .meter()))
                break
            }
        }
        return .object(object)
    }

    private static func payload(_ record: HKClinicalRecord) -> Value {
        var object = common(record, name: MobileTools.healthTypeName(record.clinicalType.identifier))
        object["display_name"] = .string(record.displayName)
        if let resource = record.fhirResource {
            object["fhir_version"] = .string(resource.fhirVersion.stringRepresentation)
            object["fhir_resource_type"] = .string(resource.resourceType.rawValue)
            object["fhir"] = (try? JSONDecoder().decode(Value.self, from: resource.data)) ?? .null
        }
        return .object(object)
    }

    private static func common(_ sample: HKSample, name: String) -> [String: Value] {
        var object: [String: Value] = [
            "id": .string(sample.uuid.uuidString),
            "type": .string(name),
            "start": .string(MobileArguments.format(sample.startDate)),
            "end": .string(MobileArguments.format(sample.endDate)),
            "source": .string(sample.sourceRevision.source.name),
        ]
        if let device = sample.device?.name { object["device"] = .string(device) }
        return object
    }

    private static func sleepStage(_ value: Int) -> String {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .inBed: return "inBed"
        case .asleepUnspecified: return "asleepUnspecified"
        case .awake: return "awake"
        case .asleepCore: return "asleepCore"
        case .asleepDeep: return "asleepDeep"
        case .asleepREM: return "asleepREM"
        default: return "unknown"
        }
    }

    // MARK: - Encoding

    private static func data(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func archive(_ anchor: HKQueryAnchor) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    private static func anchor(_ data: Data) -> HKQueryAnchor? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// Observer queries that wake the app when HealthKit has new data.
actor HealthObservers {
    static let shared = HealthObservers()
    private var queries: [String: HKObserverQuery] = [:]
    private let log = Logger(subsystem: "co.dododo.iMCP.iOS", category: "health")

    func start(types: [HKSampleType], store: HKHealthStore) async {
        for type in types where queries[type.identifier] == nil {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else {
                    completion()
                    return
                }
                Task {
                    // Concurrent wakes share one sync; HealthKit needs only the changes queued.
                    await PhoneBackend.shared.sync(.health)
                    completion()
                    await PhoneConnection.shared.flushInBackground()
                }
            }
            queries[type.identifier] = query
            store.execute(query)
            do {
                // iOS limits most types to hourly delivery whatever the requested frequency.
                try await store.enableBackgroundDelivery(for: type, frequency: .hourly)
            } catch {
                log.error(
                    "Background delivery for \(type.identifier, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func stop(store: HKHealthStore) async {
        for query in queries.values { store.stop(query) }
        queries.removeAll()
        try? await store.disableAllBackgroundDelivery()
    }
}

/// Names for HKWorkoutActivityType, which has no string form.
enum WorkoutActivity {
    private static let names: [HKWorkoutActivityType: String] = [
        .americanFootball: "americanFootball", .archery: "archery", .australianFootball: "australianFootball",
        .badminton: "badminton", .baseball: "baseball", .basketball: "basketball", .bowling: "bowling",
        .boxing: "boxing", .climbing: "climbing", .cricket: "cricket", .crossTraining: "crossTraining",
        .curling: "curling", .cycling: "cycling", .elliptical: "elliptical", .equestrianSports: "equestrianSports",
        .fencing: "fencing", .fishing: "fishing", .functionalStrengthTraining: "functionalStrengthTraining",
        .golf: "golf", .gymnastics: "gymnastics", .handball: "handball", .hiking: "hiking", .hockey: "hockey",
        .hunting: "hunting", .lacrosse: "lacrosse", .martialArts: "martialArts", .mindAndBody: "mindAndBody",
        .paddleSports: "paddleSports", .play: "play", .preparationAndRecovery: "preparationAndRecovery",
        .racquetball: "racquetball", .rowing: "rowing", .rugby: "rugby", .running: "running", .sailing: "sailing",
        .skatingSports: "skatingSports", .snowSports: "snowSports", .soccer: "soccer", .softball: "softball",
        .squash: "squash", .stairClimbing: "stairClimbing", .surfingSports: "surfingSports", .swimming: "swimming",
        .tableTennis: "tableTennis", .tennis: "tennis", .trackAndField: "trackAndField",
        .traditionalStrengthTraining: "traditionalStrengthTraining", .volleyball: "volleyball", .walking: "walking",
        .waterFitness: "waterFitness", .waterPolo: "waterPolo", .waterSports: "waterSports", .wrestling: "wrestling",
        .yoga: "yoga", .barre: "barre", .coreTraining: "coreTraining", .crossCountrySkiing: "crossCountrySkiing",
        .downhillSkiing: "downhillSkiing", .flexibility: "flexibility",
        .highIntensityIntervalTraining: "highIntensityIntervalTraining", .jumpRope: "jumpRope",
        .kickboxing: "kickboxing", .pilates: "pilates", .snowboarding: "snowboarding", .stairs: "stairs",
        .stepTraining: "stepTraining", .wheelchairWalkPace: "wheelchairWalkPace",
        .wheelchairRunPace: "wheelchairRunPace", .taiChi: "taiChi", .mixedCardio: "mixedCardio",
        .handCycling: "handCycling", .discSports: "discSports", .fitnessGaming: "fitnessGaming",
        .cardioDance: "cardioDance", .socialDance: "socialDance", .pickleball: "pickleball",
        .cooldown: "cooldown", .swimBikeRun: "swimBikeRun", .transition: "transition",
        .underwaterDiving: "underwaterDiving", .other: "other",
    ]

    static func name(of type: HKWorkoutActivityType) -> String {
        names[type] ?? "activity\(type.rawValue)"
    }

    static func type(named name: String) -> HKWorkoutActivityType? {
        names.first { $0.value == name }?.key
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

// MARK: - View

/// Lets the user allow each group of Health data on demand.
struct HealthAccessView: View {
    @State private var requested = HealthGroup.requested
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(HealthGroup.allCases) { group in
                    HStack {
                        Text(group.title)
                        Spacer()
                        Button(requested.contains(group) ? "Review" : "Allow") {
                            Task { await request(group) }
                        }
                    }
                }
            } footer: {
                Text(
                    "iOS doesn't tell apps which types you deny, so iMCP can't show what's off. To change access later, open Settings > Health > Data Access & Devices > iMCP."
                )
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .navigationTitle("Health Data Access")
    }

    private func request(_ group: HealthGroup) async {
        do {
            try await HealthPhoneService().requestAccess(to: group)
            requested = HealthGroup.requested
            error = nil
            await PhoneBackend.shared.sync(.health)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
