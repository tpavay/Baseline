import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// Reviewer-facing evidence for the shared-zone-store fix, driven the way the athlete drives it.
///
/// `HeartRateZoneReactivityTests` proves the store/monitor units and `HeartRateZoneWiringTests` pins
/// the connections; neither produces a picture of the surfaces that used to go stale. These two tests
/// walk the real signed-in shell — Weekly → Profile → Settings → Heart Rate Zones, typing a new max
/// HR into the actual `TextField` — and then come back to Weekly to show the already-built Today
/// model re-bucketed against the edited bands. Screenshots are written for review.
@MainActor
@Suite(.serialized)
struct HeartRateZoneReactivityEvidenceTests {

    /// One 10-minute run at a steady 150 BPM, logged this week. At the age-30 estimate (Tanaka → 187)
    /// that sits in Z4; with an explicit max of 200 the *same* logged minutes are Z3. Nothing about the
    /// history changes — only the athlete's zone config — so the card is a clean before/after.
    private static let loggedBPM = 150.0
    private static let loggedSeconds = 600.0

    /// The full athlete path: read the Weekly card, edit zones in Profile → Settings → Heart Rate
    /// Zones by typing into the real max-HR field, dismiss settings, and return to Weekly. Before the
    /// fix the card kept its old bands and its old bucketing until the app was relaunched.
    @Test func editingZonesInProfileUpdatesTheWeeklyCardWithoutARelaunch() async throws {
        let zones = HeartRateZoneSettingsStore(defaults: .previewEmpty, ageYears: { 30 })
        let screen = try MainTabShellScreen(tab: .today, heartRateZones: zones, seed: Self.seedOneZone4Run)
        defer { screen.tearDown() }
        try await screen.settle()

        // Before: Tanaka(30) = 187 → Z4 is 150–168 BPM, and the logged 10 minutes are Z4.
        let beforeZ4 = try #require(HeartRateZonePreview(model: zones.resolvedModel).rows.first { $0.zone == .z4 })
        #expect(zones.resolvedModel.maxHR == 187)
        try await screen.settleUntil {
            screen.scrollToBottom()
            return screen.element(labelled: "Z4, 10m, \(beforeZ4.rangeText) beats per minute") != nil
        }
        try screen.capture("hr-zones-weekly-card-before-edit")

        // Edit through the real editor: Profile → Settings → Heart Rate Zones, type a tested max.
        #expect(screen.activate(labelled: "Profile"))
        try await screen.settle()
        #expect(screen.activate(labelled: "Settings"))
        try await screen.settle()
        #expect(screen.activate(labelled: "Heart Rate Zones"))
        try await screen.settle()
        #expect(screen.element(labelled: "MAX HR") != nil)

        screen.type("200")
        try await screen.settle()
        // The editor commits on every valid keystroke — this is the athlete's edit, not a test poke.
        #expect(zones.settings.maxHROverride == 200)
        #expect(zones.resolvedModel.maxHR == 200)
        try screen.capture("hr-zones-editor-typed-max-200")

        // Back out of settings the way the athlete does, then return to Weekly.
        #expect(screen.popNavigation())                     // the navigation bar's back chevron
        try await screen.settle()
        #expect(screen.activate(labelled: "Done"))          // dismiss the settings sheet
        try await screen.settle()
        #expect(screen.activate(labelled: "Weekly"))
        try await screen.settle()

        // After: the same 10 logged minutes are now Z3, and every band's BPM range moved.
        let afterZ3 = try #require(HeartRateZonePreview(model: zones.resolvedModel).rows.first { $0.zone == .z3 })
        try #require(afterZ3.rangeText != beforeZ4.rangeText)
        try await screen.settleUntil {
            screen.scrollToBottom()
            return screen.element(labelled: "Z3, 10m, \(afterZ3.rangeText) beats per minute") != nil
        }
        #expect(screen.element(labelled: "Z4, 10m") == nil, "the pre-edit bucketing must be gone")
        #expect(screen.element(labelled: "\(beforeZ4.rangeText) beats per minute") == nil,
                "the pre-edit Z4 band must be gone, not merely joined by the new one")
        try screen.capture("hr-zones-weekly-card-after-edit")
    }

    /// The mid-workout path, rendered: a running monitor's gauge re-resolves to the edited bands for
    /// the *same* live 150 BPM once `WorkoutView`'s `onChange` swaps its `zoneModel`, and only the
    /// seconds that arrive afterwards are credited to the new zone.
    @Test func aZoneEditReachesTheRunningLiveHeartRateGauge() async throws {
        let clock = EvidenceClock()
        let source = EvidenceLiveSource()
        let zones = HeartRateZoneSettingsStore(defaults: .previewEmpty, ageYears: { 30 })
        let monitor = HeartRateMonitor(source: source, zoneModel: zones.resolvedModel, now: clock.now)
        monitor.startMonitoring()
        defer { monitor.stopMonitoring() }

        // Four minutes of steady 150 BPM at 1 Hz — the strap cadence the accumulator credits.
        stream(bpm: 150, seconds: 240, source: source, clock: clock)
        #expect(monitor.currentZone == .z4)

        let screen = try LiveZoneGaugeScreen(provider: monitor)
        defer { screen.tearDown() }
        try await screen.settle()
        // The gauge publishes its zone as an accessibility *value*, so read the spoken text.
        #expect(screen.speaks("Current zone Z4 Threshold, 150 beats per minute"))
        try screen.capture("hr-zones-live-gauge-before-edit")

        // The athlete edits zones mid-workout; WorkoutView pushes the new model into the live monitor.
        #expect(zones.update(HeartRateZoneSettings(maxHROverride: 200)))
        monitor.zoneModel = zones.resolvedModel
        stream(bpm: 150, seconds: 240, source: source, clock: clock)

        try await screen.settleUntil {
            screen.speaks("Current zone Z3 Aerobic, 150 beats per minute")
        }
        #expect(!screen.speaks("Current zone Z4 Threshold"))
        // Banked seconds keep the attribution they were earned under; new seconds go to the new zone.
        #expect(monitor.zoneTime.seconds(in: .z4) > 0)
        #expect(monitor.zoneTime.seconds(in: .z3) > 0)
        try screen.capture("hr-zones-live-gauge-after-edit")
    }

    // MARK: - Fixtures

    /// One completed cardio session inside the current plan week: 10 minutes at a steady 150 BPM.
    private static func seedOneZone4Run(_ context: ModelContext) {
        let weekStart = Calendar.planWeek.weekStart(for: .now)
        // Clamped into this week so the card is populated no matter what hour the suite runs at.
        let finished = min(max(Date.now.addingTimeInterval(-1800), weekStart.addingTimeInterval(60)), .now)
        let logID = UUID()
        let scheduledWorkoutID = UUID()
        let metrics = [MetricValues([.duration: loggedSeconds, .heartRate: loggedBPM])]
        context.insert(SDCompletedLog(id: logID, scheduledWorkoutID: scheduledWorkoutID, finishedAt: finished))
        context.insert(SDWorkoutSession(
            scheduledWorkoutID: scheduledWorkoutID,
            startedAt: finished.addingTimeInterval(-loggedSeconds)
        ))
        context.insert(SDCompletedExercise(
            completedLogID: logID,
            date: finished,
            workoutTitle: "Aerobic run",
            exerciseDefinitionID: "run",
            exerciseName: "Run",
            metricsJSON: (try? JSONEncoder().encode(metrics)) ?? Data()
        ))
    }

    /// Push `seconds` of 1 Hz samples so the monitor's zone-time accumulator credits them (a gap wider
    /// than the freshness window is deliberately not credited).
    private func stream(bpm: Int, seconds: Int, source: EvidenceLiveSource, clock: EvidenceClock) {
        for _ in 0..<seconds {
            source.emit(bpm: bpm)
            clock.advance(by: 1)
        }
        source.emit(bpm: bpm)
    }
}

// MARK: - Live-gauge harness

/// Hosts the real `LiveHeartRateView` over a real `HeartRateMonitor` in an attached key window, so the
/// gauge is rasterizable and its accessibility labels are published.
@MainActor
private final class LiveZoneGaugeScreen: HostedScreen {
    let window: UIWindow

    init(provider: any LiveHeartRateProviding) throws {
        let root = ScrollView {
            LiveHeartRateView(provider: provider, targetZones: nil)
                .padding(20)
        }
        .background(BaselineColor.base)
        .preferredColorScheme(.dark)
        window = try Self.makeWindow(rootView: root)
    }
}

/// Hand-advanced clock: freshness and zone-time stay deterministic without sleeping.
@MainActor
private final class EvidenceClock {
    private(set) var current = Date(timeIntervalSince1970: 3_000_000)
    func advance(by seconds: TimeInterval) { current += seconds }
    var now: @MainActor () -> Date { { [self] in current } }
}

/// A controllable strap that pushes through the real `onLiveSample` seam.
private final class EvidenceLiveSource: LiveHeartRateSource {
    var liveSample: HeartRateSample?
    var connectionStatus: BluetoothManager.Status = .connected
    var onLiveSample: ((HeartRateSample) -> Void)?

    func startLiveMonitoring() {}
    func stopLiveMonitoring() {}
    func resubscribeLive() {}
    func reconnectLive() {}

    func emit(bpm: Int, contact: HeartRateSample.SensorContact = .detected) {
        let sample = HeartRateSample(bpm: bpm, sensorContact: contact, receivedAt: .distantPast)
        liveSample = sample
        onLiveSample?(sample)
    }
}

// MARK: - Screen helpers

private extension HostedScreen {
    /// Type into the screen's first text field the way the athlete does — through `UITextInput`, so the
    /// SwiftUI binding (and the editor's commit-on-keystroke) actually fires.
    func type(_ text: String) {
        var fields: [UIView & UITextInput] = []
        func walk(_ view: UIView) {
            if let field = view as? (UIView & UITextInput) { fields.append(field) }
            view.subviews.forEach(walk)
        }
        walk(window)
        guard let field = fields.first else { return }
        field.becomeFirstResponder()
        if let range = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument) {
            field.replace(range, withText: text)
        }
        window.layoutIfNeeded()
    }

    /// Every accessibility label *and* value on screen, flattened. The zone gauge publishes its current
    /// zone as a value, which `element(labelled:)` cannot see.
    func speaks(_ text: String) -> Bool {
        AccessibilityElementWalker.elements(in: window)
            .flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }
            .contains { $0.contains(text) }
    }

    /// Pop the topmost pushed screen — what the navigation bar's back chevron does. Driven through
    /// `UINavigationController` because a system back button does not respond to
    /// `accessibilityActivate()`; every other step in these flows is a real control tap.
    @discardableResult
    func popNavigation() -> Bool {
        var navigationControllers: [UINavigationController] = []
        func walk(_ controller: UIViewController) {
            if let nav = controller as? UINavigationController, nav.viewControllers.count > 1 {
                navigationControllers.append(nav)
            }
            controller.children.forEach(walk)
            if let presented = controller.presentedViewController { walk(presented) }
        }
        guard let root = window.rootViewController else { return false }
        walk(root)
        guard let target = navigationControllers.last else { return false }
        target.popViewController(animated: false)
        window.layoutIfNeeded()
        return true
    }
}
