import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// End-to-end evidence for the rebuilt photo import, rendered through the real `WorkoutImportView`.
///
/// These tests drive the same screen an athlete sees, staged from a real corpus sketch pushed
/// through the real streaming assembler and the real conversion layer - no hand-built drafts. The
/// screenshots they write are the reviewable proof of the three claims that are otherwise only
/// visible as assertions: rows appear as the stream resolves and never get rewritten, a failed
/// import says what went wrong and offers a working retry instead of synthesizing a workout, and an
/// imported workout is displayed in the athlete's own units rather than the source's.
///
/// Hosted in a scene-attached window because sign-in gates a plain launch and an unattached window
/// renders blank. Mirrors `WorkoutImportKeepAwakeRenderTests`.
@MainActor
struct WorkoutImportEvidenceRenderTests {

    private final class BundleToken {}

    /// The VO2 session from `data/baseline-import-latency-p5/report.md`, read out of the shipped
    /// corpus fixture so the evidence and the pinned expectations cannot drift apart.
    ///
    /// The sketch is lifted out of the file as raw text rather than re-encoded, because key order is
    /// the thing being replayed: a real stream delivers the title before the blocks, and re-encoding
    /// would alphabetize that away and make the screen look like it read the workout backwards.
    private static func corpusSketchJSON(named name: String) throws -> String {
        let urls = Bundle(for: BundleToken.self).urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let probe = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  probe["name"] as? String == name,
                  let text = String(data: data, encoding: .utf8),
                  let key = text.range(of: "\"sketch\"") else { continue }
            guard let start = text[key.upperBound...].firstIndex(of: "{") else { continue }
            var depth = 0
            var inString = false
            var escaped = false
            for index in text[start...].indices {
                let character = text[index]
                if escaped { escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if character == "\"" { inString.toggle(); continue }
                guard !inString else { continue }
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                }
            }
        }
        Issue.record("corpus case \(name) not found in the test bundle; run xcodegen generate")
        throw CocoaError(.fileNoSuchFile)
    }

    private struct Checkpoint {
        var exerciseCount: Int
        var draft: WorkoutTemplateDraft
    }

    /// Replays the sketch through `WorkoutImportSketchStream` a character at a time and snapshots the
    /// draft each time a whole new exercise resolves - exactly the sequence `WorkoutImportFastPath`
    /// publishes to the screen.
    private static func streamCheckpoints(_ json: String) -> [Checkpoint] {
        let catalog = ExerciseCatalog.definitions
        var stream = WorkoutImportSketchStream()
        var shown = 0
        var out: [Checkpoint] = []
        for character in json {
            guard let sketch = stream.append(String(character)) else { continue }
            let converted = WorkoutImportSketchConverter.convert(sketch, catalog: catalog)
            let count = converted.document.blocks.flatMap(\.exercises).count
            guard count > shown else { continue }
            shown = count
            out.append(
                Checkpoint(
                    exerciseCount: count,
                    draft: WorkoutImportDraftBuilder.build(converted.document, catalog: catalog).draft
                )
            )
        }
        if let finished = stream.finish() {
            let converted = WorkoutImportSketchConverter.convert(finished, catalog: catalog)
            out.append(
                Checkpoint(
                    exerciseCount: converted.document.blocks.flatMap(\.exercises).count,
                    draft: WorkoutImportDraftBuilder.build(converted.document, catalog: catalog).draft
                )
            )
        }
        return out
    }

    /// The streaming screen, captured at each point a new exercise landed. Every capture is the
    /// editor's own row components over the real parsed draft, and each one is the previous screen
    /// plus rows - the promise that nothing an athlete has already read gets rewritten.
    @Test func streamingShowsRealRowsAsExercisesResolveAndNeverRewritesOne() async throws {
        let checkpoints = Self.streamCheckpoints(try Self.corpusSketchJSON(named: "vo2-thresholds"))
        #expect(checkpoints.count >= 4, "the stream should publish each exercise as it resolves")

        var previousNames: [String] = []
        for checkpoint in checkpoints {
            let names = checkpoint.draft.workout.allExercises.map(\.exerciseName)
            #expect(
                Array(names.prefix(previousNames.count)) == previousNames,
                "a row already on screen changed: \(previousNames) → \(names)"
            )
            previousNames = names

            var session = ImportSession()
            session.draft = checkpoint.draft
            session.status = .assembling(exerciseCount: checkpoint.exerciseCount)

            let screen = try await WorkoutImportScreen(
                session: session,
                settleOn: "Reading your workout"
            )
            defer { screen.tearDown() }
            screen.capture(String(format: "stream-%02d-%d-exercises", checkpoint.exerciseCount, names.count))
        }

        // The names the corpus pins for this workout: "Strides" resolves onto the catalog's running
        // movement, and nothing else is renamed.
        #expect(previousNames == ["Run", "Run", "Run", "Burpee Broad Jump"])
    }

    /// The finished import, opened for editing on exactly the rows the stream put on screen.
    @Test func readingFinishingOpensTheEditorOnTheSameRows() async throws {
        let checkpoints = Self.streamCheckpoints(try Self.corpusSketchJSON(named: "vo2-thresholds"))
        let final = try #require(checkpoints.last)

        var session = ImportSession()
        session.draft = final.draft
        session.status = .reviewing

        let screen = try await WorkoutImportScreen(session: session, settleOn: "Review Workout")
        defer { screen.tearDown() }
        screen.capture("review-editor-open")

        #expect(session.canSave, "a fully resolved corpus workout must be savable")
        #expect(
            screen.showsText(containing: "Add Set"),
            "reading finishing must hand over real editable rows, not a read-only preview"
        )
    }

    /// The units fix, shown rather than asserted: one workout written in kilometres, rendered for a
    /// metric athlete and an imperial athlete. The source no longer decides.
    @Test(arguments: [UnitSystem.metric, UnitSystem.imperial])
    func anImportedWorkoutIsDisplayedInTheAthletesOwnUnits(system: UnitSystem) async throws {
        let checkpoints = Self.streamCheckpoints(try Self.corpusSketchJSON(named: "vo2-thresholds"))
        let final = try #require(checkpoints.last)

        #expect(
            final.draft.workout.allExercises.allSatisfy { $0.displayUnits.isEmpty },
            "an imported exercise must carry no per-instance display-unit override"
        )

        var session = ImportSession()
        session.draft = final.draft
        session.status = .assembling(exerciseCount: final.exerciseCount)

        let screen = try await WorkoutImportScreen(
            session: session,
            unitSystem: system,
            settleOn: "Reading your workout"
        )
        defer { screen.tearDown() }
        screen.capture("units-\(system.rawValue)")
    }

    /// The hybrid day from `data/baseline-workout-structure-reference.md`, rendered tall enough to
    /// read in one frame. It is the case that shows the conversion layer's refusals: rep ranges and
    /// pace targets stay coach prose rather than becoming typed metrics, the three-leg sled
    /// prescription stays prose rather than collapsing into one 12.5 m set, and a name the catalog
    /// could not place honestly is left for the athlete instead of being snapped to a near-miss.
    @Test func theHybridDayKeepsCoachProseAndRefusesToGuessNames() async throws {
        let checkpoints = Self.streamCheckpoints(try Self.corpusSketchJSON(named: "bayens-intensity-day"))
        let final = try #require(checkpoints.last)

        var session = ImportSession()
        session.draft = final.draft
        session.status = .assembling(exerciseCount: final.exerciseCount)

        let screen = try await WorkoutImportScreen(session: session, settleOn: "Reading your workout")
        defer { screen.tearDown() }
        // The workout is longer than a phone screen, so it is captured as the athlete would read it.
        // Rows are lazily realized, so what is on screen is collected at each stop.
        var seen: Set<String> = []
        for (index, offset) in [0.0, 700.0, 1_400.0, 2_100.0].enumerated() {
            screen.scroll(to: offset)
            screen.capture(String(format: "hybrid-day-%02d", index + 1))
            seen.formUnion(screen.visibleText())
        }

        for prose in ["6-8 reps", "8-12 reps", "3-5km pace", "12.5m Sled Push / 12.5m Sled Drag / 12.5m Sled Push"] {
            #expect(seen.contains { $0.contains(prose) }, "coach text must survive verbatim: \(prose)")
        }
    }

    /// A name the matcher refused to place does not quietly become a near-miss: it reaches the
    /// athlete as a blocking review item, and saving stays shut until they choose.
    @Test func aNameBaselineWouldNotGuessBlocksTheSaveAndAsksTheAthlete() async throws {
        let json = try Self.corpusSketchJSON(named: "bayens-intensity-day")
        let catalog = ExerciseCatalog.definitions
        var stream = WorkoutImportSketchStream()
        _ = stream.append(json)
        let converted = WorkoutImportSketchConverter.convert(try #require(stream.finish()), catalog: catalog)
        let built = WorkoutImportDraftBuilder.build(converted.document, catalog: catalog)

        #expect(converted.unresolvedNames.isEmpty == false, "this case exists because one name is refused")

        var session = ImportSession()
        session.draft = built.draft
        session.issues = built.issues
        session.status = .reviewing

        let screen = try await WorkoutImportScreen(session: session, settleOn: "Review Workout")
        defer { screen.tearDown() }
        screen.scroll(to: 100_000)
        screen.capture("unresolved-exercise-blocks-save")

        #expect(!session.canSave, "a refused name must block saving rather than be guessed away")
        #expect(
            screen.showsText(containing: "Resolve Items to Save"),
            "the save affordance must say why it is unavailable"
        )
    }

    /// Phase one's failure state. There is no fallback synthesis behind this screen any more: it
    /// names what went wrong in the athlete's language and offers a retry that works.
    @Test func aFailedImportExplainsItselfAndOffersARetryInsteadOfGuessing() async throws {
        var job = WorkoutImportJob(stage: .processingSections, expectedPageCount: 1)
        job.failure = WorkoutImportFailure(
            stage: "review",
            reasonCode: "unusable_structured_result",
            isRetryable: true
        )

        var session = ImportSession()
        session.status = .failed(
            message: "Baseline read the photos but could not turn them into a workout it trusts, "
                + "so it did not guess. Try again, or start over with clearer or more tightly cropped photos."
        )

        let screen = try await WorkoutImportScreen(
            session: session,
            job: job,
            settleOn: "Import didn't finish"
        )
        defer { screen.tearDown() }
        screen.capture("failure-honest-and-retryable")

        #expect(screen.showsText(containing: "did not guess"), "the failure must say Baseline refused to guess")
        #expect(screen.showsText(containing: "Try again"), "a retryable failure must offer the retry")
    }
}

// MARK: - Harness

/// The real `WorkoutImportView` staged into a given session through its debug initializer, hosted in
/// a real scene-attached window.
@MainActor
private final class WorkoutImportScreen {
    private let window: UIWindow
    private let defaults: UserDefaults
    private let suiteName: String
    private let container: ModelContainer

    init(
        session: ImportSession,
        job: WorkoutImportJob? = nil,
        unitSystem: UnitSystem = .metric,
        settleOn marker: String
    ) async throws {
        suiteName = "WorkoutImportEvidenceRenderTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        let store = WorkoutStore(units: StubUnitSystem(unitSystem), defaults: defaults)
        let root = WorkoutImportView(debugSession: session, debugJob: job)
            .environment(store)
            .environment(PlanStore(context: container.mainContext))
            .preferredColorScheme(.dark)

        window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()

        try await settle(until: { [weak window] in
            guard let window else { return false }
            return WorkoutImportScreen.elements(in: window).contains {
                $0.accessibilityLabel?.contains(marker) == true
            }
        })
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        spin(0.2)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func visibleText() -> [String] {
        WorkoutImportScreen.elements(in: window).compactMap(\.accessibilityLabel)
    }

    func showsText(containing needle: String) -> Bool {
        WorkoutImportScreen.elements(in: window).contains {
            $0.accessibilityLabel?.contains(needle) == true
        }
    }

    /// Scrolls the screen's list the way a thumb would, so a workout longer than the phone can be
    /// captured in full. Clamped to the content, so an over-long offset lands on the last screen.
    func scroll(to offset: CGFloat) {
        guard let scrollView = WorkoutImportScreen.firstScrollView(in: window) else { return }
        let maximum = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        scrollView.setContentOffset(CGPoint(x: 0, y: min(offset, maximum)), animated: false)
        spin(0.3)
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    func capture(_ name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else { return }
        let url = WorkoutImportScreen.evidenceDirectory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        print("SCREENSHOT \(url.path)")
    }

    private static let evidenceDirectory: URL = {
        let base = ProcessInfo.processInfo.environment["BASELINE_EVIDENCE_DIR"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("workout-import-evidence")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private func spin(_ seconds: TimeInterval) {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
    }

    private func settle(until condition: () -> Bool, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            spin(0.1)
            await Task.yield()
            if condition() { spin(0.4); return }
        }
        Issue.record("WorkoutImportView never finished rendering.")
    }

    private static func elements(in root: UIView) -> [NSObject] {
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()

        func walk(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView {
                if view.isAccessibilityElement { out.append(view) }
                (view.accessibilityElements as? [NSObject])?.forEach(walk)
                view.subviews.forEach(walk)
            } else {
                out.append(object)
                let count = object.accessibilityElementCount()
                guard count != NSNotFound, count > 0 else { return }
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { walk(child) }
                }
            }
        }
        walk(root)
        return out
    }
}
