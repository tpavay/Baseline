import Foundation
import Testing
@testable import Baseline

/// The fast path and how the coordinator routes around it. Driven through a fake transport, so the
/// routing rules and the partial-result policy are asserted without a network.
@Suite("Workout import fast path")
struct WorkoutImportFastPathTests {

    // MARK: - Fakes

    /// Emits a scripted event sequence. Splitting a response into fragments is how a real stream
    /// behaves, and the assertions below depend on partials being delivered mid-flight.
    private struct ScriptedStreamer: WorkoutImportStreaming {
        var events: [WorkoutImportStreamEvent]

        func stream(
            images: [ImportedWorkoutImage],
            text: String?,
            catalogHints: [String]
        ) -> AsyncThrowingStream<WorkoutImportStreamEvent, any Error> {
            let events = events
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    private struct ThrowingStreamer: WorkoutImportStreaming {
        func stream(
            images: [ImportedWorkoutImage],
            text: String?,
            catalogHints: [String]
        ) -> AsyncThrowingStream<WorkoutImportStreamEvent, any Error> {
            AsyncThrowingStream { $0.finish(throwing: WorkoutImportStreamError.unreachable) }
        }
    }

    /// Records what the transport was handed, so "the image really is sent" is checkable.
    private actor RecordingStreamer: WorkoutImportStreaming {
        private(set) var imageCounts: [Int] = []
        private(set) var texts: [String?] = []
        private let events: [WorkoutImportStreamEvent]

        init(events: [WorkoutImportStreamEvent]) { self.events = events }

        private func record(images: Int, text: String?) {
            imageCounts.append(images)
            texts.append(text)
        }

        nonisolated func stream(
            images: [ImportedWorkoutImage],
            text: String?,
            catalogHints: [String]
        ) -> AsyncThrowingStream<WorkoutImportStreamEvent, any Error> {
            let events = events
            let imageCount = images.count
            return AsyncThrowingStream { continuation in
                Task {
                    await self.record(images: imageCount, text: text)
                    for event in events { continuation.yield(event) }
                    continuation.finish()
                }
            }
        }
    }

    private static let response = """
    {"title":"AM: VO2 THRESHOLDS","blocks":[{"name":"A) 400s","items":[\
    {"name":"Run","sets":"15","prescription":"400m","rest":"40 secs"},\
    {"name":"Burpee Broad Jump","sets":"4 min","prescription":"8 reps"}]}]}
    """

    /// The response split the way a stream delivers it, so a partial is emitted part way through.
    private static func fragments(of json: String, chunks: Int = 12) -> [WorkoutImportStreamEvent] {
        let size = max(1, json.count / chunks)
        var events: [WorkoutImportStreamEvent] = []
        var index = json.startIndex
        while index < json.endIndex {
            let end = json.index(index, offsetBy: size, limitedBy: json.endIndex) ?? json.endIndex
            events.append(.delta(String(json[index..<end])))
            index = end
        }
        return events
    }

    // MARK: - The fast path itself

    @Test func aCompleteStreamProducesTheWholeWorkoutAndReportsNoFailure() async {
        let path = WorkoutImportFastPath(streamer: ScriptedStreamer(
            events: Self.fragments(of: Self.response) + [.completed(model: "test-model")]
        ))

        let outcome = await path.run(images: [], text: "ignored", catalog: ExerciseCatalog.definitions) { _, _ in }

        #expect(outcome.failureCode == nil)
        #expect(outcome.model == "test-model")
        #expect(outcome.isWorthShowing)
        #expect(outcome.build?.draft.workout.allExercises.map(\.exerciseName) == ["Run", "Burpee Broad Jump"])
        #expect(outcome.document?.title == "AM: VO2 THRESHOLDS")
    }

    /// The display promise, at the layer that produces it: every partial is the previous one plus
    /// exercises. Nothing an athlete has already seen is rewritten.
    @Test func partialsOnlyEverGrowAndNeverRewriteAnExerciseAlreadyShown() async {
        let path = WorkoutImportFastPath(streamer: ScriptedStreamer(
            events: Self.fragments(of: Self.response, chunks: 40) + [.completed(model: nil)]
        ))
        let collected = Collector()

        _ = await path.run(images: [], text: nil, catalog: ExerciseCatalog.definitions) { build, _ in
            await collected.append(build.draft.workout.allExercises.map(\.exerciseName))
        }

        let snapshots = await collected.snapshots
        #expect(!snapshots.isEmpty, "the stream should have shown something before it finished")
        for (previous, next) in zip(snapshots, snapshots.dropFirst()) {
            #expect(next.count > previous.count, "a partial must add exercises, never remove them")
            #expect(Array(next.prefix(previous.count)) == previous, "an already-visible row changed")
        }
        #expect(snapshots.last?.allSatisfy { !$0.isEmpty } == true)
    }

    /// A stream that dies part way through has still done most of the work. The skeleton it produced
    /// is kept and reported alongside the failure, rather than thrown away.
    @Test func aTruncatedStreamKeepsTheExercisesItDidDeliver() async {
        let cut = Self.response.range(of: #"{"name":"Burpee"#)!.lowerBound
        let partial = String(Self.response[Self.response.startIndex..<cut])
        let path = WorkoutImportFastPath(streamer: ScriptedStreamer(
            events: Self.fragments(of: partial) + [.failed(code: "remote_unavailable")]
        ))

        let outcome = await path.run(images: [], text: nil, catalog: ExerciseCatalog.definitions) { _, _ in }

        #expect(outcome.failureCode == "remote_unavailable")
        #expect(outcome.isWorthShowing)
        #expect(outcome.build?.draft.workout.allExercises.map(\.exerciseName) == ["Run"])
    }

    /// No skeleton means nothing to judge, so there is nothing worth showing and the caller must
    /// fall back rather than open an empty editor.
    @Test func aStreamThatDeliveredNothingIsNotWorthShowing() async {
        let dead = WorkoutImportFastPath(streamer: ScriptedStreamer(events: [.failed(code: "rate_limited")]))
        let deadOutcome = await dead.run(images: [], text: nil, catalog: ExerciseCatalog.definitions) { _, _ in }
        #expect(!deadOutcome.isWorthShowing)
        #expect(deadOutcome.failureCode == "rate_limited")

        let broken = WorkoutImportFastPath(streamer: ThrowingStreamer())
        let brokenOutcome = await broken.run(images: [], text: nil, catalog: ExerciseCatalog.definitions) { _, _ in }
        #expect(!brokenOutcome.isWorthShowing)
        #expect(brokenOutcome.failureCode != nil)
    }

    // MARK: - Routing

    @Test func aSinglePhotoTakesTheFastPathAndLandsInReviewWithoutTheDurableJob() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportFastPathRoute-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let parser = RecordingWorkoutImportJobParser()
        let coordinator = WorkoutImportCoordinator(
            repository: FileWorkoutImportJobRepository(root: root),
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: parser,
            streamer: ScriptedStreamer(
                events: Self.fragments(of: Self.response) + [.completed(model: "test-model")]
            ),
            configuration: .init(pollingDelay: {})
        )

        let job = await coordinator.start(
            imageCount: 1,
            catalog: ExerciseCatalog.definitions,
            loadImage: { _ in Data([1]) },
            progress: { _ in }
        )

        #expect(job.stage == .reviewing)
        #expect(job.draft?.workout.allExercises.map(\.exerciseName) == ["Run", "Burpee Broad Jump"])
        #expect(job.diagnostics.parserModel == "test-model")
        #expect(await parser.startCallCount() == 0, "the durable job must not run when the fast path succeeded")
    }

    /// The durable job is the retry, exactly as the latency report recommends. It is not removed.
    @Test func aFailedFastPathHandsOffToTheDurableJob() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportFastPathFallback-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let parser = RecordingWorkoutImportJobParser()
        let coordinator = WorkoutImportCoordinator(
            repository: FileWorkoutImportJobRepository(root: root),
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: parser,
            streamer: ThrowingStreamer(),
            configuration: .init(pollingDelay: {})
        )

        _ = await coordinator.start(
            imageCount: 1,
            catalog: ExerciseCatalog.definitions,
            loadImage: { _ in Data([1]) },
            progress: { _ in }
        )

        #expect(await parser.startCallCount() == 1)
    }

    /// Multi-image imports stay durable. They are long enough that an athlete may leave the app
    /// mid-import, which is the case the queue genuinely earns.
    @Test func aMultiPhotoImportSkipsTheFastPathEntirely() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportFastPathMulti-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let parser = RecordingWorkoutImportJobParser()
        let streamer = RecordingStreamer(events: Self.fragments(of: Self.response) + [.completed(model: nil)])
        let coordinator = WorkoutImportCoordinator(
            repository: FileWorkoutImportJobRepository(root: root),
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: parser,
            streamer: streamer,
            configuration: .init(pollingDelay: {})
        )

        _ = await coordinator.start(
            imageCount: 3,
            catalog: ExerciseCatalog.definitions,
            loadImage: { index in Data([UInt8(index + 1)]) },
            progress: { _ in }
        )

        #expect(await streamer.imageCounts.isEmpty, "the fast path must not run for a multi-photo import")
        #expect(await parser.startCallCount() == 1)
    }

    /// The recognized text always travels, so an import still works when the normalized image is
    /// gone from disk — and the stream is never asked to read from nothing.
    @Test func recognizedTextIsSentAlongsideTheImage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportFastPathPayload-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let streamer = RecordingStreamer(events: Self.fragments(of: Self.response) + [.completed(model: nil)])
        let coordinator = WorkoutImportCoordinator(
            repository: FileWorkoutImportJobRepository(root: root),
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: RecordingWorkoutImportJobParser(),
            streamer: streamer,
            configuration: .init(pollingDelay: {})
        )

        _ = await coordinator.start(
            imageCount: 1,
            catalog: ExerciseCatalog.definitions,
            loadImage: { _ in Data([1]) },
            progress: { _ in }
        )

        #expect(await streamer.imageCounts == [1])
        #expect(await streamer.texts.first??.isEmpty == false)
    }

    /// A stream that ended early still opens the editor, but says so rather than letting the
    /// athlete discover a missing exercise on their own.
    @Test func aTruncatedStreamReachesReviewCarryingAWarning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportFastPathTruncated-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let cut = Self.response.range(of: #"{"name":"Burpee"#)!.lowerBound
        let coordinator = WorkoutImportCoordinator(
            repository: FileWorkoutImportJobRepository(root: root),
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: RecordingWorkoutImportJobParser(),
            streamer: ScriptedStreamer(
                events: Self.fragments(of: String(Self.response[Self.response.startIndex..<cut]))
                    + [.failed(code: "remote_unavailable")]
            ),
            configuration: .init(pollingDelay: {})
        )

        let job = await coordinator.start(
            imageCount: 1,
            catalog: ExerciseCatalog.definitions,
            loadImage: { _ in Data([1]) },
            progress: { _ in }
        )

        #expect(job.stage == .reviewing)
        #expect(job.draft?.workout.allExercises.map(\.exerciseName) == ["Run"])
        #expect(job.issues.contains { $0.message.contains("stopped early") })
    }

    /// Progress reaches the UI as `.assembling` with a growing count, so the screen can show real
    /// rows while the model is still writing.
    @Test func theScreenIsToldAboutEachExerciseAsItResolves() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WorkoutImportFastPathProgress-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let stages = Collector()
        let coordinator = WorkoutImportCoordinator(
            repository: FileWorkoutImportJobRepository(root: root),
            normalizer: PassthroughWorkoutImageNormalizer(),
            recognizer: IndexedWorkoutTextRecognizer(),
            parser: RecordingWorkoutImportJobParser(),
            streamer: ScriptedStreamer(
                events: Self.fragments(of: Self.response, chunks: 40) + [.completed(model: nil)]
            ),
            configuration: .init(pollingDelay: {})
        )

        _ = await coordinator.start(
            imageCount: 1,
            catalog: ExerciseCatalog.definitions,
            loadImage: { _ in Data([1]) },
            progress: { job in
                guard job.stage == .assembling else { return }
                await stages.append(job.draft?.workout.allExercises.map(\.exerciseName) ?? [])
            }
        )

        let counts = await stages.snapshots.map(\.count)
        #expect(counts.contains { $0 > 0 }, "at least one exercise should have been shown mid-stream")
        #expect(counts == counts.sorted(), "the visible count must never go backwards")
    }

    // MARK: - Transport decoding

    @Test func serverSentLinesDecodeIntoEventsAndUnknownTypesAreIgnored() {
        typealias Parser = FirebaseWorkoutImportStreamingParser

        #expect(Parser.event(from: #"data: {"type":"delta","text":"{\"a\":1}"}"#) == .delta(#"{"a":1}"#))
        #expect(Parser.event(from: #"data: {"type":"done","model":"m"}"#) == .completed(model: "m"))
        #expect(Parser.event(from: #"data: {"type":"error","code":"rate_limited"}"#) == .failed(code: "rate_limited"))
        // A server that learns to send more must not break a shipped client.
        #expect(Parser.event(from: #"data: {"type":"heartbeat"}"#) == nil)
        #expect(Parser.event(from: "event: ping") == nil)
        #expect(Parser.event(from: "data: not json") == nil)
    }

    @Test func httpStatusesMapToCodesTheFailureScreenAlreadyExplains() {
        typealias Parser = FirebaseWorkoutImportStreamingParser

        #expect(Parser.failureCode(forStatus: 401) == "unauthenticated")
        #expect(Parser.failureCode(forStatus: 429) == "rate_limited")
        #expect(Parser.failureCode(forStatus: 400) == "malformed_payload")
        #expect(Parser.failureCode(forStatus: 500) == "remote_unavailable")
    }
}

// MARK: - Shared doubles
//
// Deliberately local to this file. The equivalents in WorkoutImportTests are private to that file,
// and duplicating three tiny doubles is cheaper than widening their visibility.

private struct PassthroughWorkoutImageNormalizer: WorkoutImageNormalizing {
    func normalize(_ data: Data) async throws -> ImportedWorkoutImage {
        ImportedWorkoutImage(data: data, pixelWidth: 100, pixelHeight: 100)
    }
}

private struct IndexedWorkoutTextRecognizer: WorkoutTextRecognizing {
    func recognize(image: ImportedWorkoutImage, sourceImageIndex: Int,
                   customWords: [String]) async throws -> [WorkoutTextObservation] {
        [WorkoutTextObservation(
            id: "page-\(sourceImageIndex)",
            text: "Run 400 m",
            confidence: 1,
            boundingBox: .init(x: 0, y: 0, width: 1, height: 0.1),
            sourceImageIndex: sourceImageIndex
        )]
    }
}

/// Completes immediately with one exercise, so a hand-off terminates and can be counted.
private actor RecordingWorkoutImportJobParser: WorkoutImportJobParsing {
    private var starts = 0

    func start(_ request: WorkoutImportRemoteStartRequest) async throws -> WorkoutImportRemoteStatus {
        starts += 1
        return completed(serverJobID: request.clientJobID, sections: request.sections.count)
    }

    func status(serverJobID: String) async throws -> WorkoutImportRemoteStatus {
        completed(serverJobID: serverJobID, sections: 1)
    }

    func retry(serverJobID: String, requestID: UUID) async throws -> WorkoutImportRemoteStatus {
        completed(serverJobID: serverJobID, sections: 1)
    }

    func cancel(serverJobID: String, requestID: UUID) async throws {}

    func startCallCount() -> Int { starts }

    private func completed(serverJobID: String, sections: Int) -> WorkoutImportRemoteStatus {
        WorkoutImportRemoteStatus(
            serverJobID: serverJobID,
            state: .completed,
            completedSections: sections,
            totalSections: sections,
            document: ParsedWorkoutDocument(title: "Durable", blocks: [
                ParsedWorkoutBlock(name: "Workout", exercises: [
                    ParsedWorkoutExercise(
                        name: "Run",
                        sets: [ParsedWorkoutSet(metrics: [.init(type: "distance", value: 400, unit: "meters")])]
                    ),
                ]),
            ]),
            model: "durable-model",
            failureCode: nil
        )
    }
}

/// Collects snapshots across concurrency domains.
private actor Collector {
    private(set) var snapshots: [[String]] = []
    func append(_ names: [String]) { snapshots.append(names) }
}
