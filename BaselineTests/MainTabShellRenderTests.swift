import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// Renders the real signed-in shell — `MainTabView`, not an extracted tab — so the floating bar's
/// relationship to the system tab bar and each tab's bottom content is exercised where it actually
/// runs. The system bar must never be visible beneath the floating bar, and every tab must publish
/// the floating bar's controls in the accessibility tree.
@MainActor
@Suite(.serialized)
struct MainTabShellRenderTests {
    @Test(arguments: MainTab.allCases)
    func theShellShowsOnlyTheFloatingTabBar(_ tab: MainTab) async throws {
        let screen = try MainTabShellScreen(tab: tab)
        defer { screen.tearDown() }
        try await screen.settle()

        #expect(screen.visibleSystemTabBars.isEmpty)
        for title in MainTab.allCases.map(\.title) {
            #expect(screen.element(labelled: title) != nil)
        }
        if tab == .plan {
            let chat = try #require(screen.element(labelled: "Ask about your week"))
            let barTop = try #require(screen.element(labelled: MainTab.today.title)).accessibilityFrame.minY
            #expect(chat.accessibilityFrame.maxY <= barTop)
        }
        try screen.capture("shell-\(tab.title.lowercased())")
    }
}

@MainActor
private final class MainTabShellScreen {
    private let window: UIWindow
    private let container: ModelContainer

    init(tab: MainTab) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self]
            + PlanSchema.models + SleepSchema.models
        container = try ModelContainer(
            for: Schema(models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let root = MainTabView(initialSelection: tab)
            .environment(AuthViewModel())
            .environment(AppSettings())
            .environment(BluetoothManager())
            .environment(HealthService())
            .environment(TrainingContextStore())
            .environment(OnboardingStore())
            .environment(WorkoutStore(units: AppSettings()))
            .environment(PlanStore(context: container.mainContext))
            .modelContainer(container)
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

    var visibleSystemTabBars: [UITabBar] {
        var bars: [UITabBar] = []
        func walk(_ view: UIView) {
            if let bar = view as? UITabBar,
               !bar.isHidden,
               bar.alpha > 0,
               bar.frame.intersects(window.bounds.insetBy(dx: 0, dy: 1)) {
                bars.append(bar)
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        return bars
    }

    func element(labelled text: String) -> NSObject? {
        Self.elements(in: window).first { $0.accessibilityLabel?.contains(text) ?? false }
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
