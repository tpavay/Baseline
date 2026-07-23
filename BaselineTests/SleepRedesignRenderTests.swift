import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// Renders the redesigned sleep surfaces in an app-hosted window and captures evidence screenshots:
/// the Today sleep card (band word + ring), the sleep detail (score + band headline, breakdown with
/// the inline ⓘ, staged hypnogram), and the About screen the ⓘ opens.
@MainActor
@Suite(.serialized)
struct SleepRedesignRenderTests {

    @Test func sleepDetailShowsBandBreakdownInfoButtonAndHypnogram() async throws {
        let screen = try SleepRenderScreen(root: AnyView(
            NavigationStack {
                SleepDetailView(night: SleepPreviewFixtures.stagedNight,
                                analysis: SleepPreviewFixtures.stagedAnalysis,
                                decision: SleepPreviewFixtures.cappedDecision)
            }
            .preferredColorScheme(.dark)
        ))
        defer { screen.tearDown() }
        try await screen.settle()

        // Score + post-26.2 band in the headline; no reliability badge anywhere.
        let headline = try #require(screen.element(labelled: "Sleep score"))
        #expect(headline.accessibilityLabel?.contains("High") == true)
        #expect(screen.element(labelled: "reliability") == nil)

        // Breakdown rows carry the human subtitles, and the ⓘ sits inline in the card.
        // (The staged fixture sleeps 7h 18m against an 8 h need → the short-of-goal reading.)
        #expect(screen.element(labelled: "short of your sleep goal") != nil)
        #expect(screen.element(labelled: "awake") != nil)
        #expect(screen.element(labelled: "How your score works") != nil)

        // The staged hypnogram replaced the single-track overnight bar.
        let hypnogram = try #require(screen.element(labelled: "Sleep stage hypnogram"))
        #expect(hypnogram.accessibilityValue?.contains("Core") == true)

        // The old stat boxes are gone.
        #expect(screen.element(labelled: "Awake in bed") == nil)
        #expect(screen.element(labelled: "Time asleep") == nil)

        try screen.capture("sleep-detail")
    }

    @Test func sleepAboutExplainsComponentsBandsAndExclusions() async throws {
        let screen = try SleepRenderScreen(root: AnyView(
            NavigationStack { SleepScoreAboutView(score: 78) }
                .preferredColorScheme(.dark)
        ))
        defer { screen.tearDown() }
        try await screen.settle()

        #expect(screen.element(labelled: "Duration, up to 50 pts") != nil)
        #expect(screen.element(labelled: "Bedtime consistency, up to 30 pts") != nil)
        #expect(screen.element(labelled: "Interruptions, up to 20 pts") != nil)
        let bands = try #require(screen.element(labelled: "Where 78 lands"))
        #expect(bands.accessibilityLabel?.contains("OK") == true)
        #expect(bands.accessibilityLabel?.contains("81–95") == true)

        try screen.capture("sleep-about")
    }

    @Test func soloSleepCardLeadsWithBandAndRingOnTheRight() async throws {
        let model = try #require(TodaySleepCardModel.make(SleepPreviewFixtures.stagedAnalysis))
        let screen = try SleepRenderScreen(root: AnyView(
            VStack {
                TodaySleepCardView(model: model, isSolo: true)
                Spacer()
            }
            .padding(BaselineSpacing.screen)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BaselineColor.base)
            .preferredColorScheme(.dark)
        ))
        defer { screen.tearDown() }
        try await screen.settle()

        let card = try #require(screen.element(labelled: "Sleep score"))
        // Band word + "asleep" duration line; the old reliability caption is gone.
        #expect(card.accessibilityLabel?.contains("asleep") == true)
        #expect(card.accessibilityLabel?.contains("reliability") == false)

        try screen.capture("sleep-card-solo")
    }
}

// MARK: - Host

@MainActor
private final class SleepRenderScreen {
    private let window: UIWindow

    init(root: AnyView) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    func element(labelled text: String) -> NSObject? {
        Self.elements(in: window).first {
            $0.accessibilityLabel?.contains(text) ?? false
        }
    }

    func capture(_ name: String) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        let url = Self.evidenceDirectory.appendingPathComponent("\(name).png")
        try data.write(to: url, options: .atomic)
        print("SCREENSHOT \(url.path)")
    }

    func settle() async throws {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            spin(0.05)
            await Task.yield()
        }
        spin(0.1)
    }

    private func spin(_ seconds: TimeInterval) {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
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

    private static func elements(in root: UIView) -> [NSObject] {
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()

        func walk(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView {
                if view.isAccessibilityElement { result.append(view) }
                (view.accessibilityElements as? [NSObject])?.forEach(walk)
                view.subviews.forEach(walk)
            } else {
                result.append(object)
                let count = object.accessibilityElementCount()
                guard count != NSNotFound, count > 0 else { return }
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject {
                        walk(child)
                    }
                }
            }
        }

        walk(root)
        return result
    }
}
