import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// The wiring the reactivity unit tests sit behind. `HeartRateZoneReactivityTests` proves the store
/// and the monitor behave correctly *once* a surface reads the shared instance; nothing there fails
/// if the app stops sharing that instance or stops subscribing to it — which is precisely the bug
/// that shipped. These tests pin the connections themselves.
@MainActor
@Suite(.serialized)
struct HeartRateZoneWiringTests {

    // MARK: - The rendered shell follows an edit on the shared instance

    /// End to end through the real signed-in shell: hand `MainTabView` one store, edit it the way the
    /// Profile editor does, and the Weekly card's rendered BPM ranges must change. This fails if Today
    /// reverts to constructing its own store, or stops re-deriving `zoneRanges` when the store moves.
    @Test func aZoneEditReRendersTheWeeklyCardsBPMRanges() async throws {
        let zones = HeartRateZoneSettingsStore(defaults: .previewEmpty, ageYears: { 30 })
        let screen = try MainTabShellScreen(tab: .today, heartRateZones: zones)
        defer { screen.tearDown() }
        try await screen.settle()

        let before = try #require(HeartRateZonePreview(model: zones.resolvedModel).rows.last)
        try await screen.settleUntil {
            screen.scrollToBottom()
            return screen.element(labelled: "\(before.rangeText) beats per minute") != nil
        }

        #expect(zones.update(HeartRateZoneSettings(maxHROverride: 200)))
        let after = try #require(HeartRateZonePreview(model: zones.resolvedModel).rows.last)
        try #require(after.rangeText != before.rangeText, "the edit must actually move the Z5 band")

        try await screen.settleUntil {
            screen.scrollToBottom()
            return screen.element(labelled: "\(after.rangeText) beats per minute") != nil
        }
        #expect(screen.element(labelled: "\(before.rangeText) beats per minute") == nil,
                "the pre-edit band must be gone, not merely joined by the new one")
    }

    // MARK: - One instance, and every surface subscribed to it

    /// Only `RootView` may build the app's zone store. Every other construction is either a preview or
    /// a second source of truth — and a second source of truth is exactly what made a Profile edit
    /// invisible to an open Today model and a running monitor.
    @Test func rootViewIsTheOnlyPlaceTheAppBuildsAZoneStore() throws {
        var offences: [String] = []
        for file in try Self.appSources() where file.lastPathComponent != "RootView.swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where line.contains("HeartRateZoneSettingsStore(") {
                // The call may wrap, so read the whole statement before judging it: a preview-safe
                // construction names its throwaway suite on this line or the next couple.
                let statement = lines[index...min(index + 2, lines.count - 1)].joined()
                guard !statement.contains("previewEmpty"), !statement.contains("previewSeeded") else { continue }
                offences.append("\(file.lastPathComponent):\(index + 1)  \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offences.isEmpty, """
            These lines build a second HeartRateZoneSettingsStore. The app has exactly one, created in \
            RootView and injected into MainTabView, so an edit on any surface reaches all of them; a \
            locally constructed store silently reverts to the copy-pasted-per-surface bug. Previews and \
            test harnesses must construct theirs with `defaults: .previewEmpty` (or `.previewSeeded`) so \
            they never read or write the athlete's real config either.
            \(offences.joined(separator: "\n"))
            """)
    }

    /// `RootView` must actually hand that one instance down, or every reader traps on a missing
    /// environment object the moment it is built.
    @Test func rootViewInjectsTheSharedStoreIntoTheShell() throws {
        let source = try Self.source(of: "Baseline/App/RootView.swift")
        #expect(source.contains(".environment(heartRateZones)"),
                "RootView must inject its single HeartRateZoneSettingsStore into MainTabView")
    }

    /// The mid-workout path: a zone edit while a session is live must reach the *running* monitor.
    /// A hosted assertion is impractical (the monitor only exists behind a saved, connected strap and
    /// is private view state), so pin the one line that carries it.
    @Test func workoutViewSwapsTheRunningMonitorsZoneModel() throws {
        let source = try Self.source(of: "Baseline/Features/Workout/WorkoutView.swift")
        #expect(source.contains(".onChange(of: heartRateZones.resolvedModel)"),
                "WorkoutView must observe the shared store so a mid-workout edit is noticed")
        #expect(source.contains("hrMonitor?.zoneModel = newModel"),
                "the live monitor's bands must be swapped in place, not left until the next session")
    }

    /// Today must route zone edits through its existing `.task(id:)` rather than firing an unstructured
    /// reassemble per edit: the editor commits on every valid keystroke, and a full evidence assembly
    /// per keystroke leaves overlapping runs whose writes can land out of order.
    @Test func todayCoalescesZoneEditsThroughTheRefreshSignature() throws {
        let source = try Self.source(of: "Baseline/Features/Today/TodayView.swift")
        #expect(source.contains("zoneModel: heartRateZones.resolvedModel"),
                "the resolved zone model must be folded into TodayRefreshSignature")
        #expect(!source.contains(".onChange(of: heartRateZones"), """
            Today must not reassemble from its own onChange: the zone editor commits on every valid \
            keystroke, so each one would start another unstructured evidence assembly. Fold the model \
            into refreshKey and let the single cancellable .task(id:) coalesce them.
            """)
    }

    // MARK: - Source access

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BaselineTests
            .deletingLastPathComponent()  // repository root
    }

    private static func source(of path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static func appSources() throws -> [URL] {
        let root = repositoryRoot.appendingPathComponent("Baseline")
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
