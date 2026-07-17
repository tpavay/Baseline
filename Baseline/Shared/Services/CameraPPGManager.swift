import AVFoundation
import Foundation
import Observation

/// One processed camera frame — the full diagnostic record. Carries the per-channel means and
/// saturation so the exported telemetry can reveal *why* a reading did or didn't track a pulse
/// (the usual failure is a red channel pinned near 1.0 = saturated = no visible pulse).
struct PPGSnapshot: Sendable {
    let t: Double
    let red: Double
    let green: Double
    let blue: Double
    let brightness: Double
    let saturatedFraction: Double
    let detrended: Double
    let fingerOn: Bool
    let exposureLocked: Bool
    let isBeat: Bool
    let ibi: Double?
    let hr: Int?
    let signalQuality: Double?
    let confidence: Double
    let coverage: PPGProcessor.Coverage
}

/// Fingertip photoplethysmography (PPG) capture: the rear camera with the torch on, reading the
/// mean red channel of each frame off a fingertip pressed to the lens. Feeds the pure
/// `PPGProcessor` to derive beat-to-beat intervals, which flow into the same `HRV` pipeline as
/// the chest strap via `HeartSignalSource`.
///
/// Records full per-frame telemetry (`exportCSV()`) so readings can be analyzed on-device and the
/// algorithm tuned — a shippable capability, not just a debug tool.
///
/// The AVFoundation session + frame math live in a nonisolated `PPGCaptureCoordinator`; this class
/// holds the observable state the UI reads, mutating it only on the main queue (`@unchecked
/// Sendable` upholds that), so SwiftUI observes safely.
@Observable
final class CameraPPGManager: HeartSignalSource, @unchecked Sendable {

    enum Quality: String {
        case waiting = "Cover the lens"
        case acquiring = "Finding your pulse…"
        case locked = "Reading"
        case denied = "Camera access needed"
    }

    private(set) var rrIntervals: [Double] = []
    private(set) var currentHR: Int = 0
    private(set) var quality: Quality = .waiting
    /// Signal-quality proxy (0…1) from beat-interval regularity; low = motion, "hold still".
    private(set) var signalQuality: Double?
    /// Live per-frame coverage quality for user coaching (absent / adjust / good).
    private(set) var coverage: PPGProcessor.Coverage = .absent
    /// Confidence (0…1) that a real periodic pulse is present (autocorrelation peak strength).
    private(set) var confidence: Double = 0
    /// Best confidence seen during the reading — used to accept or honestly reject the result.
    private(set) var peakConfidence: Double = 0
    /// Below this, we don't trust the reading and tell the user rather than show a fake number.
    static let confidenceThreshold = 0.40
    /// Recent detrended waveform samples for the live pulse trace.
    private(set) var waveform: [Double] = []
    /// True once the session is fully configured and running — the preview layer must not attach
    /// to the session before this, or its main-thread reconfiguration races the capture queue's
    /// startRunning (an abort). The UI gates the preview on this.
    private(set) var isRunning = false
    /// Full per-frame log for diagnostics / export.
    private(set) var telemetry: [PPGSnapshot] = []

    var captureStatus: String { quality.rawValue }
    var hasSignal: Bool { quality == .acquiring || quality == .locked }
    var permissionDenied: Bool { quality == .denied }

    @ObservationIgnored private let coordinator = PPGCaptureCoordinator()

    /// The live capture session, for a preview layer so the user sees what the camera sees.
    var session: AVCaptureSession { coordinator.session }

    func startReadingCapture() {
        rrIntervals = []
        currentHR = 0
        quality = .waiting
        waveform = []
        telemetry = []
        confidence = 0
        peakConfidence = 0
        isRunning = false
        coordinator.onFrame = { [weak self] snap in
            DispatchQueue.main.async { self?.apply(snap) }
        }
        coordinator.onStarted = { [weak self] in
            DispatchQueue.main.async { self?.isRunning = true }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            coordinator.start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.coordinator.start() } else { self?.quality = .denied }
                }
            }
        default:
            quality = .denied
        }
    }

    func stopReadingCapture() {
        isRunning = false
        coordinator.stop()
    }

    private func apply(_ snap: PPGSnapshot) {
        telemetry.append(snap)
        if !snap.fingerOn {
            quality = .waiting
        } else if snap.ibi != nil || rrIntervals.count >= 3 {
            quality = rrIntervals.count >= 3 ? .locked : .acquiring
        } else {
            quality = .acquiring
        }
        if snap.fingerOn, let hr = snap.hr { currentHR = hr }
        signalQuality = snap.signalQuality
        coverage = snap.coverage
        confidence = snap.confidence
        peakConfidence = max(peakConfidence, snap.confidence)
        if let ibi = snap.ibi { rrIntervals.append(ibi) }
        if snap.fingerOn {
            waveform.append(snap.detrended)
            if waveform.count > 120 { waveform.removeFirst(waveform.count - 120) }
        }
    }

    /// The full per-frame telemetry as CSV text (the richest raw record of a camera reading).
    func rawCSV() -> String? {
        guard !telemetry.isEmpty else { return nil }
        var csv = "t,red,green,blue,brightness,saturatedFraction,detrended,fingerOn,exposureLocked,isBeat,ibi,hr,confidence\n"
        for s in telemetry {
            csv += String(
                format: "%.3f,%.5f,%.5f,%.5f,%.5f,%.4f,%.6f,%d,%d,%d,%@,%@,%.3f\n",
                s.t, s.red, s.green, s.blue, s.brightness, s.saturatedFraction, s.detrended,
                s.fingerOn ? 1 : 0, s.exposureLocked ? 1 : 0, s.isBeat ? 1 : 0,
                s.ibi.map { String(format: "%.1f", $0) } ?? "",
                s.hr.map(String.init) ?? "", s.confidence
            )
        }
        return csv
    }

    /// Write the full frame log to a CSV in the temp dir and return its URL for sharing/export.
    func exportCSV() -> URL? {
        guard let csv = rawCSV() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ppg-reading-\(telemetry.count)frames.csv")
        do { try csv.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }
}

/// Owns the AVCaptureSession and the PPG processor; runs entirely on its capture queue and emits
/// Sendable snapshots. `@unchecked Sendable` because all mutable state is confined to `queue`.
private final class PPGCaptureCoordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    var onFrame: (@Sendable (PPGSnapshot) -> Void)?
    var onStarted: (@Sendable () -> Void)?

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ppg.capture")
    private var device: AVCaptureDevice?
    private var torchDevice: AVCaptureDevice?
    private var processor = PPGProcessor()
    private var startTime: Date?
    private var running = false
    private var exposureLocked = false
    private var fingerSince: Date?
    private var fingerPrev = false
    private var confFrame = 0
    private var lastConfidence = 0.0

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            teardown()          // clean restart — Try Again after a completed/failed reading
            configureAndStart()
        }
    }

    func stop() {
        queue.async { [weak self] in self?.teardown() }
    }

    private func teardown() {
        running = false
        if session.isRunning { session.stopRunning() }
        setTorch(false)
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
    }

    private func configureAndStart() {
        guard !running else { return }
        processor = PPGProcessor()
        startTime = nil
        exposureLocked = false
        fingerSince = nil
        fingerPrev = false
        let candidates = Self.rearPhysicalCameraCandidates()
        torchDevice = Self.torchCarrier(from: candidates)

        // Telephoto is the lens beside/below the flash on Pro-style triple-camera iPhones — the
        // lens the finger covers together with the torch for PPG. Falls back to Wide (and Ultra
        // Wide) on phones without a telephoto. No manual switching — the finger goes on one spot.
        guard let device = candidates.first,
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        self.device = device

        session.beginConfiguration()
        // A plain low preset gives a torch-stable standard-video format. (Do NOT hand-pick a
        // low-res format by frame rate — the small high-fps formats are slo-mo/high-speed formats
        // that don't support the torch and destabilize on movement: the -17281 errors + torch
        // drop-out.) This delivers ~15 fps with jitter; the processor resamples to a fixed grid, so
        // the exact, uneven capture rate no longer corrupts the filter (see PPGProcessor.ingest).
        session.sessionPreset = .low
        if session.canAddInput(input) { session.addInput(input) }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        configureDevice(device)   // focus/exposure/WB (NOT torch)
        running = true
        session.startRunning()
        // Torch must be enabled AFTER the session is running — otherwise it won't illuminate.
        turnTorchOnWithRetry()
        onStarted?()   // now safe for the preview layer to attach to the session
    }

    private static func rearPhysicalCameraCandidates() -> [AVCaptureDevice] {
        let preferredTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTelephotoCamera,
            .builtInWideAngleCamera,
            .builtInUltraWideCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: preferredTypes,
            mediaType: .video,
            position: .back
        )

        let ordered = preferredTypes.flatMap { type in
            discovery.devices.filter { $0.deviceType == type }
        }
        let unique = ordered.reduce(into: [AVCaptureDevice]()) { result, device in
            if !result.contains(where: { $0.uniqueID == device.uniqueID }) {
                result.append(device)
            }
        }
        if !unique.isEmpty { return unique }

        if let fallback = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            return [fallback]
        }
        return []
    }

    private static func torchCarrier(from candidates: [AVCaptureDevice]) -> AVCaptureDevice? {
        candidates.first(where: \.hasTorch)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    private func configureDevice(_ device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
        // Match the proven reference (ATHeartRate / HRV4Training): leave exposure AND white
        // balance on continuous-auto and just turn the torch on. Auto settles the torch-lit
        // fingertip into the clean red field those apps show.
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        // Torch is enabled separately, after the session starts running (see configureAndStart).
        device.unlockForConfiguration()
    }

    /// Freeze exposure + white balance at their current auto-tuned (finger-lit) values so subtle
    /// finger motion can't trigger re-adjustment that washes out the pulse. Mode `.locked` holds
    /// whatever auto already settled to — no forced values.
    private func lockExposureAndWhiteBalance() {
        guard let device, !exposureLocked, (try? device.lockForConfiguration()) != nil else { return }
        if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
        if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
        device.unlockForConfiguration()
        exposureLocked = true
    }

    private func unlockExposureAndWhiteBalance() {
        guard let device, exposureLocked, (try? device.lockForConfiguration()) != nil else { return }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        device.unlockForConfiguration()
        exposureLocked = false
    }

    private func setTorch(_ on: Bool) {
        guard let torchDevice = currentTorchDevice(requiringAvailable: on),
              (try? torchDevice.lockForConfiguration()) != nil else { return }
        defer { torchDevice.unlockForConfiguration() }
        if on {
            guard torchDevice.isTorchAvailable else { return }
            // A moderate level, NOT max. Full brightness held continuously overheats the LED and
            // iOS auto-cuts it (the "flash turns off" during a reading) — the research's heat
            // warning. 0.5 is plenty of light through a fingertip and stays thermally stable.
            try? torchDevice.setTorchModeOn(level: 0.5)
        } else {
            torchDevice.torchMode = .off
        }
    }

    private func currentTorchDevice(requiringAvailable: Bool = false) -> AVCaptureDevice? {
        let carriers = [device, torchDevice].compactMap { $0 }
        return carriers.first(where: { $0.hasTorch && (!requiringAvailable || $0.isTorchAvailable) })
            ?? carriers.first(where: \.hasTorch)
    }

    private func turnTorchOnWithRetry() {
        setTorch(true)
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, running else { return }
            setTorch(true)
        }
        queue.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self, running else { return }
            setTorch(true)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date()
        if startTime == nil { startTime = now }
        let t = now.timeIntervalSince(startTime!)

        // Keep the torch lit: iOS can drop it (thermal, session events). If it's off while we're
        // running, re-assert it. Cheap check every frame; only re-locks the device when needed.
        if running, let d = currentTorchDevice(), !d.isTorchActive {
            setTorch(true)
        }

        let m = Self.channelMeans(pixelBuffer)
        // Hysteresis: enter finger-on when red is clearly dominant; stay on through brief pressure
        // dips, only releasing when red collapses. Stops the detection flickering that fragmented
        // earlier readings.
        let fingerOn: Bool
        if fingerPrev {
            fingerOn = !PPGProcessor.fingerReleased(red: m.red)
        } else {
            fingerOn = PPGProcessor.fingerPresent(red: m.red, green: m.green, blue: m.blue)
        }

        // Lock exposure + white balance ~1.5 s after the finger settles, freezing the auto-tuned
        // (red, finger-lit) values so subtle finger motion can't make the camera re-adjust and
        // wash out the pulse — the research's key point. Released when the finger lifts.
        if fingerOn {
            if fingerSince == nil { fingerSince = now }
            if !exposureLocked, let since = fingerSince, now.timeIntervalSince(since) > 1.5 {
                lockExposureAndWhiteBalance()
            }
        } else {
            fingerSince = nil
            if exposureLocked { unlockExposureAndWhiteBalance() }
            processor.breakChain()   // finger lifted → don't bridge the gap into a fake IBI
        }
        fingerPrev = fingerOn

        // Run pulse detection on the RED channel. With the torch on and exposure locked, a
        // fingertip is a bright red field whose red intensity is directly modulated by blood
        // volume — on-device telemetry shows red carries the pulse at 3–7× the SNR of green/blue
        // and far better than hue (which, under this strong-red regime, locks onto the 2× harmonic
        // and reports double the true rate). Blood absorbs, so the raw signal is inverted below.
        var ibi: Double?
        if fingerOn {
            ibi = processor.ingest(sample: -m.red, at: t)
        }
        // Confidence is an O(n²) autocorrelation — recompute a few times a second, not per frame.
        confFrame += 1
        if confFrame % 12 == 0 { lastConfidence = processor.pulseConfidence() }
        let snap = PPGSnapshot(
            t: t, red: m.red, green: m.green, blue: m.blue,
            brightness: m.brightness, saturatedFraction: m.saturated,
            detrended: processor.lastWaveformValue,
            fingerOn: fingerOn, exposureLocked: exposureLocked,
            isBeat: ibi != nil, ibi: ibi, hr: processor.currentHR,
            signalQuality: processor.signalQuality, confidence: lastConfidence,
            coverage: PPGProcessor.coverage(red: m.red, green: m.green, blue: m.blue)
        )
        onFrame?(snap)
    }

    /// Per-channel means (0…1) over the center ROI, overall brightness, and the fraction of
    /// sampled pixels with a saturated (≥250) red value — the key diagnostic for a flat signal.
    /// BGRA layout: byte order B,G,R,A per pixel.
    private static func channelMeans(_ buffer: CVPixelBuffer) -> (red: Double, green: Double, blue: Double, brightness: Double, saturated: Double) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (0, 0, 0, 0, 0) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        // Tight center ROI (middle 20%) — on a wide-angle lens the finger may not fill the frame,
        // so sampling only the center avoids diluting the pulse with dark/uncovered edges.
        let x0 = width * 2 / 5, x1 = width * 3 / 5
        let y0 = height * 2 / 5, y1 = height * 3 / 5
        var rSum = 0.0, gSum = 0.0, bSum = 0.0, sat = 0.0, count = 0.0
        var y = y0
        while y < y1 {
            var x = x0
            let row = y * bytesPerRow
            while x < x1 {
                let px = row + x * 4
                let b = Double(ptr[px]); let g = Double(ptr[px + 1]); let r = Double(ptr[px + 2])
                rSum += r; gSum += g; bSum += b
                if r >= 250 { sat += 1 }
                count += 1
                x += 4
            }
            y += 4
        }
        guard count > 0 else { return (0, 0, 0, 0, 0) }
        return (rSum / count / 255, gSum / count / 255, bSum / count / 255,
                (rSum + gSum + bSum) / count / 3 / 255, sat / count)
    }

    deinit {
        if session.isRunning { session.stopRunning() }
    }
}
