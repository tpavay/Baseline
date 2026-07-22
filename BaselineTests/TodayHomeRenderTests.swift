import SwiftUI
import Testing
import UIKit
@testable import Baseline

@MainActor
@Suite(.serialized)
struct TodayHomeRenderTests {
    @Test(arguments: TodayEvidenceState.allCases)
    func rendersApprovedAvailabilityState(_ state: TodayEvidenceState) async throws {
        let model = state.model
        #expect(model.readings.count == state.expectedReadingCount)
        if state == .none {
            #expect(model.readings.isEmpty)
        }

        let screen = try TodayEvidenceScreen(model: model)
        defer { screen.tearDown() }
        try await screen.settle()

        #expect(screen.element(labelled: "Good morning, Tyler") != nil)
        #expect(screen.element(labelled: "Today's plan") != nil)
        #expect(screen.element(labelled: "Sleep score") != nil || !state.includesSleep)
        #expect(screen.element(labelled: "HRV 68 milliseconds") != nil || !state.includesHRV)
        if state == .none {
            #expect(screen.element(labelled: "Sleep score") == nil)
            #expect(screen.element(labelled: "HRV 68 milliseconds") == nil)
        }

        try screen.capture(state.filename)
    }
}

enum TodayEvidenceState: String, CaseIterable {
    case full
    case sleep
    case hrv
    case none

    var filename: String { "today-\(rawValue)" }
    var includesSleep: Bool { self == .full || self == .sleep }
    var includesHRV: Bool { self == .full || self == .hrv }
    var expectedReadingCount: Int { (includesSleep ? 1 : 0) + (includesHRV ? 1 : 0) }

    var model: TodayHomeModel {
        var readings: [TodayReadingCard] = []
        if includesSleep { readings.append(.sleep(Self.sleepReading)) }
        if includesHRV { readings.append(.hrv(Self.hrvReading)) }

        return TodayHomeModel(
            greeting: "Good morning, Tyler",
            readings: readings,
            plan: TodayPlanCardModel(
                title: "Intensity - Block 12",
                detail: planDetail
            ),
            week: Self.week,
            zoneRanges: [
                .z1: "95-121",
                .z2: "122-140",
                .z3: "141-158",
                .z4: "159-172",
                .z5: "173-195",
            ]
        )
    }

    private var planDetail: String {
        switch self {
        case .full:
            "45 min · intervals + sled work. High certainty - sleep 82, HRV +6 ms."
        case .sleep:
            "45 min · intervals + sled work. Medium certainty - sleep 82, no HRV reading."
        case .hrv:
            "45 min · intervals + sled work. Medium certainty - HRV +6 ms, no sleep data."
        case .none:
            "45 min · intervals + sled work. Low certainty - no readings this morning."
        }
    }

    private static let sleepReading = TodaySleepCardModel(
        score: 82,
        rating: "High",
        durationText: "7h 41m in bed",
        segments: [
            .init(weight: 40, progress: 0.83, colorRole: .duration),
            .init(weight: 35, progress: 0.71, colorRole: .consistency),
            .init(weight: 25, progress: 0.76, colorRole: .interruptions),
        ]
    )

    private static let hrvReading = TodayHRVCardModel(
        value: 68,
        comparisonText: "+6 ms vs 30-day",
        isPositive: true
    )

    private static let week = TodayWeeklySummary(
        sessionCount: 4,
        trainingSeconds: 8_580,
        cardioSeconds: 4_080,
        movements: [
            TodayMovementSummary(name: "Squat", sets: 27, tint: .accent),
            TodayMovementSummary(name: "Push", sets: 22, tint: .accent),
            TodayMovementSummary(name: "Pull", sets: 10, tint: .caution),
            TodayMovementSummary(name: "Hinge", sets: 15, tint: .accent),
            TodayMovementSummary(name: "Carry / gait", sets: 19, tint: .accent),
        ],
        frontMuscles: [
            TodayMuscleMapLayer(assetName: "MuscleMapFrontQuadriceps", intensity: 1),
            TodayMuscleMapLayer(assetName: "MuscleMapFrontChest", intensity: 0.75),
            TodayMuscleMapLayer(assetName: "MuscleMapFrontBiceps", intensity: 0.5),
            TodayMuscleMapLayer(assetName: "MuscleMapFrontAbs", intensity: 0.35),
        ],
        backMuscles: [
            TodayMuscleMapLayer(assetName: "MuscleMapBackGluteal", intensity: 1),
            TodayMuscleMapLayer(assetName: "MuscleMapBackUpperBack", intensity: 0.78),
            TodayMuscleMapLayer(assetName: "MuscleMapBackHamstring", intensity: 0.62),
            TodayMuscleMapLayer(assetName: "MuscleMapBackCalves", intensity: 0.4),
        ],
        heartRateZones: [
            TodayHeartRateZoneSummary(zone: .z1, seconds: 2_040),
            TodayHeartRateZoneSummary(zone: .z2, seconds: 2_460),
            TodayHeartRateZoneSummary(zone: .z3, seconds: 2_280),
            TodayHeartRateZoneSummary(zone: .z4, seconds: 1_320),
            TodayHeartRateZoneSummary(zone: .z5, seconds: 480),
        ],
        averageHeartRate: 141
    )
}

@MainActor
private final class TodayEvidenceScreen {
    private let window: UIWindow

    init(model: TodayHomeModel) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        let root = TodayEvidenceRoot(model: model)
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

private struct TodayEvidenceRoot: View {
    let model: TodayHomeModel
    @State private var selectedTab: MainTab = .today

    var body: some View {
        TodayHomeView(model: model, openSleep: {}, openHRV: {}, openPlan: {})
            .overlay(alignment: .bottom) {
                BaselineFloatingTabBar(selection: $selectedTab)
            }
    }
}
