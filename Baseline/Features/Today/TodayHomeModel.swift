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

struct TodaySleepCardModel: Equatable {
    struct Segment: Equatable {
        let weight: Double
        let progress: Double
        let colorRole: ColorRole
    }

    enum ColorRole: Equatable {
        case duration
        case consistency
        case interruptions
    }

    let score: Int
    let rating: String
    let durationText: String
    let segments: [Segment]
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
