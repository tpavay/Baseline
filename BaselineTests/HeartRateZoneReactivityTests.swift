import Foundation
import Testing
@testable import Baseline

/// Reactivity contract for the *shared, injected* `HeartRateZoneSettingsStore`.
///
/// The bug this guards against: Today, the live workout monitor, and the Profile editor each used to
/// construct their own throwaway `HeartRateZoneSettingsStore`, so a zone edit only surfaced on the
/// next fresh build — an already-materialized Today model and a *running* monitor kept the old bands.
/// These tests assert that when every surface reads one shared instance, an edit propagates:
///   1. `resolvedModel` on the same instance reflects the committed edit immediately.
///   2. A downstream reader (the Weekly time-in-zone compute) re-buckets against the edited model.
///   3. A running `HeartRateMonitor` re-resolves its current zone once its `zoneModel` is swapped
///      from the shared store — the mid-workout path `WorkoutView` wires via `onChange`.
///   4. The boundary math itself is unchanged: `resolvedModel` equals the old
///      `model ?? HeartRateZoneModel(age:)` fallback expression it replaced.
@MainActor
struct HeartRateZoneReactivityTests {

    /// An isolated defaults suite so the store never touches `.standard` or bleeds between tests.
    private func makeDefaults() -> UserDefaults {
        let name = "hr-zone-reactivity-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - 1. The shared instance reflects an edit without reconstruction

    /// Editing the config on one instance changes `resolvedModel` on that *same* instance — no
    /// re-init, which is exactly what an already-injected surface holds onto.
    @Test func resolvedModelReflectsEditOnSameInstance() {
        // Age 30, empty config → Tanaka(30) = 187 (%max). 150 BPM sits in Z4 (t4 = 0.9·187 = 168.3).
        let store = HeartRateZoneSettingsStore(defaults: makeDefaults(), ageYears: { 30 })
        #expect(store.resolvedModel.maxHR == HeartRateZoneModel(age: 30).maxHR)
        #expect(store.resolvedModel.zone(forBPM: 150) == .z4)

        // Commit an explicit max of 200 (%max). 150 BPM now sits in Z3 (t3 = 0.8·200 = 160).
        #expect(store.update(HeartRateZoneSettings(maxHROverride: 200)))
        #expect(store.resolvedModel.maxHR == 200)
        #expect(store.resolvedModel.zone(forBPM: 150) == .z3)
    }

    // MARK: - 2. A downstream surface re-buckets through the shared model

    /// The Weekly time-in-zone compute reads whatever model the shared store currently resolves, so a
    /// zone edit moves the same logged sample into a different zone bucket — the Today card updates
    /// without any surface holding a private copy of the old bands.
    @Test func weeklyTimeInZoneFollowsSharedStoreEdit() throws {
        let store = HeartRateZoneSettingsStore(defaults: makeDefaults(), ageYears: { 30 })

        let calendar = Calendar.planWeek
        let reference = try #require(ISO8601DateFormatter().date(from: "2026-07-22T12:00:00Z"))
        let finished = try #require(calendar.date(byAdding: .hour, value: -2, to: reference))
        let started = try #require(calendar.date(byAdding: .hour, value: -1, to: finished))
        let logID = UUID()

        func summarize() -> TodayWeeklySummary {
            TodayWeeklySummary.build(
                sessions: [TodayCompletedSessionSample(completedLogID: logID, finishedAt: finished, startedAt: started)],
                exercises: [
                    TodayCompletedExerciseSample(
                        completedLogID: logID,
                        date: finished,
                        definitionID: "run",
                        metrics: [MetricValues([.duration: 600, .heartRate: 150])]
                    )
                ],
                zoneModel: store.resolvedModel,      // read the shared model at compute time
                referenceDate: reference,
                calendar: calendar
            )
        }

        // Age default (187): 150 BPM → Z4.
        let before = summarize()
        #expect(before.heartRateZones.first { $0.zone == .z4 }?.seconds == 600)
        #expect(before.heartRateZones.first { $0.zone == .z3 }?.seconds == 0)

        // Edit the shared store; the very next compute re-buckets the same sample into Z3.
        #expect(store.update(HeartRateZoneSettings(maxHROverride: 200)))
        let after = summarize()
        #expect(after.heartRateZones.first { $0.zone == .z3 }?.seconds == 600)
        #expect(after.heartRateZones.first { $0.zone == .z4 }?.seconds == 0)
    }

    // MARK: - 3. A running monitor picks up the edited model

    /// Mirrors `WorkoutView`'s `onChange(of: heartRateZones.resolvedModel)`: swapping a live monitor's
    /// `zoneModel` re-resolves the current zone for the *same* in-flight sample, so a mid-workout zone
    /// edit reaches the gauge without tearing the session down.
    @Test func runningMonitorReResolvesZoneAfterModelSwap() {
        let clock = ManualClock()
        let source = FakeReactivitySource()
        let store = HeartRateZoneSettingsStore(defaults: makeDefaults(), ageYears: { 30 })

        let monitor = HeartRateMonitor(source: source, zoneModel: store.resolvedModel, now: clock.now)
        monitor.startMonitoring()
        source.emit(bpm: 150)
        #expect(monitor.currentZone == .z4)          // age default 187 → 150 is Z4

        // A settings edit lands mid-workout; WorkoutView swaps the running model from the shared store.
        #expect(store.update(HeartRateZoneSettings(maxHROverride: 200)))
        monitor.zoneModel = store.resolvedModel
        #expect(monitor.currentZone == .z3)          // same live 150 BPM, now Z3
    }

    // MARK: - 4. Boundary math unchanged (the fallback consolidation is behaviour-preserving)

    /// `resolvedModel` must equal the exact `model ?? HeartRateZoneModel(age:)` expression it replaced
    /// at the Today/Workout call sites — both when a config is committed and when it is empty.
    @Test func resolvedModelEqualsOldInlineFallback() {
        let ages = [22, 28, 35, 47]
        for age in ages {
            let empty = HeartRateZoneSettingsStore(defaults: makeDefaults(), ageYears: { age })
            #expect(empty.resolvedModel == (empty.model ?? HeartRateZoneModel(age: age)))
            #expect(empty.resolvedModel == HeartRateZoneModel(age: age))     // empty → Tanaka fallback

            let configured = HeartRateZoneSettingsStore(defaults: makeDefaults(), ageYears: { age })
            #expect(configured.update(HeartRateZoneSettings(maxHROverride: 190, restingHR: 50)))
            #expect(configured.resolvedModel == (configured.model ?? HeartRateZoneModel(age: age)))
            #expect(configured.resolvedModel == HeartRateZoneModel(maxHR: 190, restingHR: 50))
        }
    }
}

// MARK: - Test doubles

/// A hand-advanced clock so the monitor's freshness window is deterministic (no wall clock).
@MainActor
private final class ManualClock {
    private(set) var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 2_000_000)) { current = start }
    func advance(by seconds: TimeInterval) { current += seconds }
    var now: @MainActor () -> Date { { [self] in current } }
}

/// A controllable live source that pushes samples through the same `onLiveSample` seam the real
/// `BluetoothManager` uses, so the monitor is exercised without CoreBluetooth.
private final class FakeReactivitySource: LiveHeartRateSource {
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
