import Foundation

/// The user-facing sleep score band. Cutoffs follow Apple's post-watchOS-26.2 Sleep Score ranges
/// (Very Low 0–40 · Low 41–60 · OK 61–80 · High 81–95 · Very High 96–100) - the same re-banding
/// that made a 78 an "OK" rather than the original, more generous "High". The band is a pure
/// score→word mapping shared by the Today sleep card, the sleep detail headline, and the About
/// screen, so all three surfaces can never disagree.
enum SleepScoreBand: CaseIterable, Equatable, Sendable {
    case veryLow
    case low
    case ok
    case high
    case veryHigh

    init(score: Int) {
        switch score {
        case ..<41: self = .veryLow
        case 41...60: self = .low
        case 61...80: self = .ok
        case 81...95: self = .high
        default: self = .veryHigh
        }
    }

    var label: String {
        switch self {
        case .veryLow: "Very Low"
        case .low: "Low"
        case .ok: "OK"
        case .high: "High"
        case .veryHigh: "Very High"
        }
    }

    /// The score range the band covers, for the About screen's band ladder.
    var rangeLabel: String {
        switch self {
        case .veryLow: "0–40"
        case .low: "41–60"
        case .ok: "61–80"
        case .high: "81–95"
        case .veryHigh: "96+"
        }
    }
}
