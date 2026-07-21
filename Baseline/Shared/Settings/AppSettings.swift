import Foundation
import Observation

/// App-wide user preferences, persisted in UserDefaults. Injected via the environment so both
/// views and the cue engine can read them.
@MainActor
@Observable
final class AppSettings {
    var livePreviewEnabled: Bool { didSet { defaults.set(livePreviewEnabled, forKey: Keys.livePreview) } }
    var readingPosition: BodyPosition { didSet { defaults.set(readingPosition.rawValue, forKey: Keys.position) } }
    /// Morning reading length in whole seconds (1:00–5:59). Clamped on set.
    var morningReadingDurationSeconds: Int {
        didSet {
            let clamped = min(max(morningReadingDurationSeconds, ReadingLength.range.lowerBound), ReadingLength.range.upperBound)
            if clamped != morningReadingDurationSeconds { morningReadingDurationSeconds = clamped; return }
            defaults.set(morningReadingDurationSeconds, forKey: Keys.morningDuration)
        }
    }
    /// The athlete's global imperial/metric default, seeding every exercise-metric and body input's
    /// display unit. **The only place this value is stored** — every display surface reads it back
    /// through `UnitSystemSource` rather than keeping a copy that could go stale.
    var unitSystem: UnitSystem { didSet { defaults.set(unitSystem.rawValue, forKey: Keys.unitSystem) } }

    private let defaults: UserDefaults

    private enum Keys {
        static let livePreview = "settings.reading.livePreview"
        static let position = "settings.reading.position"
        static let morningDuration = "settings.reading.morningDuration"
        static let unitSystem = "settings.units.system"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Property observers don't fire during init, so these reads don't write back.
        livePreviewEnabled = defaults.object(forKey: Keys.livePreview) as? Bool ?? true
        readingPosition = defaults.string(forKey: Keys.position).flatMap(BodyPosition.init(rawValue:)) ?? .lyingDown
        // Legacy installs stored the old enum's rawValue (60/150/300) under the same key — all
        // valid seconds, so they migrate with no special handling. 0 (unset) → default.
        let storedDuration = defaults.integer(forKey: Keys.morningDuration)
        morningReadingDurationSeconds = storedDuration == 0 ? ReadingLength.default : storedDuration
        // Un-set installs infer from the device locale once (US → imperial); any later choice sticks.
        unitSystem = defaults.string(forKey: Keys.unitSystem).flatMap(UnitSystem.init(rawValue:)) ?? .localeDefault
    }
}

extension AppSettings: UnitSystemSource {}
