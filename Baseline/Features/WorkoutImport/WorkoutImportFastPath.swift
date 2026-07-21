import Foundation

/// Runs the fast import path and reports the workout as it resolves.
///
/// One streaming call, assembled by `WorkoutImportSketchStream`, converted by
/// `WorkoutImportSketchConverter`, and handed back as a real draft after every delta. Because the
/// stream only ever appends whole exercises, each draft is the previous one plus rows — nothing an
/// athlete has already seen is rewritten underneath them.
///
/// It decides nothing about failure policy. It reports what it got and how it ended; the coordinator
/// decides whether that is worth showing or whether the durable job should take over.
struct WorkoutImportFastPath: Sendable {

    struct Outcome: Sendable {
        var document: ParsedWorkoutDocument?
        var build: WorkoutImportBuildResult?
        var model: String?
        /// Nil when the stream completed normally.
        var failureCode: String?

        /// Whether this is worth putting in front of the athlete.
        ///
        /// Judged on structure, not on field completeness. Exercises in the right order is the
        /// expensive part to get right and the cheap part to finish by hand; a missing number is
        /// seconds of typing. A parse with no exercises at all has no skeleton, so there is nothing
        /// to judge and nothing to show.
        var isWorthShowing: Bool {
            build?.draft.workout.allExercises.isEmpty == false
        }
    }

    private let streamer: any WorkoutImportStreaming

    init(streamer: any WorkoutImportStreaming) {
        self.streamer = streamer
    }

    /// Stream one import. `partial` is called after every delta that produced a new exercise.
    func run(
        images: [ImportedWorkoutImage],
        text: String?,
        catalog: [ExerciseDefinition],
        partial: @Sendable (WorkoutImportBuildResult, ParsedWorkoutDocument) async -> Void
    ) async -> Outcome {
        var stream = WorkoutImportSketchStream()
        var model: String?
        var failureCode: String?
        var shownExercises = 0

        do {
            let events = streamer.stream(
                images: images,
                text: text,
                catalogHints: WorkoutImportCoordinator.providerCatalogHints(catalog)
            )
            for try await event in events {
                try Task.checkCancellation()
                switch event {
                case .delta(let fragment):
                    guard let sketch = stream.append(fragment) else { continue }
                    let converted = WorkoutImportSketchConverter.convert(sketch, catalog: catalog)
                    let exercises = converted.document.blocks.flatMap(\.exercises).count
                    // Only republish when a whole new exercise has landed. Rebuilding for a delta
                    // that changed nothing visible would churn the editor for no benefit.
                    guard exercises > shownExercises else { continue }
                    shownExercises = exercises
                    await partial(
                        WorkoutImportDraftBuilder.build(converted.document, catalog: catalog),
                        converted.document
                    )
                case .completed(let reported):
                    model = reported
                case .failed(let code):
                    failureCode = code
                }
            }
        } catch is CancellationError {
            return Outcome(document: nil, build: nil, model: nil, failureCode: "cancelled")
        } catch {
            failureCode = failureCode ?? "remote_unavailable"
        }

        // Whatever arrived is still worth converting: a stream that died after eight of ten
        // exercises has still done most of the work, and the athlete can see what it got.
        guard let sketch = stream.finish() else {
            return Outcome(document: nil, build: nil, model: model, failureCode: failureCode ?? "no_stream_output")
        }
        let converted = WorkoutImportSketchConverter.convert(sketch, catalog: catalog)
        return Outcome(
            document: converted.document,
            build: WorkoutImportDraftBuilder.build(converted.document, catalog: catalog),
            model: model,
            failureCode: failureCode
        )
    }
}
