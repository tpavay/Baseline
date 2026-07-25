import Foundation

/// Pure, unit-testable resolvers over the Plan domain model. No SwiftData, no engines, no UI — they take
/// stored facts and compute what the UI shows. Per `docs/implementation/plan-tab.md`:
/// - **Status is never persisted** — `ScheduleStatusResolver` derives it on read.
/// - **Aggregates are contribution-based** - each workout contributes typed amounts; a caller renders
///   whatever exists rather than a hardcoded metric list.

// MARK: - Schedule status (derived, never stored)

/// The today-only physiological read, injected by the caller (which owns the DecisionEngine) so this
/// resolver stays pure. Percentages appear only when a real diff produced them.
enum TodayModification: Equatable, Sendable {
    case asPlanned
    case modified(reasons: [String])
    case constraintActive
    case swapSuggested
    case reducedVolume(percent: Int?)
}

enum ScheduleStatus: Equatable, Sendable {
    case planned                          // future, unchanged (UI: "Preview")
    case today(TodayModification)         // today, not started
    case inProgress
    case paused
    case completed
    case skipped
    case missed                           // past, non-rest, never completed
    case modifiedIntent(PlanActor)        // future, explicitly changed → attribution
}

/// Who last changed a future scheduled workout (from version history), for attribution status.
enum PlanActor: String, Codable, Equatable, Sendable { case user, agent, baseline, imported }

enum ScheduleStatusResolver {
    /// Resolve from stored facts only. `session`/`completed` are looked up by `scheduledWorkoutID` (never
    /// stored on the schedule). `todayModification` is supplied for today's session; `changedBy` is the
    /// actor of the most recent accepted change to a *future* workout, if any.
    static func status(
        for sw: ScheduledWorkout,
        today: Date,
        calendar: Calendar = .current,
        session: WorkoutSession?,
        completed: CompletedWorkoutLog?,
        todayModification: TodayModification? = nil,
        changedBy: PlanActor? = nil
    ) -> ScheduleStatus {
        // Performed facts win — they're immutable and independent of plan intent.
        if completed != nil { return .completed }
        if let session {
            switch session.status {
            case .active: return .inProgress
            case .paused: return .paused
            case .completed: return .completed
            case .discarded: break        // fall through to intent-based status
            }
        }
        if sw.skipped { return .skipped }

        if calendar.isDate(sw.date, inSameDayAs: today) {
            return .today(todayModification ?? .asPlanned)
        }
        if sw.date < calendar.startOfDay(for: today) {
            return .missed                // past, not completed, not skipped
        }
        // Future.
        if let changedBy { return .modifiedIntent(changedBy) }
        return .planned
    }
}

// MARK: - Planned aggregates (contribution-based)

enum AggregateKey: String, Sendable, CaseIterable {
    case sessions, duration, distance, strengthSets, calories
}

struct MetricContribution: Equatable, Sendable {
    let key: AggregateKey
    let amount: Double                    // canonical units (duration=s, distance=m, calories=kcal, counts=1)
}

struct Aggregate: Equatable, Sendable, Identifiable {
    let key: AggregateKey
    let total: Double                     // canonical
    var id: AggregateKey { key }
}

/// Each workout contributes typed amounts derived from its *planned* content, and a caller renders
/// whatever aggregates exist for the sessions it asked about. Adding a modality never touches a view.
/// This resolves plan intent only - a weekly total of what was actually performed comes from the
/// completed logs behind the Today tab's This Week card, never from summing prescriptions.
enum AggregateProvider {
    /// What one workout's *planned* content contributes.
    static func contributions(of workout: Workout) -> [MetricContribution] {
        var duration = 0.0, distance = 0.0, calories = 0.0, strengthSets = 0.0
        for ex in workout.allExercises {
            let isStrength = ex.definition.category == .strength
            for set in ex.prescription.sets {
                if let d = set.values[.duration] { duration += d }
                if let m = set.values[.distance] { distance += m }
                if let c = set.values[.calories] { calories += c }
                if isStrength { strengthSets += 1 }
            }
        }
        var out: [MetricContribution] = []
        if duration > 0 { out.append(.init(key: .duration, amount: duration)) }
        if distance > 0 { out.append(.init(key: .distance, amount: distance)) }
        if calories > 0 { out.append(.init(key: .calories, amount: calories)) }
        if strengthSets > 0 { out.append(.init(key: .strengthSets, amount: strengthSets)) }
        return out
    }

    /// Sum contributions across a set of scheduled workouts, plus a session count. Only aggregates with a
    /// non-zero total are returned, in a stable display order.
    static func aggregates(for scheduled: [ScheduledWorkout]) -> [Aggregate] {
        var totals: [AggregateKey: Double] = [:]
        for sw in scheduled where !sw.skipped {
            for c in contributions(of: sw.workout) { totals[c.key, default: 0] += c.amount }
        }
        totals[.sessions] = Double(scheduled.filter { !$0.skipped }.count)
        return AggregateKey.allCases.compactMap { key in
            guard let t = totals[key], t > 0 else { return nil }
            return Aggregate(key: key, total: t)
        }
    }
}
