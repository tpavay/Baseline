import Foundation

enum BreathPhase: String, Equatable, Sendable {
    case inhale = "Breathe in"
    case exhale = "Breathe out"
}

/// The breathing cue at a moment in the read: which phase, how far through it, and a smooth
/// 0…1 scale (0 = fully exhaled, 1 = fully inhaled) the orb maps to.
struct BreathState: Equatable, Sendable {
    var phase: BreathPhase
    var progress: Double
    var scale: Double
}

/// Pure 5s-in / 5s-out resonance pacing (≈6 breaths/min). No UIKit/Firebase so it's
/// unit-testable; the view just renders `state(atElapsed:)`.
enum BreathingPacer {
    static let inhale: TimeInterval = 5
    static let exhale: TimeInterval = 5
    static var cycle: TimeInterval { inhale + exhale }

    static func state(atElapsed t: TimeInterval) -> BreathState {
        let phaseTime = t.truncatingRemainder(dividingBy: cycle)
        if phaseTime < inhale {
            let p = phaseTime / inhale
            return BreathState(phase: .inhale, progress: p, scale: smoothstep(p))
        } else {
            let p = (phaseTime - inhale) / exhale
            return BreathState(phase: .exhale, progress: p, scale: 1 - smoothstep(p))
        }
    }

    /// Smooth ease 0…1 so the orb breathes naturally instead of linearly.
    private static func smoothstep(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}
