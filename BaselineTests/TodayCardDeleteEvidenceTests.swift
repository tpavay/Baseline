import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// Renders the real Today home cards ("This Week" + "Movement Balance") from live repository data before
/// and after a completed workout is deleted, capturing before/after PNGs into `evidence/`. This is the
/// visual proof for the fix: the "before" shot shows the logged session's session count, training
/// duration, Movement Balance bars and muscle heat map; the "after" shot shows them all cleared the
/// instant the delete cascades its performed rows away.
@MainActor
@Suite(.serialized)
struct TodayCardDeleteEvidenceTests {

    private let cal = Calendar.planWeek
    private var monday: Date { cal.weekStart(for: Date(timeIntervalSince1970: 1_752_000_000)) }

    @Test func capturesWeeklyCardsBeforeAndAfterDeletingACompletedWorkout() throws {
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let container = try ModelContainer(for: Schema(models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let repo = SwiftDataPlanRepository(context: context)
        let prog = repo.addProgram(Program(name: "P", createdAt: monday))

        // Log a full week of varied training so the cards have something worth looking at, then delete the
        // most recent (a pull day) to prove it drops out.
        completeStrength(repo, program: prog.id, title: "Back Squat", definitionID: "back_squat", day: 0, sets: 5, load: 140)
        completeStrength(repo, program: prog.id, title: "Bench Press", definitionID: "bench_press", day: 1, sets: 4, load: 90)
        completeCardio(repo, program: prog.id, day: 2, minutes: 40)
        let pullDay = completeStrength(repo, program: prog.id, title: "Deadlift", definitionID: "deadlift", day: 3, sets: 5, load: 180)

        let before = summary(context)
        #expect(before.sessionCount == 4)
        try render(before, name: "today-cards-before-delete")

        confirmDelete(repo, pullDay.id)

        let after = summary(context)
        #expect(after.sessionCount == 3)                                        // the deleted pull day is gone
        #expect(after.movements.first { $0.name == "Hinge" }?.sets == 0)        // its Hinge sets cleared
        try render(after, name: "today-cards-after-delete")
    }

    // MARK: Seeding

    @discardableResult
    private func completeStrength(_ repo: SwiftDataPlanRepository, program: UUID, title: String,
                                  definitionID: String, day: Int, sets: Int, load: Double) -> ScheduledWorkout {
        var ex = PlannedExercise(exerciseName: title, definitionId: definitionID)
        ex.prescription.sets = (0..<sets).map { _ in PlannedSet(reps: 5, load: load) }
        return complete(repo, program: program, title: title, exercise: ex, day: day, minutes: 50) { log, planned in
            for set in planned.prescription.sets {
                log.upsertSetLog(forPlanned: planned.id, name: planned.exerciseName, plannedSetID: set.id) {
                    $0.values[.load] = load; $0.values.setInt(.reps, 5); $0.completed = true
                }
            }
        }
    }

    @discardableResult
    private func completeCardio(_ repo: SwiftDataPlanRepository, program: UUID, day: Int, minutes: Int) -> ScheduledWorkout {
        var ex = PlannedExercise(exerciseName: "Run", definitionId: "run")
        ex.prescription.sets = [PlannedSet()]
        return complete(repo, program: program, title: "Run", exercise: ex, day: day, minutes: minutes) { log, planned in
            log.upsertSetLog(forPlanned: planned.id, name: planned.exerciseName, plannedSetID: planned.prescription.sets[0].id) {
                $0.values[.duration] = Double(minutes) * 60; $0.values[.heartRate] = 150; $0.completed = true
            }
        }
    }

    private func complete(_ repo: SwiftDataPlanRepository, program: UUID, title: String, exercise: PlannedExercise,
                          day: Int, minutes: Int, log: (inout WorkoutLog, PlannedExercise) -> Void) -> ScheduledWorkout {
        let date = cal.date(byAdding: .day, value: day, to: monday)!
        let workout = Workout(title: title, blocks: [WorkoutBlock(name: "", exercises: [exercise], isDefault: true)])
        let sw = repo.addScheduled(ScheduledWorkout(programID: program, date: date, origin: .userCreated,
                                                    workoutID: UUID(), workoutRevisionID: UUID(), workout: workout))
        let planned = sw.workout.allExercises.first!
        repo.startSession(forScheduled: sw.id, now: date)
        repo.updateSessionLog(forScheduled: sw.id) { log(&$0, planned) }
        _ = repo.completeSession(forScheduled: sw.id, acknowledgingOpenWork: true,
                                 now: cal.date(byAdding: .minute, value: minutes, to: date)!)
        return sw
    }

    private func confirmDelete(_ repo: SwiftDataPlanRepository, _ id: UUID) {
        guard case .confirmationRequired(_, _, let proposalID) = repo.delete(id, actor: .user, reason: nil, proposalID: nil) else {
            Issue.record("expected confirmationRequired"); return
        }
        #expect(repo.delete(id, actor: .user, reason: nil, proposalID: proposalID).isApplied)
    }

    // MARK: Summary mapping (mirrors TodayView.completedSessionSamples / completedExerciseSamples)

    private func summary(_ context: ModelContext) -> TodayWeeklySummary {
        let logs = (try? context.fetch(FetchDescriptor<SDCompletedLog>())) ?? []
        let sessions = (try? context.fetch(FetchDescriptor<SDWorkoutSession>())) ?? []
        let exercises = (try? context.fetch(FetchDescriptor<SDCompletedExercise>())) ?? []
        let sessionSamples = logs.map { completed -> TodayCompletedSessionSample in
            let startedAt = sessions.first {
                $0.scheduledWorkoutID == completed.scheduledWorkoutID && $0.startedAt <= completed.finishedAt
            }?.startedAt
            return TodayCompletedSessionSample(completedLogID: completed.id, finishedAt: completed.finishedAt, startedAt: startedAt)
        }
        let exerciseSamples = exercises.map {
            TodayCompletedExerciseSample(
                completedLogID: $0.completedLogID, date: $0.date, definitionID: $0.exerciseDefinitionID,
                metrics: (try? JSONDecoder().decode([MetricValues].self, from: $0.metricsJSON)) ?? [])
        }
        return TodayWeeklySummary.build(sessions: sessionSamples, exercises: exerciseSamples,
                                        zoneModel: HeartRateZoneModel(maxHR: 200), referenceDate: monday, calendar: cal)
    }

    // MARK: Render + capture

    private func model(_ week: TodayWeeklySummary) -> TodayHomeModel {
        TodayHomeModel(
            greeting: "Good morning, Tyler",
            readings: [],
            plan: TodayPlanCardModel(title: "Intensity - Block 12", detail: "45 min · intervals. High certainty."),
            week: week,
            zoneRanges: [.z1: "95-121", .z2: "122-140", .z3: "141-158", .z4: "159-172", .z5: "173-195"]
        )
    }

    private func render(_ week: TodayWeeklySummary, name: String) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        let root = TodayHomeView(model: model(week), openSleep: {}, openHRV: {}, openPlan: {})
            .preferredColorScheme(.dark)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        // Let SwiftUI lay out and load the muscle-map image assets before rasterizing.
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let data = try #require(image.pngData())
        let url = Self.evidenceDirectory.appendingPathComponent("\(name).png")
        try data.write(to: url, options: .atomic)
        print("SCREENSHOT \(url.path)")
    }

    private static let evidenceDirectory: URL = {
        let base = ProcessInfo.processInfo.environment["BASELINE_EVIDENCE_DIR"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("evidence")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
}
