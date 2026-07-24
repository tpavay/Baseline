import SwiftUI
import Testing
import UIKit
@testable import Baseline

@MainActor
struct WorkoutLogSummaryTests {

    @Test func strengthWorkoutSummaryAndTextUseCompletedSets() {
        let summary = ShareComposerFixtures.strengthSummary()

        #expect(summary.exerciseCount == 2)
        #expect(summary.totalSets == 3)
        #expect(summary.totalReps == 18)
        #expect(abs(summary.totalVolumeKilograms - 1570) < 0.001)
        #expect(summary.heaviestLoadKilograms == 100)
        #expect(summary.totalDistanceMeters == 0)

        let text = WorkoutShareTextSummary.make(from: summary, unitForMetric: ShareComposerFixtures.metricUnits)
        #expect(text.contains("Lower Strength"))
        #expect(text.contains("Duration: 01:12:00"))
        #expect(text.contains("Back Squat - 2 sets"))
        #expect(text.contains("1. 5 reps · 100 kg"))
        #expect(text.contains("Bench Press - 1 sets"))
    }

    @Test func cardioWorkoutSummaryAndTextIncludeDistanceDurationAndPace() {
        let summary = ShareComposerFixtures.cardioSummary()

        #expect(summary.exerciseCount == 1)
        #expect(summary.totalSets == 2)
        #expect(summary.totalReps == 0)
        #expect(summary.totalVolumeKilograms == 0)
        #expect(summary.totalDistanceMeters == 5000)
        #expect(summary.totalDurationSeconds == 1500)
        #expect(summary.averagePaceSecondsPerMeter == 0.3)

        let text = WorkoutShareTextSummary.make(from: summary, unitForMetric: ShareComposerFixtures.metricUnits)
        #expect(text.contains("5 km Progression"))
        #expect(text.contains("Distance: 5 km"))
        #expect(text.contains("Average pace: 5:00/km"))
        #expect(text.contains("Treadmill Run - 2 sets"))
        #expect(text.contains("1. 12:00 · 2.4 km · 5:00/km"))
    }
}

@MainActor
struct BaselineShareStatResolverTests {

    @Test func strengthStatsResolveAgainstBaselineMetrics() throws {
        let resolver = BaselineShareStatResolver(
            summary: ShareComposerFixtures.strengthSummary(),
            unitForMetric: ShareComposerFixtures.metricUnits
        )

        #expect(try #require(resolver.resolve(.duration)).value == "1h 12m")
        #expect(try #require(resolver.resolve(.totalSets)).value == "3")
        #expect(try #require(resolver.resolve(.totalReps)).value == "18")
        #expect(try #require(resolver.resolve(.totalVolume)).value == "1570 kg")
        #expect(try #require(resolver.resolve(.heaviestLoad)).value == "100 kg")
        #expect(resolver.resolve(.totalDistance) == nil)
        #expect(resolver.resolve(.avgPace) == nil)
    }

    @Test func cardioStatsOmitStrengthOnlyValues() throws {
        let resolver = BaselineShareStatResolver(
            summary: ShareComposerFixtures.cardioSummary(),
            unitForMetric: ShareComposerFixtures.metricUnits
        )

        #expect(try #require(resolver.resolve(.totalDistance)).value == "5 km")
        #expect(try #require(resolver.resolve(.totalDuration)).value == "25m")
        #expect(try #require(resolver.resolve(.avgPace)).value == "5:00/km")
        #expect(resolver.resolve(.totalVolume) == nil)
        #expect(resolver.resolve(.heaviestLoad) == nil)
        #expect(resolver.availableKinds().contains(.workoutName))
    }
}

@MainActor
struct ShareComposerRenderTests {

    @Test func rendererProducesStorySizedBaselineCard() async throws {
        let viewModel = ShareComposerViewModel(
            summary: ShareComposerFixtures.strengthSummary(),
            unitForMetric: ShareComposerFixtures.metricUnits
        )
        let image = try #require(await ShareComposerExporter().renderImage(viewModel: viewModel))

        #expect(image.size.width == 1080)
        #expect(image.size.height == 1920)
        try ShareComposerFixtures.write(image, named: "share-card-render")
    }

    @Test func copyAndShareSheetWiringWorkFromHostedComposer() async throws {
        let screen = try ShareComposerScreen(summary: ShareComposerFixtures.strengthSummary())
        defer { screen.tearDown() }
        try await screen.settle()
        try screen.capture("share-composer-card")

        UIPasteboard.general.string = nil
        #expect(screen.activate(labelled: "Copy workout text"))
        try await screen.settle()
        #expect(UIPasteboard.general.string?.contains("Lower Strength") == true)

        #expect(screen.activate(labelled: "Share workout text"))
        try await screen.settleUntil(timeout: 5) { screen.presentedShareSheet != nil }
        screen.presentedShareSheet?.dismiss(animated: false)
        try await screen.settle()

        #expect(screen.activate(labelled: "Share workout image"))
        try await screen.settleUntil(timeout: 5) { screen.presentedShareSheet != nil }
        try await screen.settle()
        try screen.capture("share-composer-share-sheet")
        screen.presentedShareSheet?.dismiss(animated: false)
    }
}

@MainActor
private enum ShareComposerFixtures {
    static let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    static let finishedAt = startedAt.addingTimeInterval(4_320)

    static func strengthSummary() -> WorkoutLogSummary {
        WorkoutLogSummary(
            title: "Lower Strength",
            log: WorkoutLog(exercises: [
                PerformedExercise(
                    exerciseName: "Back Squat",
                    setLogs: [
                        SetLog(reps: 5, load: 100, outcome: .completed),
                        SetLog(reps: 5, load: 100, outcome: .completed),
                        SetLog(reps: 5, load: 100, outcome: .skipped)
                    ]
                ),
                PerformedExercise(
                    exerciseName: "Bench Press",
                    setLogs: [
                        SetLog(reps: 8, load: 71.25, outcome: .completed)
                    ]
                )
            ], isComplete: true),
            startedAt: startedAt,
            finishedAt: finishedAt,
            unitForMetric: metricUnits
        )
    }

    static func cardioSummary() -> WorkoutLogSummary {
        WorkoutLogSummary(
            title: "5 km Progression",
            log: WorkoutLog(exercises: [
                PerformedExercise(
                    exerciseName: "Treadmill Run",
                    setLogs: [
                        SetLog(duration: 720, distance: 2_400, outcome: .completed),
                        SetLog(duration: 780, distance: 2_600, outcome: .completed)
                    ]
                )
            ], isComplete: true),
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(1_620),
            unitForMetric: metricUnits
        )
    }

    static func metricUnits(_ metric: MetricType) -> MetricUnit {
        switch metric {
        case .distance:
            return .kilometers
        case .pace:
            return .secondsPerKilometer
        case .load:
            return .kilograms
        default:
            return metric.canonicalUnit
        }
    }

    static func write(_ image: UIImage, named name: String) throws {
        let data = try #require(image.pngData())
        let url = AccessibilityElementWalker.evidenceDirectory.appendingPathComponent("\(name).png")
        try data.write(to: url, options: .atomic)
        print("SCREENSHOT \(url.path)")
    }
}

@MainActor
private final class ShareComposerScreen: HostedScreen {
    let window: UIWindow

    init(summary: WorkoutLogSummary) throws {
        window = try Self.makeWindow(
            rootView: ShareComposerView(summary: summary, unitForMetric: ShareComposerFixtures.metricUnits)
                .preferredColorScheme(.dark)
        )
    }

    var presentedShareSheet: UIActivityViewController? {
        var presenter = window.rootViewController
        while let presented = presenter?.presentedViewController {
            if let activity = presented as? UIActivityViewController {
                return activity
            }
            presenter = presented
        }
        return nil
    }
}
