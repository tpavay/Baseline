import Foundation
import Observation

/// One point on the live curve: beat-to-beat HR (bpm), derived from one R-R interval.
struct HRSample: Identifiable, Equatable, Sendable {
    let id = UUID()
    let t: TimeInterval
    let hr: Int
}

/// One detected beat, for the live beat-driven waveform: its time in the reading window and the
/// R-R interval (ms) that closed it. The waveform draws one fixed-height spike per beat and labels
/// the interval in the gap — so the trace never rescales with raw signal amplitude.
struct BeatMark: Identifiable, Equatable, Sendable {
    let id = UUID()
    let t: TimeInterval
    let intervalMs: Int
}

/// Drives a single reading: connect the strap → (optional) live preview → a quiet natural-breath
/// read for the reading's duration, streaming the HR curve + live HRV (RMSSD, ms) and finalizing
/// averages over the *reading* window (preview beats excluded). UI-state only — no SwiftUI, no
/// persistence (the view turns `result` into a `Reading`). Uses the shared `BluetoothManager`.
@MainActor
@Observable
final class ReadingSession {
    enum Phase: Equatable { case intro, connecting, preview, countdown, reading, complete, failed }

    let type: ReadingType
    let duration: TimeInterval
    let countdownDuration: TimeInterval
    var usesLivePreview: Bool

    private(set) var phase: Phase = .connecting
    private(set) var elapsed: TimeInterval = 0
    private(set) var hrSeries: [HRSample] = []
    private(set) var beats: [BeatMark] = []
    private(set) var currentHRVms: Double?
    private(set) var result: ReadingResult?

    var remaining: TimeInterval { max(0, duration - elapsed) }
    var currentHR: Int { hrSeries.last?.hr ?? source.currentHR }

    /// A continuously-advancing reading clock, so the waveform can scroll smoothly *between* the
    /// 100 ms ticks (driven by a TimelineView). Falls back to the last ticked `elapsed` off-read.
    var liveElapsed: TimeInterval {
        guard phase == .reading, let phaseStart else { return elapsed }
        return Date().timeIntervalSince(phaseStart)
    }
    /// Source-appropriate status line (strap connection / camera finger quality).
    var captureStatus: String { source.captureStatus }

    /// Whole seconds left in the pre-reading countdown, for the big number. Stored (not computed
    /// off `Date()`) so SwiftUI actually re-renders it each tick while the number ticks down.
    private(set) var countdownRemaining: Int = 6

    /// The most recent beat-to-beat interval (ms), for the live "Δ ms" readout.
    var lastBeatIntervalMs: Int? {
        source.rrIntervals.last.map { Int($0.rounded()) }
    }

    private let source: HeartSignalSource
    private var phaseStart: Date?
    private var connectDeadline: Date?
    private var countdownStart: Date?
    private var windowStartIndex = 0    // first beat index of the active window (preview/reading)
    private var lastBeatCount = 0       // beats already turned into hrSeries points
    nonisolated(unsafe) private var tickTask: Task<Void, Never>?

    init(type: ReadingType, duration: TimeInterval? = nil, countdownDuration: TimeInterval = 6,
         usesLivePreview: Bool, source: HeartSignalSource) {
        self.type = type
        self.duration = duration ?? type.duration
        self.countdownDuration = countdownDuration
        self.usesLivePreview = usesLivePreview
        self.source = source
    }

    /// Start the session. `showIntro` (camera) parks on a static instructional screen and does NOT
    /// begin capture or the connect deadline until `dismissIntro()`.
    func start(showIntro: Bool = false) {
        elapsed = 0
        hrSeries = []
        currentHRVms = nil
        result = nil
        phaseStart = nil
        countdownStart = nil
        windowStartIndex = 0
        lastBeatCount = 0

        if showIntro {
            phase = .intro
        } else {
            startCountdown()   // count down immediately while acquiring the signal
        }

        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.tick() { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Leave the intro (GOT IT): begin capture and start counting down immediately.
    func dismissIntro() {
        guard phase == .intro else { return }
        startCountdown()
    }

    /// Begin the pre-reading countdown right away — it runs while the signal is still being
    /// acquired; the read itself only starts once the countdown reaches zero AND a signal is present.
    func startCountdown() {
        startWindow()
        countdownStart = Date()
        countdownRemaining = Int(countdownDuration.rounded(.up))
        // Fail only if the finger/strap never shows up well *after* the countdown finishes.
        connectDeadline = Date().addingTimeInterval(countdownDuration + 20)
        source.startReadingCapture()
        phase = .countdown
    }

    /// Begin the reading — called when the countdown hits zero.
    func beginReading() {
        startWindow()
        elapsed = 0
        phase = .reading
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        source.stopReadingCapture()
    }

    // MARK: - Loop

    private func tick() -> Bool {
        switch phase {
        case .intro:
            return false   // static; waits for dismissIntro()

        case .connecting, .preview:
            return false   // no longer part of the flow (countdown starts immediately)

        case .countdown:
            // Keep the live HR flowing and tick the number down while acquiring the signal.
            if let phaseStart {
                ingestNewBeats(at: Date().timeIntervalSince(phaseStart))
            }
            updateLiveHRV()
            if let start = countdownStart {
                countdownRemaining = max(0, Int((countdownDuration - Date().timeIntervalSince(start)).rounded(.up)))
            }
            if countdownRemaining <= 0 {
                if source.hasSignal {
                    beginReading()                 // countdown done + signal present → record
                } else if let deadline = connectDeadline, Date() >= deadline {
                    phase = .failed                // never found a signal → fail
                    source.stopReadingCapture()
                    return true
                }
            }
            return false

        case .reading:
            guard let phaseStart else { return false }
            elapsed = Date().timeIntervalSince(phaseStart)
            ingestNewBeats(at: elapsed)
            updateLiveHRV()
            if elapsed >= duration {
                finalize()
                return true
            }
            return false

        case .complete, .failed:
            return true
        }
    }

    /// Reset the active HR window to "now" (current beat index + clock).
    private func startWindow() {
        windowStartIndex = source.rrIntervals.count
        lastBeatCount = windowStartIndex
        hrSeries = []
        beats = []
        currentHRVms = nil
        phaseStart = Date()
    }

    private func ingestNewBeats(at t: TimeInterval) {
        let rr = source.rrIntervals
        guard rr.count > lastBeatCount else { return }
        let newIdx = (lastBeatCount..<rr.count).filter { rr[$0] > 0 }
        // Real detection times on the reading clock: the newest new beat is "now" (`t`); any earlier
        // new beats in the same batch step back by their own intervals. Keeping beats on the same
        // clock as `elapsed` is what lets the waveform scroll smoothly without drifting off-screen.
        var times = [TimeInterval](repeating: 0, count: newIdx.count)
        var bt = t
        for k in stride(from: newIdx.count - 1, through: 0, by: -1) {
            times[k] = bt
            bt -= rr[newIdx[k]] / 1000
        }
        for (k, i) in newIdx.enumerated() {
            hrSeries.append(HRSample(t: times[k], hr: Int((60_000.0 / rr[i]).rounded())))
            beats.append(BeatMark(t: times[k], intervalMs: Int(rr[i].rounded())))
        }
        lastBeatCount = rr.count
    }

    private func updateLiveHRV() {
        let rr = source.rrIntervals
        guard windowStartIndex <= rr.count else { return }
        currentHRVms = HRV.rmssd(Array(rr[windowStartIndex...]))
    }

    private func finalize() {
        let rr = Array(source.rrIntervals[min(windowStartIndex, source.rrIntervals.count)...])
        // HRV is computed on the artifact-CORRECTED series (ectopics/dropouts interpolated), but we
        // persist the RAW R-R for export/diagnostics. The quality rating flags an unreliable read.
        let (corrected, artifacts, quality) = HRV.corrected(rr)
        let hrs = hrSeries.map(\.hr)
        result = ReadingResult(
            type: type,
            durationSeconds: Int(duration),
            meanHR: hrs.isEmpty ? 0 : Double(hrs.reduce(0, +)) / Double(hrs.count),
            minHR: hrs.min() ?? 0,
            maxHR: hrs.max() ?? 0,
            rmssd: HRV.rmssd(corrected) ?? 0,
            lnRMSSD: HRV.lnRmssd(corrected) ?? 0,
            beatCount: rr.count,
            rrIntervalsMs: rr,
            artifacts: artifacts,
            signalQuality: quality
        )
        phase = .complete
        source.stopReadingCapture()
    }

    deinit {
        tickTask?.cancel()
    }
}
