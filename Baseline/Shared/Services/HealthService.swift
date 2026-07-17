import Foundation
import HealthKit
import Observation

/// Minimal Apple Health facade for onboarding: request read access to the recovery inputs
/// (sleep, resting HR, HRV history for baseline seeding) plus the characteristics that power
/// HR zones (date of birth, biological sex). Read-only per project rules — Baseline never
/// writes to Health. Deeper history import lives with the readiness engine, not here.
@MainActor
@Observable
final class HealthService {

    private(set) var requested: Bool
    private(set) var isAvailable = HKHealthStore.isHealthDataAvailable()

    private let store = HKHealthStore()
    private let defaults: UserDefaults
    private static let requestedKey = "health.readAccessRequested"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        requested = defaults.bool(forKey: Self.requestedKey)
    }

    /// Everything the recovery + activity context needs. HRV history (SDNN from wearables) is
    /// deliberately NOT requested: it's a different metric from a different modality than our
    /// R-R readings, and we don't consume it yet — ask when the seeding logic exists.
    private var readTypes: Set<HKObjectType> {
        [
            // Recovery inputs
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
            HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            // Activity context (steps / distance / calories / exercise minutes) + workouts
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKObjectType.quantityType(forIdentifier: .appleExerciseTime)!,
            HKObjectType.workoutType(),
            // Characteristics that power HR zones (age → max-HR estimate) and cold-start norms
            HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!,
            HKObjectType.characteristicType(forIdentifier: .biologicalSex)!,
        ]
    }

    /// Show the Health permission sheet. Health never reveals what was granted for reads —
    /// we only record that we asked.
    func requestReadAccess() async {
        guard isAvailable else { return }
        try? await store.requestAuthorization(toShare: [], read: readTypes)
        requested = true
        defaults.set(true, forKey: Self.requestedKey)
    }

    /// Age from Health's date of birth, if the athlete granted it. Used to seed HR zones.
    var age: Int? {
        guard let dob = try? store.dateOfBirthComponents().date else { return nil }
        return Calendar.current.dateComponents([.year], from: dob, to: .now).year
    }

    var biologicalSex: HKBiologicalSex? {
        try? store.biologicalSex().biologicalSex
    }

    /// Raw Apple Health sleep for one night — hours asleep, per-stage breakdown, and efficiency.
    /// These are Apple's numbers; any "sleep score" is Baseline's own derivation, not from Health.
    struct SleepSummary: Sendable {
        let hours: Double
        let deepHours: Double?
        let remHours: Double?
        let coreHours: Double?
        let efficiency: Double?
    }

    /// Sleep for the night ending on the morning `nightsAgo` days back (0 = last night). Window is
    /// that day's noon-to-noon straddle so an overnight sleep lands in one bucket. Returns nil when
    /// Health is unavailable or no sample exists for the window — the caller reports "none recorded",
    /// never infers absence from elsewhere.
    func sleepSummary(nightsAgo: Int = 0) async -> SleepSummary? {
        guard isAvailable, let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }

        let now = Date()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        guard let dayStart = calendar.date(byAdding: .day, value: -max(0, nightsAgo), to: startOfToday) else { return nil }
        let windowStart = calendar.date(byAdding: .hour, value: -12, to: dayStart) ?? dayStart
        let windowEnd = min(now, calendar.date(byAdding: .hour, value: 12, to: dayStart) ?? now)
        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd, options: .strictEndDate)

        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, _ in
                continuation.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
        guard !samples.isEmpty else { return nil }

        func hoursOf(_ value: HKCategoryValueSleepAnalysis) -> Double {
            samples.filter { $0.value == value.rawValue }
                .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) } / 3600
        }
        let deep = hoursOf(.asleepDeep), rem = hoursOf(.asleepREM), core = hoursOf(.asleepCore)
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM,
        ].map(\.rawValue).reduce(into: Set<Int>()) { $0.insert($1) }
        let asleep = samples.filter { asleepValues.contains($0.value) }
            .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) } / 3600
        guard asleep > 0 else { return nil }

        let inBed = samples.filter { $0.value == HKCategoryValueSleepAnalysis.inBed.rawValue }
            .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) } / 3600
        return SleepSummary(
            hours: asleep,
            deepHours: deep > 0 ? deep : nil,
            remHours: rem > 0 ? rem : nil,
            coreHours: core > 0 ? core : nil,
            efficiency: inBed > asleep ? asleep / inBed : nil
        )
    }

    /// Last night's asleep hours + efficiency, for the daily readiness pipeline.
    func lastNightSleep() async -> (hours: Double, efficiency: Double?)? {
        guard let s = await sleepSummary(nightsAgo: 0) else { return nil }
        return (s.hours, s.efficiency)
    }

    /// Active energy (kcal) and Apple exercise minutes for the day `daysAgo` back (1 = yesterday).
    /// Returns nil when Health is unavailable or that day recorded no activity at all — the caller
    /// then shows no activity tile rather than a misleading zero.
    func activitySummary(daysAgo: Int = 1) async -> (activeEnergyKcal: Double, exerciseMinutes: Double)? {
        guard isAvailable else { return nil }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let dayStart = calendar.date(byAdding: .day, value: -max(0, daysAgo), to: startOfToday),
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: dayStart, end: dayEnd, options: .strictStartDate)

        // Sequential (not `async let`): both hop through this main-actor method, so the non-Sendable
        // predicate never crosses an isolation boundary. Two quick statistics reads — order is cheap.
        let kcal = await cumulativeSum(.activeEnergyBurned, unit: .kilocalorie(), predicate: predicate)
        let minutes = await cumulativeSum(.appleExerciseTime, unit: .minute(), predicate: predicate)
        guard (kcal ?? 0) > 0 || (minutes ?? 0) > 0 else { return nil }
        return (kcal ?? 0, minutes ?? 0)
    }

    /// Cumulative sum of a quantity type over a predicate window, in `unit`, or nil if unavailable.
    private func cumulativeSum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, predicate: NSPredicate) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, stats, _ in
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    /// Recent resting heart-rate samples from Apple Health, newest first (typically one per day).
    func restingHeartRate(days: Int = 7) async -> [(date: Date, bpm: Double)] {
        guard isAvailable, let type = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else { return [] }
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -max(1, days), to: now) ?? now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictEndDate)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        let samples: [HKQuantitySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, results, _ in
                continuation.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }
        let unit = HKUnit.count().unitDivided(by: .minute())
        return samples.map { (date: $0.endDate, bpm: $0.quantity.doubleValue(for: unit)) }
    }
}

// MARK: - Sleep ingestion (Sleep Engine Slice 1)

/// The raw-sample path for `SleepIngestionEngine`. Lives in this file because it needs the
/// private `store`; kept deliberately thin — every decision (precedence, segmentation,
/// lifecycle) happens in the pure engine, reachable by tests without HealthKit.
extension HealthService: SleepSampleProviding {

    /// Raw sleep samples in a window with the detail `sleepSummary` discards: interval
    /// timestamps, stage, and per-sample source provenance — plus the count of raw samples the
    /// mapping rejected (`@unknown default`), so data loss is a visible number, never logged
    /// values. Empty when Health is unavailable or access was denied — HealthKit reports read
    /// denial as no data, never as an error we should surface.
    func sleepSamples(in window: DateInterval) async -> SleepSampleBatch {
        guard isAvailable, let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            return SleepSampleBatch(samples: [])
        }
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: .strictEndDate)
        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, _ in
                continuation.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
        let mapped = samples.compactMap(SleepSample.init(healthKitSample:))
        return SleepSampleBatch(samples: mapped, droppedUnknownCount: samples.count - mapped.count)
    }

    /// New and deleted sleep samples since the opaque cursor (an archived `HKQueryAnchor` — it
    /// never leaves this method), bounded to samples starting at or after `start` so a nil
    /// cursor can never replay the athlete's entire Health sleep history. A failed or
    /// unauthorized query returns no samples and leaves the caller's cursor where it was, so no
    /// delta is ever silently skipped.
    func sleepSampleDelta(after cursor: Data?, startingFrom start: Date) async -> SleepSampleDelta {
        guard isAvailable, let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            return SleepSampleDelta(samples: [], cursor: cursor)
        }
        let anchor = cursor.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: [])
        let (added, deleted, newAnchor): ([HKCategorySample], [UUID], HKQueryAnchor?) = await withCheckedContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor, limit: HKObjectQueryNoLimit) { _, samples, deletedObjects, newAnchor, _ in
                continuation.resume(returning: (
                    (samples as? [HKCategorySample]) ?? [],
                    (deletedObjects ?? []).map(\.uuid),
                    newAnchor
                ))
            }
            store.execute(query)
        }
        let newCursor = newAnchor.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        let mapped = added.compactMap(SleepSample.init(healthKitSample:))
        return SleepSampleDelta(
            samples: mapped,
            deletedSampleUUIDs: deleted,
            cursor: newCursor ?? cursor,
            droppedUnknownCount: added.count - mapped.count
        )
    }
}

private extension SleepSample {
    /// HK → engine-input mapping, kept here so HealthKit types never leak into the pure sleep module.
    init?(healthKitSample sample: HKCategorySample) {
        let kind: SleepSample.Kind
        switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
        case .inBed: kind = .inBed
        case .asleepUnspecified: kind = .asleepUnspecified
        case .awake: kind = .awake
        case .asleepCore: kind = .core
        case .asleepDeep: kind = .deep
        case .asleepREM: kind = .rem
        case .none: return nil
        @unknown default: return nil
        }
        self.init(
            uuid: sample.uuid,
            start: sample.startDate,
            end: sample.endDate,
            kind: kind,
            sourceBundleID: sample.sourceRevision.source.bundleIdentifier,
            deviceModel: sample.device?.model,
            isUserEntered: (sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool) ?? false
        )
    }
}
