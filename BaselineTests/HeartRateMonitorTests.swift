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

    func startLiveMonitoring() { startCount += 1 }
    func stopLiveMonitoring() { stopCount += 1 }

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
}
