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
            // Activity context (steps / distance / calories, Morpheus-parity) + workouts
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
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
