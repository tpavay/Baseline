#if DEBUG
import Foundation

enum WorkoutImportDebugFixtures {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-workout-import-debug")
    }

    static var session: ImportSession {
        switch value(after: "-workout-import-debug-state") {
        case "waiting": waiting
        case "retrying": retrying
        case "processing": processing
        case "failure": failure
        default: review
        }
    }

    static var job: WorkoutImportJob? {
        switch value(after: "-workout-import-debug-state") {
        case "waiting":
            WorkoutImportJob(
                stage: .waitingForHandoff,
                expectedPageCount: 5,
                pages: review.sourcePages
            )
        case "processing":
            WorkoutImportJob(
                stage: .processingSections,
                expectedPageCount: 5,
                pages: review.sourcePages,
                serverProgress: .init(
                    serverJobID: "debug-processing-job",
                    status: "processing",
                    completedSections: 2,
                    totalSections: 4
                )
            )
        case "retrying":
            WorkoutImportJob(
                stage: .failed,
                expectedPageCount: 5,
                pages: review.sourcePages,
                serverProgress: .init(
                    serverJobID: "debug-retrying-job",
                    status: "failed",
                    completedSections: 1,
                    totalSections: 2,
                    failureCode: "provider_unavailable"
                )
            )
        case "failure":
            WorkoutImportJob(
                stage: .failed,
                expectedPageCount: 5,
                pages: review.sourcePages,
                serverProgress: .init(
                    serverJobID: "debug-failed-job",
                    status: "failed",
                    completedSections: 2,
                    totalSections: 4,
                    failureCode: "remote_unavailable"
                ),
                failure: .init(stage: "status", reasonCode: "remote_unavailable", isRetryable: true)
            )
        default:
            WorkoutImportJob(
                stage: .reviewing,
                expectedPageCount: 5,
                pages: review.sourcePages,
                draft: review.draft,
                issues: review.issues,
                diagnostics: review.diagnostics
            )
        }
    }

    private static var review: ImportSession {
        let sledID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let deadliftID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let sled = PlannedExercise(
            id: sledID,
            exerciseName: "Sled Pull",
            definitionId: "sled-pull",
            selectedMetrics: [.distance, .load],
            prescription: Prescription(sets: [PlannedSet(distance: 25)])
        )
        let deadlift = PlannedExercise(
            id: deadliftID,
            exerciseName: "Deadlift",
            definitionId: "deadlift",
            selectedMetrics: [.reps, .load],
            prescription: Prescription(
                sets: [PlannedSet(reps: 12)],
                intensityTargets: [.descriptive("Bodyweight on the bar")]
            )
        )
        let burpee = PlannedExercise(
            exerciseName: "Lateral Burpee Over Barbell",
            definitionId: "lateral-burpee-over-barbell",
            selectedMetrics: [.reps],
            prescription: Prescription(sets: [PlannedSet(reps: 12)])
        )
        let workout = Workout(
            title: "Aerobic Capacity - Week 3",
            goal: "Build aerobic capacity while protecting the surrounding intensity days.",
            guidance: CoachGuidance(
                formCues: [
                    "Use this day to consolidate, not chase stimulus.",
                    "Finish feeling calm, loose, and ready to train again.",
                ]
            ),
            blocks: [
                WorkoutBlock(
                    name: "Minimum Effective Dose",
                    intent: "70 minute AMRAP, plus or minus 10 minutes based on desired volume.",
                    exercises: [sled, deadlift, burpee]
                ),
                WorkoutBlock(
                    name: "Performance Layer",
                    intent: "StairMaster work with optional vest or ruck.",
                    exercises: [
                        PlannedExercise(
                            exerciseName: "Stair Climber",
                            definitionId: "stair-climber",
                            selectedMetrics: [.duration],
                            prescription: Prescription(sets: [PlannedSet(duration: 2_100)])
                        ),
                        PlannedExercise(
                            exerciseName: "Dumbbell Push Press",
                            definitionId: "dumbbell-push-press",
                            selectedMetrics: [.reps, .load],
                            prescription: Prescription(sets: [PlannedSet(reps: 12)])
                        ),
                    ]
                ),
            ]
        )
        let pages = (0..<5).map { index in
            WorkoutImportSourcePage(
                index: index,
                relativeFilename: "pages/\(index).jpg",
                digest: WorkoutImportStableIdentity.digest(["debug-page", String(index)]),
                pixelWidth: 1_178,
                pixelHeight: 2_556,
                stage: .recognized
            )
        }
        return ImportSession(
            sourcePages: pages,
            draft: WorkoutTemplateDraft(workout: workout),
            issues: [
                WorkoutImportIssue(
                    code: .missingMetricValue,
                    severity: .warning,
                    message: "Sled Pull: add the load if you want to track it.",
                    exerciseID: sledID,
                    metric: .load
                ),
                WorkoutImportIssue(
                    code: .missingMetricValue,
                    severity: .warning,
                    message: "Deadlift: add the bar load when you review this workout.",
                    exerciseID: deadliftID,
                    metric: .load
                ),
            ],
            diagnostics: WorkoutImportDiagnostics(imageCount: 5, sectionCount: 4),
            status: .reviewing
        )
    }

    private static var processing: ImportSession {
        ImportSession(
            sourcePages: review.sourcePages,
            diagnostics: WorkoutImportDiagnostics(imageCount: 5, sectionCount: 4),
            status: .processingSections(completed: 2, total: 4)
        )
    }

    private static var waiting: ImportSession {
        ImportSession(
            sourcePages: review.sourcePages,
            diagnostics: WorkoutImportDiagnostics(imageCount: 5, sectionCount: 2),
            status: .waitingForHandoff
        )
    }

    private static var retrying: ImportSession {
        ImportSession(
            sourcePages: review.sourcePages,
            diagnostics: WorkoutImportDiagnostics(imageCount: 5, sectionCount: 2),
            status: .retryingSections(completed: 1, total: 2)
        )
    }

    private static var failure: ImportSession {
        ImportSession(
            sourcePages: review.sourcePages,
            diagnostics: WorkoutImportDiagnostics(imageCount: 5, sectionCount: 4),
            status: .failed(message: "The import is saved, but Baseline could not reach the workout parser. Try again.")
        )
    }

    private static func value(after argument: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
#endif
