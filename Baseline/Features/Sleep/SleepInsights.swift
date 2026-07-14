import Foundation

/// Descriptive, recomputable sleep insight copy (plan §2 Q-C / §4). A **pure** function of a
/// `SleepAnalysis` — every emitted line's quantities are recomputed directly from analysis fields,
/// so the copy can never drift from the numbers the engine produced (AC-7).
///
/// v1 is deliberately **descriptive/calculable only**: vs-average duration, bedtime shift, awake
/// time, tracking gap, and notable-night rank. There are **no stage→effect claims** ("less REM →
/// higher effort") anywhere — those are Learning Engine material and would be unsubstantiated
/// single-night statements. The negative claim-scan test guards this.
enum SleepInsights {

    /// Notability thresholds so trivial deltas don't produce noise. Minutes.
    enum Tunables {
        static let durationDeltaMinMinutes = 15.0
        static let bedtimeDeltaMinMinutes = 15.0
        static let awakeMinMinutes = 5.0
        static let gapMinMinutes = 5.0
    }

    static func rules(for analysis: SleepAnalysis) -> [String] {
        [
            durationVsAverage(analysis),
            bedtimeShift(analysis),
            awakeTime(analysis),
            trackingGap(analysis),
            notableNight(analysis)
        ].compactMap { $0 }
    }

    // MARK: - Rules

    /// "You slept 54 minutes less than your 30-day average."
    private static func durationVsAverage(_ analysis: SleepAnalysis) -> String? {
        guard let asleep = analysis.asleepHours, let mean = analysis.vsBaseline.chronic30Mean else {
            return nil
        }
        let deltaMinutes = (asleep - mean) * 60
        guard abs(deltaMinutes) >= Tunables.durationDeltaMinMinutes else { return nil }
        let direction = deltaMinutes < 0 ? "less" : "more"
        return "You slept \(duration(abs(deltaMinutes))) \(direction) than your 30-day average."
    }

    /// "Your bedtime was 1 h 12 m off your usual time." Direction-neutral: the analysis carries the
    /// deviation magnitude (`scheduleShiftMinutes`), not a signed offset, so the copy states the
    /// magnitude honestly without asserting later/earlier it cannot recompute.
    private static func bedtimeShift(_ analysis: SleepAnalysis) -> String? {
        guard let shift = analysis.decisionEvidence.scheduleShiftMinutes,
              shift >= Tunables.bedtimeDeltaMinMinutes else { return nil }
        return "Your bedtime was \(duration(shift)) off your usual time."
    }

    /// "You were awake 38 minutes during the night."
    private static func awakeTime(_ analysis: SleepAnalysis) -> String? {
        guard let waso = analysis.wasoMinutes, waso >= Tunables.awakeMinMinutes else { return nil }
        return "You were awake \(duration(waso)) during the night."
    }

    /// "Your sleep data contains a tracking gap of 46 minutes."
    private static func trackingGap(_ analysis: SleepAnalysis) -> String? {
        let gap = analysis.additionalEvidence.gapMinutes
        guard gap >= Tunables.gapMinMinutes else { return nil }
        return "Your sleep data contains a tracking gap of \(duration(gap))."
    }

    /// "This was your shortest night in 21 days." / "…longest night in 21 days."
    private static func notableNight(_ analysis: SleepAnalysis) -> String? {
        for flag in analysis.flags {
            switch flag {
            case .worstIn(let days):
                return "This was your shortest night in \(days) days."
            case .bestIn(let days):
                return "This was your longest night in \(days) days."
            default:
                continue
            }
        }
        return nil
    }

    // MARK: - Formatting

    /// Minutes → "38 minutes" / "1 h 12 m" / "2 h", rounded to the nearest minute so the printed
    /// quantity is exactly what a test recomputes from the same field.
    private static func duration(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let hours = total / 60
        let mins = total % 60
        if hours == 0 { return "\(mins) minute\(mins == 1 ? "" : "s")" }
        if mins == 0 { return "\(hours) h" }
        return "\(hours) h \(mins) m"
    }
}
