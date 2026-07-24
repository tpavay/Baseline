import Foundation
import Observation

/// Local-first store for the athlete's `HeartRateZoneSettings` (UserDefaults-JSON, the house
/// pattern). Zone config is stored **on-device only** this slice — the strict `users/{uid}`
/// Firestore schema would reject new profile fields until a lockstep rules deploy, so Firestore
/// sync is a documented future enhancement, not here.
///
/// The store reads the profile's age through an injected closure (never coupling to Firestore or
/// `OnboardingStore` directly) so max-HR resolution and validation stay testable with a fixed age.
/// Writes are gated: only a config that validates for the current age is persisted, so the stored
/// state can never build a degenerate `HeartRateZoneModel`.
@MainActor
@Observable
final class HeartRateZoneSettingsStore {

    private(set) var settings: HeartRateZoneSettings {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private let ageYearsProvider: () -> Int?
    private enum Keys { static let settings = "heartRateZones.settings" }

    /// - Parameters:
    ///   - defaults: injectable for tests.
    ///   - ageYears: the profile's age for Tanaka fallback; `nil` → the model's 35-year fallback.
    init(defaults: UserDefaults = .standard, ageYears: @escaping () -> Int? = { nil }) {
        self.defaults = defaults
        self.ageYearsProvider = ageYears
        settings = defaults.data(forKey: Keys.settings)
            .flatMap { try? JSONDecoder().decode(HeartRateZoneSettings.self, from: $0) }
            ?? HeartRateZoneSettings()
    }

    // MARK: - Age-resolved reads

    var ageYears: Int? { ageYearsProvider() }
    var resolvedMaxHR: Int { settings.resolvedMaxHR(ageYears: ageYears) }
    var method: HeartRateZoneModel.Method { settings.method(ageYears: ageYears) }

    /// The well-formed model for the current committed config (always non-nil: stored state is
    /// validated on write).
    var model: HeartRateZoneModel? { settings.validatedModel(ageYears: ageYears) }

    /// The zone model every surface should read: the committed config's model when present, else the
    /// age-estimated Tanaka fallback. Non-optional so no caller re-implements
    /// `model ?? HeartRateZoneModel(age:)` — that duplicated fallback used to live at each ad-hoc
    /// construction site (Today, Workout) and was the seam where displayed bands could drift. Reading
    /// it through this single injected `@Observable` store is what makes a zone edit propagate
    /// reactively to every open surface.
    var resolvedModel: HeartRateZoneModel { model ?? HeartRateZoneModel(age: ageYears) }

    /// Validate a candidate config against the current age without committing it.
    func validate(_ candidate: HeartRateZoneSettings) -> HeartRateZoneSettings.ValidationError? {
        candidate.validate(ageYears: ageYears)
    }

    // MARK: - Gated write

    /// Commit a new config only if it validates for the current age. Returns whether it was accepted
    /// so callers can surface the rejection instead of silently persisting a degenerate config.
    @discardableResult
    func update(_ candidate: HeartRateZoneSettings) -> Bool {
        guard candidate.validate(ageYears: ageYears) == nil else { return false }
        settings = candidate
        return true
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Keys.settings)
        }
    }
}

extension UserDefaults {
    /// A throwaway suite for previews and hosted test harnesses, which must construct a real store to
    /// satisfy the environment but must never read or write the athlete's actual zone config.
    static var previewEmpty: UserDefaults {
        UserDefaults(suiteName: "hr-zone-preview-\(UUID().uuidString)")!
    }

    /// `previewEmpty` pre-loaded with a config, bypassing the gated write so a preview can show a
    /// state the store itself would refuse to commit.
    static func previewSeeded(_ settings: HeartRateZoneSettings) -> UserDefaults {
        let defaults = previewEmpty
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: "heartRateZones.settings")
        }
        return defaults
    }
}
