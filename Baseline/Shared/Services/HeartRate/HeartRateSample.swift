import Foundation

/// A single live heart-rate reading from a connected strap, parsed from the standard BLE Heart Rate
/// Measurement characteristic (`0x2A37`). Unlike the resting HRV path (`HRV.parseMeasurement`), the
/// live path needs only the instantaneous BPM plus sensor-contact state — R-R intervals are not
/// required for workout heart-rate tracking (see `live-heart-rate-contract`).
struct HeartRateSample: Equatable, Sendable {

    /// Skin-contact state reported by bits 1–2 of the measurement flags. `unsupported` when the
    /// strap does not advertise the feature; a chest strap typically reports `detected` once worn.
    enum SensorContact: Equatable, Sendable {
        case unsupported
        case notDetected
        case detected
    }

    let bpm: Int
    let sensorContact: SensorContact
    /// Transport receipt time. The `HeartRateMonitor` re-stamps arrival with its own injected clock
    /// for freshness/zone-time, so this is provenance only and need not be trusted for timing.
    let receivedAt: Date

    /// Parse a `0x2A37` payload into a live sample. Byte layout per the Bluetooth Heart Rate Service
    /// spec: byte 0 flags — bit 0 = value format (0 → UInt8, 1 → UInt16 little-endian), bit 2 =
    /// sensor-contact feature supported, bit 1 = contact detected. Returns nil for a malformed or
    /// zero-BPM payload.
    static func parse(_ data: Data, receivedAt: Date = Date()) -> HeartRateSample? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }

        let flags = bytes[0]
        let isSixteenBit = flags & 0b0000_0001 != 0

        let bpm: Int
        if isSixteenBit {
            guard bytes.count >= 3 else { return nil }
            bpm = Int(bytes[1]) | (Int(bytes[2]) << 8)
        } else {
            bpm = Int(bytes[1])
        }
        guard bpm > 0 else { return nil }

        let sensorContact: SensorContact
        if flags & 0b0000_0100 != 0 {                        // bit 2: feature supported
            sensorContact = flags & 0b0000_0010 != 0 ? .detected : .notDetected
        } else {
            sensorContact = .unsupported
        }

        return HeartRateSample(bpm: bpm, sensorContact: sensorContact, receivedAt: receivedAt)
    }
}

/// The live-heart-rate seam the `HeartRateMonitor` reads. `BluetoothManager` is the production
/// conformer (reusing the one paired strap); tests inject a fake so the monitor's freshness and
/// zone-time logic runs without CoreBluetooth.
///
/// Not `@MainActor`: `BluetoothManager` is main-confined by convention (CoreBluetooth delivers on
/// the main queue) rather than actor-isolated, so this protocol stays non-isolated to match, and
/// `onLiveSample` is a plain closure invoked on the main queue. The `HeartRateMonitor` bridges into
/// its main-actor state with `MainActor.assumeIsolated`, which is safe under this main-queue
/// invariant.
protocol LiveHeartRateSource: AnyObject {
    /// The most recent parsed live sample, or nil before the first one / after stopping.
    var liveSample: HeartRateSample? { get }
    /// Current connection status, surfaced for a "connecting/connected/lost" indicator.
    var connectionStatus: BluetoothManager.Status { get }
    /// Invoked on the main queue for each new live sample. The monitor sets this to accumulate
    /// zone-time; assigning nil detaches.
    var onLiveSample: ((HeartRateSample) -> Void)? { get set }

    /// Enter live streaming on the remembered strap (or scan for the first one if none saved).
    func startLiveMonitoring()
    /// Leave live streaming and drop the connection.
    func stopLiveMonitoring()
}
