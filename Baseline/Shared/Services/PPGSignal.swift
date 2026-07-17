import Foundation

/// Pure photoplethysmography (PPG) signal processing — no AVFoundation, no UIKit, fully
/// unit-testable. Turns a stream of per-frame **red-channel** samples (the ROI-averaged red
/// intensity of a torch-lit fingertip) into beat-to-beat intervals that feed the same `HRV`
/// pipeline as the chest strap.
///
/// Signal choice is empirical: with the torch on and exposure locked, a fingertip is a bright red
/// field whose red intensity is directly modulated by blood volume. On-device telemetry showed the
/// red channel carries the pulse at 3–7× the SNR of green/blue and far better than hue — under this
/// strong-red regime hue actually locks onto the 2× harmonic and reports double the true rate.
/// Pipeline: **red → resample to a fixed 30 Hz grid → 8th-order Butterworth bandpass
/// (0.667–4.167 Hz) → 5-tap median smoothing → peak detection (local max, refractory, notch-merge,
/// prominence) → artifact correction (reject beats far from the running median)**. The resampling
/// step means the jittery, ~15 fps camera stream is decoupled from the fixed rate the coefficients
/// assume.
struct PPGProcessor {

    // Peak-timing constraints.
    private let minIBI = 300.0
    private let maxIBI = 1600.0
    /// Reject a beat whose interval deviates more than this from the running median (artifact
    /// correction — the standard guard that keeps camera-PPG RMSSD usable).
    private let artifactTolerance = 0.25
    /// Minimum spacing between beats before the pulse period is known (≤170 bpm). Once the
    /// autocorrelation locks a period, `adaptiveRefractoryMs` takes over.
    private let refractoryFloorMs = 350.0
    /// Live refractory window. Starts conservative, then locks to ~0.6× the detected pulse period
    /// so the **dicrotic notch** (a smaller bump ~0.5 period after each beat) can never be
    /// miscounted as a second beat — the low-HR "doubling" failure. See `refreshPulseEstimate()`.
    private var adaptiveRefractoryMs = 500.0

    private(set) var ibis: [Double] = []      // artifact-corrected inter-beat intervals (ms)
    private(set) var lastPeakTime: Double?

    // Streaming Butterworth state.
    private var xv = [Double](repeating: 0, count: 9)
    private var yv = [Double](repeating: 0, count: 9)
    private let gain = 1.232232910e+02

    // Median-smoothing + peak-detection buffers.
    private var filtBuf: [Double] = []                 // last 5 filtered values
    private var sm: [(t: Double, v: Double)] = []      // smoothed samples with timestamps
    private var nextCheck = 3                            // next center index to test as a peak
    private var amplitude = 0.0                          // EMA of |smoothed| for prominence
    private var acceptedWindow: [Double] = []           // recent accepted IBIs for the median

    private var frameCount = 0
    /// Filter warm-up: ignore the first ~1 s while the 8th-order IIR settles.
    private let warmupFrames = 30

    // Fixed-rate resampling. The camera delivers irregular frames at whatever rate the capture
    // format allows (empirically ~15 fps, with 58–360 ms jitter), but the Butterworth coefficients,
    // the warm-up count, and the autocorrelation lag→bpm map all assume a *fixed* rate. So we
    // resample the incoming (t, sample) stream onto a uniform grid at `filterFs` Hz by linear
    // interpolation and run the fixed-rate pipeline on that — decoupling signal correctness from
    // the camera's real, jittery frame rate. `filterFs` MUST match the rate the coefficients assume.
    private let filterFs = 30.0
    private var haveRaw = false
    private var lastRawT = 0.0
    private var lastRawSample = 0.0
    private var nextGridT = 0.0

    /// Whether a finger covers the lens, judged by **red dominance**: with auto white balance a
    /// torch-lit fingertip reads as a bright red field (the solid-red circle HRV4Training shows),
    /// so red is high and clearly the largest channel.
    static func fingerPresent(red: Double, green: Double, blue: Double) -> Bool {
        red > 0.40 && red > green * 1.2 && red > blue * 1.2
    }

    /// Hysteresis release — keep "finger on" through brief dips until red clearly collapses.
    static func fingerReleased(red: Double) -> Bool { red < 0.30 }

    /// Immediate, per-frame coverage quality for live user coaching (HRV4Training-style ring):
    /// `.absent` (no finger — show the "cover the camera" graphic), `.adjust` (partial/weak
    /// coverage — "slightly adjust your finger"), `.good` (fully covered, strong red field).
    enum Coverage: String, Sendable { case absent, adjust, good }

    static func coverage(red: Double, green: Double, blue: Double) -> Coverage {
        guard red > 0.30, red > green * 1.15, red > blue * 1.15 else { return .absent }
        // Strong, well-lit red field with clear dominance = good; otherwise partial coverage.
        if red > 0.45, red > green * 1.5 { return .good }
        return .adjust
    }

    /// Legacy brightness gate (kept for the pure unit test).
    static func fingerPresent(brightness: Double) -> Bool {
        brightness > 0.35 && brightness < 0.99
    }

    /// Feed one raw camera sample (the ROI-averaged **red-channel** intensity, blood-absorption
    /// inverted) at real-clock time `t` (seconds). Resamples onto the fixed-rate grid the filter
    /// assumes, running beat detection on each interpolated grid point. Returns the last IBI (ms)
    /// this call completed, if any.
    mutating func ingest(sample: Double, at t: Double) -> Double? {
        let dt = 1.0 / filterFs
        guard haveRaw else {
            haveRaw = true; lastRawT = t; lastRawSample = sample; nextGridT = t
            return nil
        }
        guard t > lastRawT else { lastRawSample = sample; return nil }   // ignore out-of-order / duplicate
        // A long stall (dropped frames > ~1 s) isn't a heartbeat — don't manufacture a pulse by
        // interpolating across it; break the beat chain and re-anchor the grid.
        if t - lastRawT > 1.0 {
            breakChain()
            lastRawT = t; lastRawSample = sample; nextGridT = t
            return nil
        }
        var completed: Double?
        while nextGridT <= t + 1e-9 {
            let frac = (nextGridT - lastRawT) / (t - lastRawT)
            let interpolated = lastRawSample + (sample - lastRawSample) * min(max(frac, 0), 1)
            if let ibi = processSample(interpolated, at: nextGridT) { completed = ibi }
            nextGridT += dt
        }
        lastRawT = t; lastRawSample = sample
        return completed
    }

    /// One fixed-rate grid sample through the streaming filter + peak detector.
    private mutating func processSample(_ sample: Double, at t: Double) -> Double? {
        frameCount += 1

        // 8th-order Butterworth bandpass (streaming).
        for i in 0..<8 { xv[i] = xv[i + 1] }
        xv[8] = sample / gain
        for i in 0..<8 { yv[i] = yv[i + 1] }
        yv[8] = (xv[0] + xv[8]) - 4 * (xv[2] + xv[6]) + 6 * xv[4]
            + (-0.1397436053 * yv[0]) + (1.2948188815 * yv[1])
            + (-5.4070037946 * yv[2]) + (13.2683981280 * yv[3])
            + (-20.9442560520 * yv[4]) + (21.7932169160 * yv[5])
            + (-14.5817197500 * yv[6]) + (5.7161939252 * yv[7])
        let filtered = yv[8]

        // 5-tap median smoothing (outputs the sample 2 frames back).
        filtBuf.append(filtered)
        if filtBuf.count > 5 { filtBuf.removeFirst() }
        guard frameCount > warmupFrames, filtBuf.count == 5 else { return nil }
        let smoothed = filtBuf.sorted()[2]
        sm.append((t, smoothed))
        if sm.count > 400 { sm.removeFirst(sm.count - 400); nextCheck = max(3, nextCheck - (sm.count)) }

        amplitude = amplitude * 0.98 + abs(smoothed) * 0.02

        // Re-estimate the dominant period + confidence a couple of times a second (the
        // autocorrelation is O(n²), so not every sample). This locks the refractory to the real
        // pulse period so the dicrotic notch can't be double-counted.
        if frameCount % 15 == 0 { refreshPulseEstimate() }

        // Test any center sample that now has 3 successors.
        var completed: Double?
        while nextCheck + 3 < sm.count {
            let c = nextCheck
            let v = sm[c].v
            let isLocalMax = v > sm[c-1].v && v > sm[c-2].v && v > sm[c-3].v
                && v >= sm[c+1].v && v >= sm[c+2].v && v >= sm[c+3].v
            if isLocalMax, v > 0, v > amplitude * 0.4 {
                if let ibi = registerPeak(at: sm[c].t) { completed = ibi }
            }
            nextCheck += 1
        }
        return completed
    }

    private mutating func registerPeak(at t: Double) -> Double? {
        guard let last = lastPeakTime else { lastPeakTime = t; return nil }
        let ibi = (t - last) * 1000
        // Refractory: a peak inside the (period-locked) window is the dicrotic notch / noise. Keep
        // the earlier beat as the true one and drop this candidate WITHOUT advancing the clock, so
        // the notch doesn't reset the timer and split the real interval into two.
        guard ibi >= adaptiveRefractoryMs else { return nil }
        guard ibi >= minIBI, ibi <= maxIBI else { lastPeakTime = t; return nil }

        // Artifact correction: reject an interval that deviates too far from the running median.
        if acceptedWindow.count >= 4 {
            let median = acceptedWindow.sorted()[acceptedWindow.count / 2]
            if ibi < median * (1 - artifactTolerance) || ibi > median * (1 + artifactTolerance) {
                lastPeakTime = t   // still advance the clock so we don't chain across the gap
                return nil
            }
        }
        lastPeakTime = t
        ibis.append(ibi)
        acceptedWindow.append(ibi)
        if acceptedWindow.count > 7 { acceptedWindow.removeFirst() }
        return ibi
    }

    mutating func breakChain() {
        lastPeakTime = nil
    }

    /// Instantaneous heart rate from the median of recent accepted beats (bpm) — median is robust
    /// to the occasional missed/extra beat. Nil until enough beats.
    var currentHR: Int? {
        guard acceptedWindow.count >= 3 else { return nil }
        let median = acceptedWindow.sorted()[acceptedWindow.count / 2]
        guard median > 0 else { return nil }
        return Int((60_000 / median).rounded())
    }

    /// Signal quality (0…1) from the coefficient of variation of recent accepted IBIs. High =
    /// clean/still; low = motion. Nil until enough beats.
    var signalQuality: Double? {
        guard acceptedWindow.count >= 4 else { return nil }
        let mean = acceptedWindow.reduce(0, +) / Double(acceptedWindow.count)
        guard mean > 0 else { return nil }
        let variance = acceptedWindow.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(acceptedWindow.count)
        let cv = variance.squareRoot() / mean
        return max(0, min(1, 1 - cv / 0.30))
    }

    /// Exposed for telemetry: the latest smoothed, bandpassed value (the live waveform).
    var lastWaveformValue: Double { sm.last?.v ?? 0 }

    /// Honest confidence (0…1) that the signal contains a *real periodic pulse* rather than
    /// filtered noise — the peak strength of the autocorrelation in the 40–180 bpm band. This is
    /// the one measure that distinguishes a genuine (if weak) pulse from the pseudo-regular beats
    /// bandpass + refractory manufacture from noise. Below ~0.4 the reading is not trusted; the UI
    /// says "couldn't get a clean pulse" instead of showing a number. Cached — refreshed by
    /// `refreshPulseEstimate()` on a timer (the autocorrelation is O(n²), too costly per sample).
    func pulseConfidence() -> Double { cachedConfidence }

    private var cachedConfidence = 0.0

    /// Recompute confidence AND the dominant pulse period from the autocorrelation of the recent
    /// waveform, then lock the beat refractory to ~0.6× that period. Because the dicrotic notch
    /// falls well inside one period, a refractory scaled to the true period rejects it — killing
    /// the low-HR doubling where the notch was counted as a second beat and the median ran away.
    private mutating func refreshPulseEstimate() {
        guard sm.count > 180 else { return }
        let v = sm.suffix(300).map(\.v)
        let n = v.count
        let mean = v.reduce(0, +) / Double(n)
        let d = v.map { $0 - mean }
        let ac0 = d.reduce(0) { $0 + $1 * $1 } / Double(n)
        guard ac0 > 1e-12 else { return }
        // Fixed grid (filterFs): 180 bpm = 10-frame lag, 40 bpm = 45-frame lag.
        var acf = [Double](repeating: 0, count: 46)
        for lag in 8...45 {
            var s = 0.0
            for i in 0..<(n - lag) { s += d[i] * d[i + lag] }
            acf[lag] = (s / Double(n - lag)) / ac0
        }
        // The dominant in-band period = the strongest genuine local maximum (a descending lobe
        // isn't a period).
        var best = 0.0, bestLag = 0
        for lag in 10...44 where acf[lag] > acf[lag - 1] && acf[lag] > acf[lag + 1] {
            if acf[lag] > best { best = acf[lag]; bestLag = lag }
        }
        cachedConfidence = max(0, min(1, best))
        // Only trust the period once the pulse is credible; then clamp the refractory sensibly.
        if best > 0.3, bestLag > 0 {
            let periodMs = Double(bestLag) / filterFs * 1000
            adaptiveRefractoryMs = min(max(0.6 * periodMs, refractoryFloorMs), 1100)
        }
    }
}
