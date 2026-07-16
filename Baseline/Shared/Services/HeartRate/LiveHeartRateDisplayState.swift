import Foundation

/// What `LiveHeartRateView` should show right now, resolved once from the monitor so `body` never
/// re-derives it. The distinction that matters is honesty: a BPM number only ever appears in the
/// `.streaming` case, which is reachable only from a *fresh* sample. Every non-streaming case is a
/// reason there is no live number to show, so the view can render an explicit state instead of a
/// stale reading dressed up as live (`baseline-live-heart-rate` honest-data rule).
enum LiveHeartRateDisplayState: Equatable, Hashable, Sendable {
    /// A fresh sample with skin contact: show the BPM, its zone, and the marker position (0…1).
    case streaming(bpm: Int, zone: HeartRateZone, position: Double)
    /// A fresh sample whose strap reports lost skin contact. The BPM is still shown (it is real data)
    /// but flagged as unreliable, rather than trusted silently — the HUD renders it with a warning.
    case sensorOff(bpm: Int, zone: HeartRateZone, position: Double)
    /// Connected, but the sample went stale (BLE has no "signal lost" push — silence is the signal).
    /// No BPM is shown.
    case noSignal
    /// Establishing the first connection to the strap (no sample has ever arrived).
    case connecting
    /// Re-establishing after a drop (a sample arrived earlier this run, then the link was lost).
    case reconnecting
    /// No connection: idle, Bluetooth off, or unauthorized.
    case disconnected

    /// A fully trusted live reading — only `.streaming`. Drives the "is the number solid?" styling.
    var isLive: Bool { if case .streaming = self { return true } else { return false } }

    /// Whether a BPM number is shown at all: the trusted `.streaming` reading or the flagged
    /// `.sensorOff` one. The non-reading states show a placeholder instead.
    var showsNumber: Bool {
        switch self {
        case .streaming, .sensorOff: true
        case .noSignal, .connecting, .reconnecting, .disconnected: false
        }
    }

    /// The BPM to display, if any (streaming or flagged sensor-off).
    var bpm: Int? {
        switch self {
        case let .streaming(bpm, _, _), let .sensorOff(bpm, _, _): bpm
        default: nil
        }
    }

    /// The current zone, if a reading exists (streaming or sensor-off) — tints the number and marks
    /// the spectrum.
    var zone: HeartRateZone? {
        switch self {
        case let .streaming(_, zone, _), let .sensorOff(_, zone, _): zone
        default: nil
        }
    }

    /// The 0…1 spectrum marker position, if a reading exists.
    var position: Double? {
        switch self {
        case let .streaming(_, _, position), let .sensorOff(_, _, position): position
        default: nil
        }
    }
}

/// Pure monitor-state → `LiveHeartRateDisplayState` mapping. Kept out of the view and off `Date()` so
/// it is exhaustively unit-testable with a hand-driven `LiveHeartRateProviding` fake and no
/// CoreBluetooth. The precedence encodes the honesty rule: freshness is checked *before* connection
/// status, so a stale sample can never be presented as a live number even while "connected".
enum LiveHeartRateStateResolver {

    /// Resolve the display state for a provider's current live state.
    ///
    /// Precedence:
    /// 1. A **fresh** sample with lost contact → `.sensorOff` (the number exists but isn't credible).
    /// 2. A **fresh** sample with contact → `.streaming` (the only state that shows a BPM).
    /// 3. No fresh sample → explain *why* from the connection status:
    ///    - connected → `.noSignal` (linked but silent),
    ///    - connecting/scanning → `.reconnecting` if a sample arrived earlier this run, else
    ///      `.connecting`,
    ///    - idle/off/unauthorized → `.disconnected`.
    @MainActor
    static func resolve(_ provider: some LiveHeartRateProviding) -> LiveHeartRateDisplayState {
        if let sample = provider.freshSample {
            let zone = provider.zoneModel.zone(forBPM: sample.bpm)
            let position = provider.zoneModel.position(forBPM: sample.bpm)
            if sample.sensorContact == .notDetected {
                return .sensorOff(bpm: sample.bpm, zone: zone, position: position)
            }
            return .streaming(bpm: sample.bpm, zone: zone, position: position)
        }

        switch provider.connectionStatus {
        case .connected:
            return .noSignal
        case .connecting, .scanning:
            return provider.latestSample == nil ? .connecting : .reconnecting
        case .idle, .bluetoothOff, .unauthorized:
            return .disconnected
        }
    }
}
