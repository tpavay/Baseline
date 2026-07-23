import Foundation

// MARK: - Health boundary

/// Authorization state for writing body mass to Apple Health, collapsed to what the weight step
/// needs. Unlike reads, write (sharing) status is knowable: Health reports sharing denial.
enum BodyMassAuthorization: Equatable, Sendable {
    /// HealthKit does not exist on this device (iPad) - entry still works, nothing is written.
    case unavailable
    case notDetermined
    case denied
    case authorized
}

/// One body-mass write, expressed without HealthKit types so the recording logic is testable
/// without a live `HKHealthStore`. `syncIdentifier`/`syncVersion` are HealthKit's built-in
/// replace-don't-duplicate mechanism: a later save with the same identifier and a higher version
/// replaces the earlier sample instead of adding a second one.
struct BodyMassSaveRequest: Equatable, Sendable {
    let kilograms: Double
    let date: Date
    let syncIdentifier: String
    let syncVersion: Int
    /// Provenance: the athlete typed this number - it must never look machine-measured.
    let wasUserEntered: Bool
}

/// The slice of Apple Health the morning weight step touches - body mass only, nothing broader.
/// `HealthService` is the one live conformer (the same store the sleep reads use); tests
/// substitute a fake.
@MainActor
protocol BodyMassHealthStore: AnyObject {
    var bodyMassAuthorization: BodyMassAuthorization { get }
    /// Present the Health permission sheet for body mass only (share + read for the prefill).
    func requestBodyMassAuthorization() async
    /// Most recent body-mass sample in Health, in kilograms - nil when unauthorized or absent.
    func latestBodyMassKilograms() async -> Double?
    func saveBodyMass(_ request: BodyMassSaveRequest) async throws
}

// MARK: - Validation

enum MorningWeightPolicy {
    /// Accepted entry range, canonical kilograms (≈66–660 lb): wide enough for any athlete,
    /// narrow enough to reject an obvious typo. Firestore's profile validation caps higher, at
    /// 500 kg, so every accepted entry also satisfies the remote write.
    static let kilogramRange: ClosedRange<Double> = 30...300

    static func isValid(kilograms: Double) -> Bool {
        kilograms.isFinite && kilogramRange.contains(kilograms)
    }
}

// MARK: - Recorder

/// Records the optional morning weight entry: caches it locally (prefill fallback), then writes
/// exactly one body-mass sample per check-in day to Apple Health.
///
/// Duplicate resistance is two layers deep: the recorder skips the write entirely when the same
/// value was already written for the same day (a retry), and every write carries a per-day
/// `syncIdentifier` so a changed value *replaces* the day's sample in Health rather than adding
/// a second one - even if the local bookkeeping was lost.
@MainActor
final class MorningWeightRecorder {

    enum Outcome: Equatable, Sendable {
        case savedToHealth
        /// The same value is already in Health for this day - a retry writes nothing.
        case alreadySaved
        case healthDenied
        case healthUnavailable
        case healthError
    }

    private let health: BodyMassHealthStore
    private let defaults: UserDefaults
    private let calendar: Calendar

    private enum Keys {
        static let lastEntered = "checkin.weight.lastEnteredKilograms"
        static let lastSyncIdentifier = "checkin.weight.lastSyncIdentifier"
        static let lastSyncVersion = "checkin.weight.lastSyncVersion"
        static let lastSaved = "checkin.weight.lastSavedKilograms"
    }

    init(health: BodyMassHealthStore, defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.health = health
        self.defaults = defaults
        self.calendar = calendar
    }

    /// Prefill for the entry field: the most recent weight Health knows (from any app), else the
    /// last value entered here, else the caller's fallback (the profile weight), else nothing.
    /// A prefill is a suggestion the athlete confirms - never a value Baseline records on its own.
    func prefillKilograms(fallback: Double? = nil) async -> Double? {
        if let fromHealth = await health.latestBodyMassKilograms() { return fromHealth }
        if let cached = defaults.object(forKey: Keys.lastEntered) as? Double { return cached }
        return fallback
    }

    /// Record `kilograms` for the check-in on `date`. The entry is cached locally first - a
    /// Health denial never loses the number - then the Health write is attempted. Authorization
    /// is requested here, the moment the athlete chooses to save, never earlier.
    func record(kilograms: Double, on date: Date) async -> Outcome {
        defaults.set(kilograms, forKey: Keys.lastEntered)

        switch health.bodyMassAuthorization {
        case .unavailable:
            return .healthUnavailable
        case .denied:
            return .healthDenied
        case .notDetermined:
            await health.requestBodyMassAuthorization()
            guard health.bodyMassAuthorization == .authorized else { return .healthDenied }
        case .authorized:
            break
        }

        let identifier = Self.syncIdentifier(for: date, calendar: calendar)
        let sameDay = defaults.string(forKey: Keys.lastSyncIdentifier) == identifier
        if sameDay, defaults.object(forKey: Keys.lastSaved) as? Double == kilograms {
            return .alreadySaved
        }
        let request = BodyMassSaveRequest(
            kilograms: kilograms,
            date: date,
            syncIdentifier: identifier,
            syncVersion: sameDay ? defaults.integer(forKey: Keys.lastSyncVersion) + 1 : 1,
            wasUserEntered: true
        )
        do {
            try await health.saveBodyMass(request)
        } catch {
            return .healthError
        }
        defaults.set(request.syncIdentifier, forKey: Keys.lastSyncIdentifier)
        defaults.set(request.syncVersion, forKey: Keys.lastSyncVersion)
        defaults.set(kilograms, forKey: Keys.lastSaved)
        return .savedToHealth
    }

    /// Stable per-day identity for the morning entry, so Health replaces rather than duplicates.
    /// Calendar day in the athlete's calendar; the format is fixed and locale-independent.
    static func syncIdentifier(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "com.tylerpavay.Baseline.morning-weight.%04d-%02d-%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
