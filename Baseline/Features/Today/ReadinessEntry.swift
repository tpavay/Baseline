import Foundation
import SwiftData

/// A saved daily readiness result — the morning score plus the check-in that fed it. Local source
/// of truth for the home screen's "today" state and the readiness trend. CloudKit-safe per project
/// rules: every property defaults, nothing `.unique`, no required relationships.
@Model
final class ReadinessEntry {
    var id: UUID = UUID()
    var date: Date = Date.now
    var score: Int = 0
    var band: String = "amber"
    var soreness: Double?
    var mood: Double?
    var energy: Double?
    var stress: Double?
    var sleepQuality: Double?
    var notes: String = ""

    // Plan + limiter + certainty. Optional-backed (added after the model shipped — a non-optional
    // add would crash old rows; see the SwiftData gotcha in project memory).
    var certainty: String?
    var primaryLimiter: String?
    var planType: String?
    var planSummary: String?
    private var planWhyRaw: String?
    private var planAvoidRaw: String?

    var planWhy: [String] { planWhyRaw.map { $0.components(separatedBy: "\n").filter { !$0.isEmpty } } ?? [] }
    var planAvoid: [String] { planAvoidRaw.map { $0.components(separatedBy: "\n").filter { !$0.isEmpty } } ?? [] }

    // Sleep Engine decision snapshot (Slice 4, AC-7). Written only when the seam produced a score;
    // nil for the manual/legacy path. Plain optionals (like `certainty` above) are the crash-safe
    // idiom this @Model already uses — a row saved before these fields existed decodes them to nil.
    var sleepScore: Int?
    var sleepConfidence: Double?
    /// The exact `SleepAnalysis` (with its aggregation/score versions) the morning decision used,
    /// frozen as a Codable blob so late Health revisions can never rewrite what history shows was
    /// decided (plan §7). Immutable: set once at construction, exposed read-only.
    private var sleepDecisionSnapshotJSON: Data?
    var sleepDecisionSnapshot: SleepAnalysis? { SleepCoding.value(SleepAnalysis.self, sleepDecisionSnapshotJSON) }

    init(
        id: UUID = UUID(),
        date: Date = .now,
        score: Int = 0,
        band: String = "amber",
        soreness: Double? = nil,
        mood: Double? = nil,
        energy: Double? = nil,
        stress: Double? = nil,
        sleepQuality: Double? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.date = date
        self.score = score
        self.band = band
        self.soreness = soreness
        self.mood = mood
        self.energy = energy
        self.stress = stress
        self.sleepQuality = sleepQuality
        self.notes = notes
    }

    convenience init(date: Date = .now, decision: DecisionEngine.Result, plan: PlanningEngine.Plan,
                     answers: CheckInAnswers?, sleep: ReadinessSleepSnapshot? = nil) {
        self.init(
            date: date,
            score: decision.score,
            band: decision.band.rawValue,
            soreness: answers?.soreness,
            mood: answers?.mood,
            energy: answers?.energy,
            stress: answers?.stress,
            sleepQuality: answers?.sleepQuality,
            notes: answers?.notes ?? ""
        )
        certainty = decision.certainty.rawValue
        primaryLimiter = decision.primaryLimiter?.rawValue
        planType = plan.type.rawValue
        planSummary = plan.summary
        planWhyRaw = plan.why.joined(separator: "\n")
        planAvoidRaw = plan.avoid.joined(separator: "\n")
        // Freeze the sleep decision snapshot only when the seam supplied one (nil in the seam-off app).
        if let sleep {
            sleepScore = sleep.score
            sleepConfidence = sleep.confidence
            sleepDecisionSnapshotJSON = SleepCoding.data(sleep.analysis)
        }
    }
}
