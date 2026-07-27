import Foundation
import Testing
@testable import Baseline

/// A controllable live source: pushes samples through the same `onLiveSample` seam the real
/// `BluetoothManager` uses, so the monitor's wiring is exercised without CoreBluetooth.
private final class FakeLiveHeartRateSource: LiveHeartRateSource {
    var liveSample: HeartRateSample?
    var connectionStatus: BluetoothManager.Status = .connected
    var onLiveSample: ((HeartRateSample) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var resubscribeCount = 0
    private(set) var reconnectCount = 0

    func startLiveMonitoring() { startCount += 1 }
    func stopLiveMonitoring() { stopCount += 1 }
    func resubscribeLive() { resubscribeCount += 1 }
    func reconnectLive() { reconnectCount += 1 }

    /// Emit a sample as a worn strap would. The monitor re-stamps arrival with its own clock, so
    /// `receivedAt` here is arbitrary provenance.
    func emit(bpm: Int, contact: HeartRateSample.SensorContact = .detected) {
        let sample = HeartRateSample(bpm: bpm, sensorContact: contact, receivedAt: .distantPast)
        liveSample = sample
        onLiveSample?(sample)
    }
}

/// A hand-advanced clock so freshness and zone-time are fully deterministic (no wall clock, no
/// sleeps).
@MainActor
private final class ManualClock {
    private(set) var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { current = start }
    func advance(by seconds: TimeInterval) { current += seconds }
    var now: @MainActor () -> Date { { [self] in current } }
}

@MainActor
struct HeartRateMonitorTests {

    // maxHR 200, %max → lower bounds 100/120/140/160/180. 130→Z2, 150→Z3, 190→Z5, 90→Z1.
    private func makeMonitor(_ clock: ManualClock) -> (HeartRateMonitor, FakeLiveHeartRateSource) {
        let source = FakeLiveHeartRateSource()
        let monitor = HeartRateMonitor(
            source: source,
            zoneModel: HeartRateZoneModel(maxHR: 200),
            now: clock.now
        )
        return (monitor, source)
    }

    // MARK: - AC-6: freshness + current zone

    @Test func freshSampleWithinWindowExposesBPMAndZone() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        monitor.startMonitoring()
        #expect(source.startCount == 1)

        source.emit(bpm: 130)                       // ingested at t0
        #expect(monitor.freshSample != nil)
        #expect(monitor.currentBPM == 130)
        #expect(monitor.currentZone == .z2)
        #expect(monitor.sensorContact == .detected)

        clock.advance(by: 4)                        // still inside the 5 s window
        #expect(monitor.currentBPM == 130)
        #expect(monitor.currentZone == .z2)
    }

    @Test func staleSampleBeyondWindowBecomesAbsent() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        monitor.startMonitoring()
        source.emit(bpm: 150)                       // ingested at t0

        clock.advance(by: 6)                        // 6 s > 5 s window → stale
        monitor.checkLiveness()                     // the watchdog tick pushes the downgrade
        #expect(monitor.freshSample == nil)
        #expect(monitor.currentBPM == nil)
        #expect(monitor.currentZone == nil)
        #expect(monitor.sensorContact == nil)
    }

    @Test func notDetectedSensorContactPropagates() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        monitor.startMonitoring()
        source.emit(bpm: 130, contact: .notDetected)
        #expect(monitor.sensorContact == .notDetected)
    }

    @Test func currentZoneUsesInjectedModel() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        monitor.startMonitoring()
        source.emit(bpm: 190)
        #expect(monitor.currentZone == .z5)         // 190 ≥ 180 (0.9·200)
    }

    @Test func connectionStatusPassesThrough() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        source.connectionStatus = .connecting
        #expect(monitor.connectionStatus == .connecting)
    }

    // MARK: - AC-7: zone-time accumulation

    @Test func zoneTimeCreditsEachIntervalToTheActiveZone() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        monitor.startMonitoring()

        source.emit(bpm: 130)          // Z2 — no credit on the first sample
        clock.advance(by: 3)
        source.emit(bpm: 150)          // credits [t0, t0+3] = 3 s to Z2 (prev zone)
        clock.advance(by: 2)
        source.emit(bpm: 190)          // credits 2 s to Z3
        clock.advance(by: 4)
        source.emit(bpm: 190)          // credits 4 s to Z5

        #expect(monitor.zoneTime.seconds(in: .z2) == 3)
        #expect(monitor.zoneTime.seconds(in: .z3) == 2)
        #expect(monitor.zoneTime.seconds(in: .z5) == 4)
        #expect(monitor.zoneTime.seconds(in: .z1) == 0)
        #expect(monitor.zoneTime.seconds(in: .z4) == 0)
        #expect(monitor.zoneTime.total == 9)
    }

    @Test func gapLongerThanWindowIsNotCredited() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        monitor.startMonitoring()

        source.emit(bpm: 130)          // Z2
        clock.advance(by: 10)          // 10 s > 5 s window → sensor was silent, zone unknown
        source.emit(bpm: 150)
        #expect(monitor.zoneTime.total == 0)
    }

    @Test func firstSampleAfterStartResetsZoneTime() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        monitor.startMonitoring()
        source.emit(bpm: 130)
        clock.advance(by: 2)
        source.emit(bpm: 130)
        #expect(monitor.zoneTime.total == 2)

        monitor.stopMonitoring()
        monitor.startMonitoring()      // fresh run resets the accumulator
        #expect(monitor.zoneTime.total == 0)
    }

    // MARK: - Session aggregates (AVG · TIME · MAX)

    @Test func sessionStatsAccumulateAverageMaxAndElapsed() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        monitor.startMonitoring()
        #expect(monitor.averageBPM == nil)     // no samples yet
        #expect(monitor.maxBPM == nil)
        #expect(monitor.sessionElapsed == 0)

        source.emit(bpm: 130)                   // t0
        clock.advance(by: 3); source.emit(bpm: 150)   // t0+3
        clock.advance(by: 2); source.emit(bpm: 190)   // t0+5

        #expect(monitor.averageBPM == 157)      // round((130+150+190)/3) = 156.67 → 157
        #expect(monitor.maxBPM == 190)
        #expect(monitor.sessionElapsed == 5)    // first → most-recent sample
    }

    @Test func sessionStatsPersistThroughAStaleSignal() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        monitor.startMonitoring()
        source.emit(bpm: 140)                   // t0
        clock.advance(by: 2); source.emit(bpm: 160)   // t0+2
        clock.advance(by: 6)                    // stale: current blanks, aggregates must not
        monitor.checkLiveness()                 // watchdog tick pushes the freshness downgrade

        #expect(monitor.currentBPM == nil)      // honest: no live number
        #expect(monitor.averageBPM == 150)      // but the recorded aggregates persist
        #expect(monitor.maxBPM == 160)
        #expect(monitor.sessionElapsed == 2)
    }

    @Test func startMonitoringResetsSessionStats() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        monitor.startMonitoring()
        source.emit(bpm: 150)
        clock.advance(by: 2); source.emit(bpm: 170)
        #expect(monitor.averageBPM == 160)

        monitor.stopMonitoring()
        monitor.startMonitoring()               // fresh run wipes the aggregates
        #expect(monitor.averageBPM == nil)
        #expect(monitor.maxBPM == nil)
        #expect(monitor.sessionElapsed == 0)
    }

    // MARK: - Staleness watchdog (the freeze fix)

    /// The core regression: a connected strap goes silent (no new sample, no disconnect). The watchdog
    /// tick must downgrade the display off its last number **without** a new sample arriving, and the
    /// resolver must render the honest `.noSignal` state rather than the frozen reading.
    @Test func watchdogDowngradesSilentStrapWithoutANewSample() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        source.connectionStatus = .connected
        monitor.startMonitoring()
        source.emit(bpm: 133)                                   // last real reading, e.g. the stuck 133
        #expect(LiveHeartRateStateResolver.resolve(monitor) == .streaming(
            bpm: 133, zone: monitor.zoneModel.zone(forBPM: 133),
            position: monitor.zoneModel.position(forBPM: 133)))

        clock.advance(by: 6)                                    // strap stops sending; link stays up
        monitor.checkLiveness()                                 // watchdog tick (the push the app lacked)

        #expect(monitor.freshSample == nil)                    // no longer painting 133
        #expect(monitor.currentBPM == nil)
        #expect(LiveHeartRateStateResolver.resolve(monitor) == .noSignal)   // "No signal — check the strap"
    }

    /// On first crossing the soft window the watchdog re-subscribes (cheap, keeps the link); if silence
    /// continues past the hard window it escalates to a reconnect. Each fires exactly once per episode.
    @Test func watchdogResubscribesThenReconnectsOnContinuedSilence() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        source.connectionStatus = .connected
        monitor.startMonitoring()
        source.emit(bpm: 150)

        clock.advance(by: 6)                                    // > freshnessWindow (5) → re-subscribe
        monitor.checkLiveness()
        #expect(source.resubscribeCount == 1)
        #expect(source.reconnectCount == 0)

        clock.advance(by: 1)                                    // still silent, still < reconnectWindow
        monitor.checkLiveness()
        #expect(source.resubscribeCount == 1)                  // not re-fired
        #expect(source.reconnectCount == 0)

        clock.advance(by: 5)                                    // total 12 s > reconnectWindow (10)
        monitor.checkLiveness()
        #expect(source.reconnectCount == 1)                    // escalated to reconnect

        clock.advance(by: 3)
        monitor.checkLiveness()
        #expect(source.reconnectCount == 1)                    // still only once per episode
    }

    /// After the first reconnect the strap stays silent while the link flaps back to `.connected`.
    /// The watchdog must not sit on "No signal" forever: it keeps retrying the reconnect, but spaced by
    /// `reconnectWindow` (not every tick) and bounded by `maxReconnectAttempts`.
    @Test func watchdogKeepsReconnectingOnACadenceUpToTheBound() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        source.connectionStatus = .connected
        monitor.startMonitoring()
        source.emit(bpm: 150)

        clock.advance(by: 6); monitor.checkLiveness()          // soft window → re-subscribe
        #expect(source.resubscribeCount == 1)

        clock.advance(by: 5); monitor.checkLiveness()          // 11 s > reconnectWindow → first reconnect
        #expect(source.reconnectCount == 1)

        clock.advance(by: 3); monitor.checkLiveness()          // only 3 s since last reconnect → spaced out
        #expect(source.reconnectCount == 1)

        // The link stays connected but silent; each further `reconnectWindow` elapsed fires one more
        // reconnect, until the per-episode bound is reached — then it stops (no unbounded loop).
        for expected in 2...HeartRateMonitor.maxReconnectAttempts {
            clock.advance(by: HeartRateMonitor.reconnectWindow); monitor.checkLiveness()
            #expect(source.reconnectCount == expected)
        }
        clock.advance(by: HeartRateMonitor.reconnectWindow); monitor.checkLiveness()
        #expect(source.reconnectCount == HeartRateMonitor.maxReconnectAttempts)   // bounded, not still climbing
        #expect(monitor.currentBPM == nil)                     // still honestly blank throughout
    }

    /// A recovered sample resets the ladder: the number returns and a *later* silent episode re-arms
    /// recovery from scratch (re-subscribe again).
    @Test func freshSampleReturnsAndRecoveryResetsOnNewSample() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        source.connectionStatus = .connected
        monitor.startMonitoring()
        source.emit(bpm: 150)
        clock.advance(by: 6); monitor.checkLiveness()          // stale → re-subscribe
        #expect(source.resubscribeCount == 1)

        source.emit(bpm: 148)                                  // strap recovers
        #expect(monitor.currentBPM == 148)                     // number returns

        clock.advance(by: 6); monitor.checkLiveness()          // a new stale episode
        #expect(monitor.currentBPM == nil)
        #expect(source.resubscribeCount == 2)                  // recovery re-armed, not stuck
    }

    /// Recovery only targets the silent-but-connected case: if the link is not `.connected` (a real
    /// disconnect, which `BluetoothManager` auto-reconnects on its own), the watchdog still blanks the
    /// number but does not fire re-subscribe/reconnect.
    @Test func watchdogDoesNotDriveRecoveryWhenNotConnected() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        monitor.startMonitoring()
        source.emit(bpm: 150)
        source.connectionStatus = .connecting                  // link already re-establishing
        clock.advance(by: 6); monitor.checkLiveness()

        #expect(monitor.freshSample == nil)                    // still honestly blanks
        #expect(source.resubscribeCount == 0)
        #expect(source.reconnectCount == 0)
        #expect(LiveHeartRateStateResolver.resolve(monitor) == .reconnecting)  // sample seen earlier
    }

    /// The watchdog is torn down with the session: no ticks fire after `stopMonitoring()`, and a fresh
    /// `startMonitoring()` clears any leftover fresh sample.
    @Test func stopMonitoringStopsTheWatchdog() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        monitor.startMonitoring()
        source.emit(bpm: 150)
        monitor.stopMonitoring()

        clock.advance(by: 6)
        monitor.checkLiveness()                                // guarded by isMonitoring → no-op
        #expect(monitor.freshSample == nil)
        #expect(source.resubscribeCount == 0)
    }

    // MARK: - Lifecycle

    @Test func stopMonitoringDetachesAndClearsLiveState() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        monitor.startMonitoring()
        source.emit(bpm: 150)
        #expect(monitor.currentZone == .z3)

        monitor.stopMonitoring()
        #expect(source.stopCount == 1)
        #expect(source.onLiveSample == nil)
        #expect(monitor.isMonitoring == false)
        #expect(monitor.currentBPM == nil)
        #expect(monitor.currentZone == nil)
    }

    // MARK: - Trace capture (the recorder is downstream of the HUD, never in front of it)

    /// The whole point of attaching the recorder here: it sees every sample the HUD sees, using the
    /// same injected clock.
    @Test func anAttachedRecorderCapturesEverySampleTheMonitorIngests() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        let recorder = WorkoutHeartRateRecorder()
        monitor.recorder = recorder
        monitor.startMonitoring()

        source.emit(bpm: 130)
        clock.advance(by: 1)
        source.emit(bpm: 150)
        clock.advance(by: 1)
        source.emit(bpm: 165)

        #expect(recorder.trace.points.map(\.bpm) == [130, 150, 165])
        #expect(recorder.trace.startAt == clock.current.addingTimeInterval(-2))
    }

    /// The freshness regression guard: a silent strap must still blank the live number, and the trace
    /// already captured must survive that — the recorder cannot delay, suppress, or resurrect the HUD.
    @Test func theRecorderKeepsItsTraceWhileTheHUDHonestlyBlanksAStaleReading() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        let recorder = WorkoutHeartRateRecorder()
        monitor.recorder = recorder
        monitor.startMonitoring()

        source.emit(bpm: 145)
        clock.advance(by: 2)
        source.emit(bpm: 148)
        #expect(monitor.currentBPM == 148)

        clock.advance(by: HeartRateMonitor.freshnessWindow + 1)
        monitor.checkLiveness()

        #expect(monitor.freshSample == nil)                       // still honest about the silence
        #expect(monitor.currentBPM == nil)
        #expect(monitor.averageBPM != nil)                        // recorded aggregates persist
        #expect(recorder.trace.points.map(\.bpm) == [145, 148])   // and so does the trace
    }

    /// A new run resets the trace along with `zoneTime` and `stats`, so one run's samples can never
    /// leak into the next one's record.
    @Test func startingAnotherRunClearsTheRecordersBuffer() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        let recorder = WorkoutHeartRateRecorder()
        monitor.recorder = recorder
        monitor.startMonitoring()
        source.emit(bpm: 150)
        #expect(recorder.trace.count == 1)

        monitor.stopMonitoring()
        monitor.startMonitoring()
        #expect(recorder.trace.isEmpty)
        #expect(monitor.zoneTime.total == 0)
        #expect(monitor.averageBPM == nil)
    }

    /// With no recorder attached — every surface that only *shows* the live number — nothing changes.
    @Test func withNoRecorderAttachedIngestionBehavesExactlyAsBefore() {
        let clock = ManualClock()
        let (monitor, source) = makeMonitor(clock)
        monitor.startMonitoring()

        source.emit(bpm: 130)
        clock.advance(by: 2)
        source.emit(bpm: 150)

        #expect(monitor.recorder == nil)
        #expect(monitor.currentBPM == 150)
        #expect(monitor.zoneTime.seconds(in: .z2) == 2)
    }
}
