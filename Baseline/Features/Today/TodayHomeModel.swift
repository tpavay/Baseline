import Foundation

struct TodayHomeModel: Equatable {
    let greeting: String
    let readings: [TodayReadingCard]
    let plan: TodayPlanCardModel
    let week: TodayWeeklySummary
    let zoneRanges: [HeartRateZone: String]
}

enum TodayReadingCard: Equatable, Identifiable {
    case sleep(TodaySleepCardModel)
    case hrv(TodayHRVCardModel)

    var id: String {
        switch self {
        case .sleep: "sleep"
        case .hrv: "hrv"
        }
    }
}

/// Everything Today needs to render the sleep card and push its detail. Assembled only when a
/// canonical night exists for today; absent while the Sleep Engine is dormant, which keeps Today's
/// layout byte-identical to pre-slice (no context → no card → no tap target).
struct SleepDetailContext: Equatable {
    var night: SleepNight
    var analysis: SleepAnalysis
    var decision: DecisionEngine.Result?
}

struct TodaySleepCardModel: Equatable {
    struct Segment: Equatable {
        let kind: SleepComponent.Kind
        let weight: Double
        let progress: Double
    }

    let score: Int
    /// The Apple-post-26.2 band word ("OK", "High", …) - the card's leading readout.
    let band: String
    /// "8h 32m asleep" under the band word.
    let durationText: String
    /// Ring segments in component order, weighted by each component's point ceiling (50/30/20) with
    /// progress = points earned / ceiling - the radial fill height.
    let segments: [Segment]

    /// Pure analysis → card mapping (tested without a view tree). nil when the night published no
    /// score: the card never shows a fabricated 0–100 number.
    static func make(_ analysis: SleepAnalysis) -> TodaySleepCardModel? {
        guard let score = analysis.score else { return nil }
        let order: [SleepComponent.Kind] = [.duration, .bedtimeConsistency, .interruptions]
        let segments = order.compactMap { kind -> Segment? in
            guard let component = analysis.component(kind), component.max > 0 else { return nil }
            return Segment(kind: kind,
                           weight: component.max,
                           progress: component.isAvailable ? component.value / component.max : 0)
        }
        let duration = analysis.asleepHours.map { "\(SleepFormat.hours($0)) asleep" } ?? ""
        return TodaySleepCardModel(
            score: score,
            band: SleepScoreBand(score: score).label,
            durationText: duration,
            segments: segments
        )
    }
}

struct TodayHRVCardModel: Equatable {
    let value: Int
    let comparisonText: String
    let isPositive: Bool
}

struct TodayPlanCardModel: Equatable {
    let title: String
    let detail: String
}
