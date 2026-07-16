import Foundation

/// The read-only live surface `LiveHeartRateView` binds to. Introducing it lets the view be driven by
/// a fake in previews and tests without a `BluetoothManager` or a real `HeartRateMonitor`, and keeps
/// the view from reaching for any lifecycle control — it can only *read* live state, never start,
/// stop, or connect. Every member here is already exposed by `HeartRateMonitor`, so the production
/// conformance is empty and the monitor's behavior is unchanged.
///
/// Main-actor because the production conformer (`HeartRateMonitor`) is main-actor `@Observable`;
/// reading these through the existential still triggers Observation tracking, so a SwiftUI `body`
/// re-renders when the underlying monitor's state changes.
@MainActor
protocol LiveHeartRateProviding: AnyObject {
    /// Current BPM if a fresh sample exists, else nil (stale → absent, never a fabricated live value).
    var currentBPM: Int? { get }
    /// Current zone from the fresh BPM via the model, else nil.
    var currentZone: HeartRateZone? { get }
    /// Sensor-contact state of the fresh sample, else nil.
    var sensorContact: HeartRateSample.SensorContact? { get }
    /// The latest sample if within the freshness window, else nil — the honest "is the number live?".
    var freshSample: HeartRateSample? { get }
    /// The most recent sample regardless of freshness. Non-nil once any sample has arrived, so it
    /// distinguishes a first-time connect from a reconnect after a dropout.
    var latestSample: HeartRateSample? { get }
    /// Underlying connection status (connecting / connected / idle / …).
    var connectionStatus: BluetoothManager.Status { get }
    /// The athlete's zone boundaries, used to place the marker and read the current zone.
    var zoneModel: HeartRateZoneModel { get }
    /// Session average BPM (recorded aggregate), or nil before the first sample. Persists through a
    /// dropout — the AVG in the HUD's AVG · TIME · MAX row.
    var averageBPM: Int? { get }
    /// Session max BPM (recorded aggregate), or nil before the first sample.
    var maxBPM: Int? { get }
    /// Session elapsed seconds (recorded aggregate) — the TIME in the AVG · TIME · MAX row.
    var sessionElapsed: TimeInterval { get }
}

/// `HeartRateMonitor` already exposes every member of `LiveHeartRateProviding`, so it conforms with
/// no added behavior — the protocol is purely a testing/preview seam.
extension HeartRateMonitor: LiveHeartRateProviding {}
