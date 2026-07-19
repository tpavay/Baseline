import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// Drives the real onboarding Units step the way an athlete meets it: it appears pre-selected on the
/// system the device locale implies, seeds the body-unit toggles the moment it is shown (so accepting
/// the pre-selected card without tapping still works), and flips the whole profile to metric when the
/// other card is tapped. Everything goes through `UnitsStepView` itself, hosted in a scene-attached
/// window, and each state writes a PNG so the screen can be looked at, not only asserted about.
@MainActor
struct UnitsStepRenderTests {

    /// On first appearance the step commits the locale-derived choice and seeds the two body-unit
    /// flags — the review fix: an athlete who taps NEXT without touching a card is still set up
    /// coherently.
    @Test func firstAppearanceSeedsBodyUnitsFromThePreselectedCard() async throws {
        let screen = try await UnitsScreen()
        defer { screen.tearDown() }

        #expect(screen.store.draft.unitSystemRaw != nil, "The step must commit a concrete choice on entry.")
        let system = screen.store.draft.unitSystem
        #expect(screen.store.draft.metricHeight == (system == .metric))
        #expect(screen.store.draft.metricWeight == (system == .metric))

        #expect(screen.card("Imperial") != nil)
        #expect(screen.card("Metric") != nil)
        screen.capture("01-units-step-default-\(system.rawValue)")
    }

    @Test func tappingMetricSelectsItAndFlipsBodyUnitsToMetric() async throws {
        let screen = try await UnitsScreen()
        defer { screen.tearDown() }

        try screen.tapCard("Metric")
        #expect(screen.store.draft.unitSystem == .metric)
        #expect(screen.store.draft.metricHeight == true)
        #expect(screen.store.draft.metricWeight == true)
        screen.capture("02-units-step-metric-selected")

        try screen.tapCard("Imperial")
        #expect(screen.store.draft.unitSystem == .imperial)
        #expect(screen.store.draft.metricHeight == false)
        #expect(screen.store.draft.metricWeight == false)
        screen.capture("03-units-step-imperial-selected")
    }
}

// MARK: - Harness

@MainActor
private final class UnitsScreen {
    private let window: UIWindow
    private let defaults: UserDefaults
    private let suiteName = "UnitsStepRenderTests"
    let store: OnboardingStore

    init() async throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        // Seed the persisted step so the store's chrome/progress reflects the units step.
        defaults.set(OnboardingStep.units.rawValue, forKey: "onboarding.step")
        store = OnboardingStore(defaults: defaults)

        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        let root = UnitsStepView(store: store)
            .preferredColorScheme(.dark)

        window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        try await settle(until: { [weak self] in self?.card("Metric") != nil })
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        defaults.removePersistentDomain(forName: suiteName)
    }

    func card(_ title: String) -> NSObject? {
        UnitsScreen.elements(in: window).first {
            ($0.accessibilityLabel?.contains(title) ?? false) && $0.accessibilityTraits.contains(.button)
        }
    }

    func tapCard(_ title: String) throws {
        let element = try #require(card(title), "No card labelled \"\(title)\" on screen.")
        #expect(element.accessibilityActivate())
        flush()
    }

    func capture(_ name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else { return }
        let url = UnitsScreen.evidenceDirectory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        print("SCREENSHOT \(url.path)")
    }

    private static let evidenceDirectory: URL = {
        let base = ProcessInfo.processInfo.environment["BASELINE_EVIDENCE_DIR"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("units-step")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private func spin(_ seconds: TimeInterval) {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
    }

    private func flush() { spin(0.4) }

    private func settle(until condition: () -> Bool, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            spin(0.1)
            await Task.yield()
            if condition() { flush(); return }
        }
        Issue.record("Units step never appeared.")
    }

    private static func allViews(in root: UIView) -> [UIView] {
        root.subviews.reduce(into: [root]) { $0 += allViews(in: $1) }
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
