import Foundation

/// A source of beat-to-beat heart data for a reading — a chest strap over BLE or the phone
/// camera (fingertip PPG). `ReadingSession` consumes this so the reading flow is identical
/// regardless of source; only the capture front-end differs.
///
/// Conformers are `@Observable` and only mutated on the main actor (`BluetoothManager` marshals
/// CoreBluetooth callbacks to main; `CameraPPGManager` marshals its capture-queue frames), so
/// the main-actor `ReadingSession` reads these properties safely.
protocol HeartSignalSource: AnyObject {
    /// R-R (inter-beat) intervals in milliseconds, growing during capture.
    var rrIntervals: [Double] { get }
    /// Latest instantaneous heart rate (bpm), 0 if not yet available.
    var currentHR: Int { get }
    /// A short, source-appropriate status line (e.g. "Connected", "Cover the lens").
    var captureStatus: String { get }
    /// Whether a usable signal is currently flowing (strap streaming / finger detected).
    var hasSignal: Bool { get }

    func startReadingCapture()
    func stopReadingCapture()
}
