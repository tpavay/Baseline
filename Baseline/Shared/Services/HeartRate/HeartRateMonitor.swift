import Foundation
import Observation

/// Main-actor facade over a `LiveHeartRateSource` (production: `BluetoothManager`) that turns the
/// raw live stream into workout-ready state: current BPM, current zone (via an injected
/// `HeartRateZoneModel`), sensor contact, a freshness verdict, and accumulated seconds-in-zone.
///
/// Freshness matters because BLE has no "signal lost" push — silence is the only signal. Every
/// timing decision uses an **injected clock** (`now`), never `Date()` directly, so freshness and
/// zone-time are deterministic in tests. This slice is headless: nothing in the running app starts
/// the monitor (that is the Slice-3 go-live wiring).
@MainActor
@Observable
final class HeartRateMonitor {

    /// A live sample older than this is treated as absent, and a gap longer than this is not
    /// credited to any zone (the strap was effectively silent, so its zone is unknown). ~5 s covers
    /// several missed ~1 Hz notifications. Tunable.
    static let freshnessWindow: TimeInterval = 5

    /// The most recent sample received, regardless of freshness. `freshSample` applies the window.
    private(set) var latestSample: HeartRateSample?

    /// Seconds-in-zone accumulated over the current monitoring run.
    private(set) var zoneTime = ZoneTimeAccumulator()

    /// Average / max / elapsed for the current run. Aggregates of recorded samples, so they persist
    /// through a dropout and feed the HUD's AVG · TIME · MAX row while the live BPM blanks.
    private(set) var stats = SessionHeartRateStats()

    /// Whether `startMonitoring()` is currently active.
    private(set) var isMonitoring = false

    @ObservationIgnored private let source: any LiveHeartRateSource
    @ObservationIgnored private let now: @MainActor () -> Date

    /// The athlete's zone boundaries. Swappable so settings changes (Slice 2) re-resolve zones.
    var zoneModel: HeartRateZoneModel

    /// Clock time at which `latestSample` was ingested (the monitor's own arrival stamp).
    @ObservationIgnored private var latestSampleAt: Date?

    init(
        source: any LiveHeartRateSource,
        zoneModel: HeartRateZoneModel,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.source = source
        self.zoneModel = zoneModel
        self.now = now
    }

    // MARK: - Derived live state

    /// The latest sample if it arrived within the freshness window, else nil (stale → absent).
    var freshSample: HeartRateSample? {
        guard let latestSample, let latestSampleAt,
              now().timeIntervalSince(latestSampleAt) <= Self.freshnessWindow else {
            return nil
        }
        return latestSample
    }

    /// Current BPM if a fresh sample exists, else nil.
    var currentBPM: Int? { freshSample?.bpm }

    /// Current zone from the fresh BPM via the injected model, else nil.
    var currentZone: HeartRateZone? { freshSample.map { zoneModel.zone(forBPM: $0.bpm) } }

    /// Sensor-contact state of the fresh sample, else nil.
    var sensorContact: HeartRateSample.SensorContact? { freshSample?.sensorContact }

    /// Session average BPM, or nil before the first sample. A recorded aggregate, so it survives a
    /// dropout (unlike `currentBPM`, which honestly blanks when stale).
    var averageBPM: Int? { stats.averageBPM }

    /// Session max BPM, or nil before the first sample.
    var maxBPM: Int? { stats.maxBPM }

    /// Session elapsed seconds (first to most-recent recorded sample).
    var sessionElapsed: TimeInterval { stats.elapsed }

    /// Passthrough of the underlying connection status.
    var connectionStatus: BluetoothManager.Status { source.connectionStatus }

    // MARK: - Lifecycle

    /// Begin live monitoring: wire the sample stream and ask the source to connect/stream. Resets
    /// the zone-time accumulator for a fresh run.
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        latestSample = nil
        latestSampleAt = nil
        zoneTime = ZoneTimeAccumulator()
        stats = SessionHeartRateStats()

        // `onLiveSample` fires on the main queue (see `LiveHeartRateSource`); `assumeIsolated`
        // bridges that main-confined callback into this main-actor instance without a hop.
        source.onLiveSample = { [weak self] sample in
            MainActor.assumeIsolated {
                self?.ingest(sample)
            }
        }
        source.startLiveMonitoring()
    }

    /// Stop live monitoring and detach the stream. Accumulated `zoneTime` is retained for a summary.
    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        source.onLiveSample = nil
        source.stopLiveMonitoring()
        latestSample = nil
        latestSampleAt = nil
    }

    // MARK: - Ingestion

    /// Record a new live sample. Credits the interval since the previous sample to the zone that was
    /// active during it (the previous sample's zone), then adopts the new sample. A gap longer than
    /// the freshness window is treated as a dropout and not credited — honest about unknown time.
    /// Internal so the source wiring and tests can drive it directly.
    func ingest(_ sample: HeartRateSample) {
        let t = now()
        if let previous = latestSample, let previousAt = latestSampleAt {
            let elapsed = t.timeIntervalSince(previousAt)
            if elapsed > 0, elapsed <= Self.freshnessWindow {
                zoneTime.credit(zoneModel.zone(forBPM: previous.bpm), seconds: elapsed)
            }
        }
        latestSample = sample
        latestSampleAt = t
        stats.record(bpm: sample.bpm, at: t)
    }
}
