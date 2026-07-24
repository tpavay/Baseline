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
    /// several missed ~1 Hz notifications. This is the *soft* staleness threshold: once crossed the
    /// HUD drops the live number to "No signal — check the strap" and the watchdog re-subscribes.
    /// Tunable (captain-facing).
    static let freshnessWindow: TimeInterval = 5

    /// The *hard* staleness threshold. If samples are still silent this long after the last one while
    /// the link still reports connected, a re-subscribe has not helped, so the watchdog cancels and
    /// reconnects the peripheral (which surfaces as "Reconnecting…"). Must be > `freshnessWindow`.
    /// Tunable (captain-facing).
    static let reconnectWindow: TimeInterval = 10

    /// How often the staleness watchdog re-evaluates freshness while monitoring. Converts freshness
    /// from a pull (recomputed only on a SwiftUI re-render) into a push, so a silent strap downgrades
    /// off its last number within ~one tick of crossing `freshnessWindow`. Tunable.
    static let watchdogInterval: TimeInterval = 1

    /// The most recent sample received, regardless of freshness. `freshSample` applies the window.
    private(set) var latestSample: HeartRateSample?

    /// The latest sample if it is still within the freshness window, else nil — the honest "is the
    /// number live?" verdict the HUD renders. **Stored, not computed**: the watchdog recomputes and
    /// mutates it on a tick, so this is an *observed* property change that pushes a SwiftUI re-render
    /// even when no new sample or connection-status change occurs. That closes the freeze where a
    /// silent-but-connected strap left the last `.streaming` value painted forever.
    private(set) var freshSample: HeartRateSample?

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

    /// The repeating staleness watchdog for the current run; cancelled on `stopMonitoring()`.
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    /// How far recovery has escalated for the *current* stale episode, so each step fires at most
    /// once and a fresh sample resets it. `.healthy` while data flows.
    @ObservationIgnored private var recoveryStage: RecoveryStage = .healthy

    /// Escalation ladder the watchdog walks while a strap is silent but the link still reads connected.
    private enum RecoveryStage { case healthy, resubscribed, reconnecting }

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
        freshSample = nil
        recoveryStage = .healthy
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
        startWatchdog()
    }

    /// Stop live monitoring and detach the stream. Accumulated `zoneTime` is retained for a summary.
    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        watchdog?.cancel()
        watchdog = nil
        source.onLiveSample = nil
        source.stopLiveMonitoring()
        latestSample = nil
        latestSampleAt = nil
        freshSample = nil
        recoveryStage = .healthy
    }

    // MARK: - Staleness watchdog

    /// Start the repeating watchdog that re-evaluates freshness on a fixed cadence. BLE has no
    /// "signal lost" push — silence is the only signal — so nothing else re-renders the HUD when a
    /// connected strap simply stops notifying. The tick supplies that missing push.
    ///
    /// The production timer uses wall-clock `Task.sleep`; the freshness/recovery *decision* it drives
    /// (`checkLiveness`) reads the injected clock, so tests advance that clock and call `checkLiveness`
    /// directly for full determinism (no real sleeping).
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.watchdogInterval))
                guard let self, !Task.isCancelled else { return }
                self.checkLiveness()
            }
        }
    }

    /// One watchdog evaluation. Recomputes the freshness verdict from the injected clock — mutating
    /// the observed `freshSample` so the HUD re-renders and honestly drops a silent strap off its last
    /// number — and, while the link still reports connected, escalates recovery at most once per
    /// stage: re-subscribe first, then reconnect. A real disconnect has its own auto-reconnect path in
    /// `BluetoothManager`, so recovery here only targets the silent-but-connected case.
    ///
    /// Internal (not private) and clock-driven so tests can drive a deterministic tick.
    func checkLiveness() {
        guard isMonitoring else { return }
        guard let latestSampleAt else {
            freshSample = nil
            return
        }

        let silence = now().timeIntervalSince(latestSampleAt)
        guard silence > Self.freshnessWindow else {
            freshSample = latestSample          // still fresh
            recoveryStage = .healthy
            return
        }

        freshSample = nil                       // stale → honest blank, not a frozen number

        guard source.connectionStatus == .connected else { return }
        if silence > Self.reconnectWindow, recoveryStage != .reconnecting {
            recoveryStage = .reconnecting
            source.reconnectLive()
        } else if recoveryStage == .healthy {
            recoveryStage = .resubscribed
            source.resubscribeLive()
        }
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
        freshSample = sample          // a just-arrived sample is fresh by definition
        recoveryStage = .healthy      // data is flowing again — reset recovery escalation
        stats.record(bpm: sample.bpm, at: t)
    }
}
