import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// Renders the morning weight step the way the flow presents it - dark, full-screen, on the
/// base background - and captures evidence for both unit systems plus the out-of-range hint.
@MainActor
@Suite(.serialized)
struct MorningWeightEntryRenderTests {

    @Test(arguments: [UnitSystem.metric, .imperial])
    func rendersPrefilledEntry(_ system: UnitSystem) async throws {
        let screen = try WeightEntryScreen(system: system, fallbackKilograms: 81.6466)
        defer { screen.tearDown() }
        try await screen.settle()

        // The prefill shows in the athlete's unit - the same number, never the same digits.
        let expected = MetricFormat.editText(81.6466, .load, unit: system.displayUnit(metric: .load, exercise: nil))
        #expect(screen.element(labelled: expected) != nil)
        #expect(screen.element(labelled: "SKIP") != nil)
        #expect(screen.element(labelled: "SAVE WEIGHT") != nil)

        try screen.capture("morning-weight-\(system.rawValue)")
    }

    @Test func rendersRangeHintForATypo() async throws {
        let screen = try WeightEntryScreen(system: .metric, fallbackKilograms: nil, text: "8000")
        defer { screen.tearDown() }
        try await screen.settle()

        #expect(screen.element(labelled: "Enter a weight between") != nil)
        try screen.capture("morning-weight-invalid")
    }
}

@MainActor
private final class WeightEntryScreen {
    private let window: UIWindow

    init(system: UnitSystem, fallbackKilograms: Double?, text: String? = nil) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: "weight-render-\(UUID().uuidString)")))
        settings.unitSystem = system

        // The view's recorder reads its prefill cache from standard defaults; clear it so a
        // previous run in this host app can never outrank the fallback under test.
        for key in ["checkin.weight.lastEnteredKilograms", "checkin.weight.lastSyncIdentifier",
                    "checkin.weight.lastSyncVersion", "checkin.weight.lastSavedKilograms"] {
            UserDefaults.standard.removeObject(forKey: key)
        }

        let root = WeightEntryRoot(fallbackKilograms: fallbackKilograms, initialText: text)
            .environment(settings)
            .environment(HealthService(defaults: try #require(UserDefaults(suiteName: "weight-render-health-\(UUID().uuidString)"))))
            .preferredColorScheme(.dark)

        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// Matches label or value - a text field carries its content as its accessibility *value*.
    func element(labelled text: String) -> NSObject? {
        Self.elements(in: window).first {
            ($0.accessibilityLabel?.contains(text) ?? false) || ($0.accessibilityValue?.contains(text) ?? false)
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

/// Hosts the step exactly as the flow does: on the base background, with a bindable text seed so
/// the invalid state is reachable without a keyboard.
private struct WeightEntryRoot: View {
    let fallbackKilograms: Double?
    let initialText: String?

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            MorningWeightEntryView(
                profileFallbackKilograms: fallbackKilograms,
                initialText: initialText,
                onSave: { _ in },
                onSkip: {}
            )
        }
    }
}
