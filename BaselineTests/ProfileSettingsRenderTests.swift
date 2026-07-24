import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// Profile settings sheet, reached the way the athlete reaches it: open Profile, tap the gear.
/// Two regressions from the Profile redesign are pinned here:
/// - the METRIC / IMPERIAL unit segments must each render on a single line (the row used to
///   starve `Segmented2` of width and "IMPERIAL" broke across two lines), and
/// - the dead "Appearance" row is gone from the sheet entirely.
///
/// Hosted in a scene-attached window because sign-in gates a plain launch and `ImageRenderer`
/// cannot rasterize the sheet's `ScrollView`.
@MainActor
@Suite(.serialized)
struct ProfileSettingsRenderTests {

    /// A single-line segment is its 11 pt mono label plus 7 pt vertical padding — well under 34 pt.
    /// A wrapped label pushes the segment past 40 pt, so the bound separates the two states cleanly.
    private static let singleLineSegmentMaxHeight: CGFloat = 34

    @Test(arguments: [DynamicTypeSize.large, DynamicTypeSize.xxLarge])
    func unitSegmentsRenderOnOneLine(_ size: DynamicTypeSize) async throws {
        let screen = try ProfileSettingsScreen(dynamicTypeSize: size)
        defer { screen.tearDown() }
        try await screen.openSettings()

        let metric = try #require(screen.element(labelled: "METRIC"), "the METRIC segment is not on screen")
        let imperial = try #require(screen.element(labelled: "IMPERIAL"), "the IMPERIAL segment is not on screen")
        for (name, segment) in [("METRIC", metric), ("IMPERIAL", imperial)] {
            #expect(segment.accessibilityFrame.height <= Self.singleLineSegmentMaxHeight,
                    "\(name) wrapped: segment is \(segment.accessibilityFrame.height) pt tall")
            // A segment starved of width would be narrower than its own single-line label.
            let ideal = (name as NSString).size(withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .bold), .kern: 1,
            ]).width
            #expect(segment.accessibilityFrame.width >= ideal,
                    "\(name) is compressed below its single-line label width")
        }
        // Both segments sit on the same row of one control.
        #expect(abs(metric.accessibilityFrame.midY - imperial.accessibilityFrame.midY) < 1)

        if size == .large {
            try await screen.scrollSettingsToBottom()
            try screen.capture("profile-settings-units")
        }
    }

    @Test func settingsHasNoAppearanceRow() async throws {
        let screen = try ProfileSettingsScreen()
        defer { screen.tearDown() }
        try await screen.openSettings()

        #expect(screen.element(labelled: "Appearance") == nil,
                "the Appearance row should be removed from the settings sheet")
        // The rest of the Integrations group is untouched.
        #expect(screen.element(labelled: "Apple Health") != nil)
        #expect(screen.element(labelled: "Notifications") != nil)
        try screen.capture("profile-settings")
    }
}

@MainActor
private final class ProfileSettingsScreen {
    private let window: UIWindow
    private let container: ModelContainer

    init(dynamicTypeSize: DynamicTypeSize = .large) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: "profile-settings-\(UUID().uuidString)")))
        let root = ProfileView()
            .environment(OnboardingStore(defaults: try #require(UserDefaults(suiteName: "profile-settings-ob-\(UUID().uuidString)"))))
            .environment(AuthViewModel())
            .environment(settings)
            .environment(BluetoothManager())
            .environment(HealthService())
            .environment(PlanStore(context: container.mainContext))
            .environment(HeartRateZoneSettingsStore(defaults: .previewEmpty, ageYears: { 28 }))
            .modelContainer(container)
            .dynamicTypeSize(dynamicTypeSize)
            .preferredColorScheme(.dark)

        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
    }

    func openSettings() async throws {
        try await settle()
        #expect(activate(labelled: "Settings"), "the Settings gear did not activate")
        try await settle()
        #expect(element(labelled: "Measurement system") != nil, "the settings sheet did not open")
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// Scrolls the settings sheet to its end so the Units group is in frame for capture. The sheet's
    /// list is the tallest scrollable surface on screen, which is how it is told apart from the
    /// Profile dashboard's own scroll view underneath it.
    func scrollSettingsToBottom() async throws {
        var scrollViews: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView { scrollViews.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(window)
        let sheet = try #require(scrollViews.max { $0.contentSize.height < $1.contentSize.height },
                                 "no scroll view found in the settings sheet")
        let bottom = max(0, sheet.contentSize.height - sheet.bounds.height + sheet.adjustedContentInset.bottom)
        sheet.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        try await settle()
    }

    func element(labelled text: String) -> NSObject? {
        Self.elements(in: window).first { $0.accessibilityLabel?.contains(text) ?? false }
    }

    func activate(labelled text: String) -> Bool {
        element(labelled: text)?.accessibilityActivate() ?? false
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
