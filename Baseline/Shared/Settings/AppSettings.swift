import Foundation
import Observation

/// App-wide user preferences, persisted in UserDefaults. Injected via the environment so both
/// views and the cue engine can read them.
@MainActor
@Observable
final class AppSettings {
    var voiceCuesEnabled: Bool { didSet { defaults.set(voiceCuesEnabled, forKey: Keys.voice) } }
    var hapticCuesEnabled: Bool { didSet { defaults.set(hapticCuesEnabled, forKey: Keys.haptics) } }
    var livePreviewEnabled: Bool { didSet { defaults.set(livePreviewEnabled, forKey: Keys.livePreview) } }
    var guidedBreathingEnabled: Bool { didSet { defaults.set(guidedBreathingEnabled, forKey: Keys.guidedBreathing) } }
    var readingPosition: BodyPosition { didSet { defaults.set(readingPosition.rawValue, forKey: Keys.position) } }
    /// Morning reading length in whole seconds (1:00–5:59). Clamped on set.
    var morningReadingDurationSeconds: Int {
        didSet {
            let clamped = min(max(morningReadingDurationSeconds, ReadingLength.range.lowerBound), ReadingLength.range.upperBound)
            if clamped != morningReadingDurationSeconds { morningReadingDurationSeconds = clamped; return }
            defaults.set(morningReadingDurationSeconds, forKey: Keys.morningDuration)
        }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let voice = "settings.cues.voice"
        static let haptics = "settings.cues.haptics"
        static let livePreview = "settings.reading.livePreview"
        static let guidedBreathing = "settings.reading.guidedBreathing"
        static let position = "settings.reading.position"
        static let morningDuration = "settings.reading.morningDuration"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Property observers don't fire during init, so these reads don't write back.
        voiceCuesEnabled = defaults.object(forKey: Keys.voice) as? Bool ?? true
        hapticCuesEnabled = defaults.object(forKey: Keys.haptics) as? Bool ?? true
        livePreviewEnabled = defaults.object(forKey: Keys.livePreview) as? Bool ?? true
        // Natural breathing is the measurement protocol (paced cues shift HRV via respiration
        // — decided 2026-07-07); the pacer remains an opt-in.
        guidedBreathingEnabled = defaults.object(forKey: Keys.guidedBreathing) as? Bool ?? false
        readingPosition = defaults.string(forKey: Keys.position).flatMap(BodyPosition.init(rawValue:)) ?? .lyingDown
        // Legacy installs stored the old enum's rawValue (60/150/300) under the same key — all
        // valid seconds, so they migrate with no special handling. 0 (unset) → default.
        let storedDuration = defaults.integer(forKey: Keys.morningDuration)
        morningReadingDurationSeconds = storedDuration == 0 ? ReadingLength.default : storedDuration
    }
}
