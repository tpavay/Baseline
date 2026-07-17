import Foundation

enum SetRole: String, Codable, Equatable, Sendable, CaseIterable {
    case warmup
    case working
    case top
    case backoff
    case drop
}

enum EffortTarget: Codable, Equatable, Sendable {
    case rpe(Double)
    case rir(Double)
    case toFailure
    case maxEffort
}

struct MetricTargetRange: Codable, Equatable, Sendable {
    var metric: MetricType
    var lower: Double
    var upper: Double

    init(metric: MetricType, lower: Double, upper: Double) {
        self.metric = metric
        self.lower = min(lower, upper)
        self.upper = max(lower, upper)
    }
}

enum ProgressionUnit: String, Codable, Equatable, Sendable {
    case set
    case round
    case interval
    case cycle
}

struct MetricProgression: Codable, Equatable, Sendable {
    var metric: MetricType
    var delta: Double
    var every: Int = 1
    var unit: ProgressionUnit

    func value(base: Double, iteration: Int) -> Double {
        let completedSteps = max(iteration - 1, 0) / max(every, 1)
        return max(0, base + Double(completedSteps) * delta)
    }
}

struct PlannedSetAlternative: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var label: String
    var values = MetricValues()
    var ranges: [MetricTargetRange] = []

    init(id: UUID = UUID(), label: String, values: MetricValues = MetricValues(),
         ranges: [MetricTargetRange] = []) {
        self.id = id
        self.label = label
        self.values = values
        self.ranges = ranges
    }

    private enum CodingKeys: String, CodingKey { case id, label, values, ranges }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try container.decode(String.self, forKey: .label)
        values = try container.decodeIfPresent(MetricValues.self, forKey: .values) ?? MetricValues()
        ranges = try container.decodeIfPresent([MetricTargetRange].self, forKey: .ranges) ?? []
    }
}

enum IntensityTarget: Codable, Equatable, Sendable {
    case heartRateZone(Int)
    case namedZone(system: String, range: String)
    case rpe(lower: Double, upper: Double)
    case pace(String)
    case power(lower: Double, upper: Double, unit: MetricUnit)
    case thresholdPercentage(lower: Double, upper: Double)
    case descriptive(String)
}

enum WorkoutPhase: String, Codable, Equatable, Sendable, CaseIterable {
    case warmup
    case main
    case cooldown
    case transition
}

enum DoseLayer: String, Codable, Equatable, Sendable, CaseIterable {
    case med
    case hpl
    case mdv
}

struct MetricAdjustment: Codable, Equatable, Sendable {
    var metric: MetricType
    var step: Double
    var minimum: Double?
    var maximum: Double?
}
