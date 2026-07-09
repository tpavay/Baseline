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

    /// Last night's sleep: total asleep hours and efficiency (asleep / in-bed). Looks back from
    /// noon yesterday to now so a morning reading captures the night just passed. Returns nil if
    /// Health is unavailable or there's no sleep sample for the window.
    func lastNightSleep() async -> (hours: Double, efficiency: Double?)? {
        guard isAvailable, let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }

        let now = Date()
        let calendar = Calendar.current
        // Window: yesterday 12:00 → now, so an early-morning reading includes last night.
        let startOfToday = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .hour, value: -12, to: startOfToday) ?? startOfToday
        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: now, options: .strictEndDate)

        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, _ in
                continuation.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
        guard !samples.isEmpty else { return nil }

        // "Asleep" = any of the asleep phases (core/deep/REM) or the legacy generic asleep value.
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let inBedValue = HKCategoryValueSleepAnalysis.inBed.rawValue

        let asleep = samples.filter { asleepValues.contains($0.value) }
            .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        guard asleep > 0 else { return nil }

        let inBed = samples.filter { $0.value == inBedValue }
            .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        let efficiency = inBed > asleep ? asleep / inBed : nil

        return (hours: asleep / 3600, efficiency: efficiency)
    }
}
