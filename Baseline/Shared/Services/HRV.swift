import Foundation

/// Pure HRV math + BLE Heart Rate Measurement parsing.
/// No hardware, no UIKit/SwiftUI — fully unit-testable.
enum HRV {

    /// Parse a BLE Heart Rate Measurement (`0x2A37`) payload.
    /// Spec: flags byte, then HR (uint8 or uint16), optional energy expended (uint16),
    /// optional R-R intervals (uint16 each, units of 1/1024 s).
    /// - Returns: heart rate in bpm and any R-R intervals converted to milliseconds.
    static func parseMeasurement(_ data: Data) -> (hr: Int, rrMs: [Double]) {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return (0, []) }

        var i = 1
        let hr: Int
        if flags & 0x01 != 0 {                       // bit 0: HR is uint16
            guard bytes.count >= 3 else { return (0, []) }
            hr = Int(bytes[1]) | (Int(bytes[2]) << 8)
            i = 3
        } else {                                      // HR is uint8
            guard bytes.count >= 2 else { return (0, []) }
            hr = Int(bytes[1])
            i = 2
        }

        if flags & 0x08 != 0 { i += 2 }               // bit 3: energy expended present → skip uint16

        var rr: [Double] = []
        if flags & 0x10 != 0 {                         // bit 4: R-R intervals present
            while i + 1 < bytes.count {
                let raw = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
                rr.append(Double(raw) * 1000.0 / 1024.0)
                i += 2
            }
        }
        return (hr, rr)
    }

    /// Drop physiologically implausible R-R intervals (ms). A crude first-pass artifact filter;
    /// real ectopic-beat correction comes later.
    static func cleaned(_ rr: [Double], min: Double = 300, max: Double = 2000) -> [Double] {
        rr.filter { $0 >= min && $0 <= max }
    }

    /// Signal-quality rating from the fraction of beats that needed correcting (Elite/Kubios style).
    enum SignalQuality: String, Codable, Sendable { case good, fair, poor }

    /// Kubios/Malik-style artifact correction. Finds R-R intervals that deviate too far from their
    /// local median — ectopic beats, missed beats, strap dropouts — and replaces *only those* with
    /// an interpolated value, preserving real beat-to-beat variability (RSA) and the beat count
    /// (unlike a hard drop, which biases the series). Runs a couple of passes so a cluster of bad
    /// beats settles. Returns the corrected series, how many were corrected, and a quality rating.
    static func corrected(_ rr: [Double], tolerance: Double = 0.30, window: Int = 5)
        -> (rr: [Double], artifacts: Int, quality: SignalQuality) {
        guard rr.count >= 3 else { return (rr, 0, .good) }
        var out = rr
        var flagged = [Bool](repeating: false, count: rr.count)

        for _ in 0..<2 {
            for i in 0..<out.count {
                let lo = Swift.max(0, i - window), hi = Swift.min(out.count, i + window + 1)
                var neighbors = Array(out[lo..<i]) + Array(out[(i + 1)..<hi])
                guard !neighbors.isEmpty else { continue }
                neighbors.sort()
                let median = neighbors[neighbors.count / 2]
                if abs(out[i] - median) > tolerance * median {
                    let prev = i > 0 ? out[i - 1] : median
                    let next = i < out.count - 1 ? out[i + 1] : median
                    out[i] = (prev + next) / 2
                    flagged[i] = true
                }
            }
        }
        let artifacts = flagged.filter { $0 }.count
        let pct = Double(artifacts) / Double(rr.count) * 100
        let quality: SignalQuality = pct < 5 ? .good : (pct < 15 ? .fair : .poor)
        return (out, artifacts, quality)
    }

    /// Root mean square of successive differences (ms). `nil` if fewer than 2 intervals.
    static func rmssd(_ rr: [Double]) -> Double? {
        guard rr.count >= 2 else { return nil }
        var sumSq = 0.0
        for i in 1..<rr.count {
            let d = rr[i] - rr[i - 1]
            sumSq += d * d
        }
        return (sumSq / Double(rr.count - 1)).squareRoot()
    }

    /// Natural log of RMSSD — the value most HRV apps trend (more normally distributed).
    static func lnRmssd(_ rr: [Double]) -> Double? {
        guard let r = rmssd(rr), r > 0 else { return nil }
        return Foundation.log(r)
    }

    /// Mean R-R interval (ms). `nil` if empty.
    static func meanRR(_ rr: [Double]) -> Double? {
        guard !rr.isEmpty else { return nil }
        return rr.reduce(0, +) / Double(rr.count)
    }

    /// Standard deviation of N-N intervals (ms). `nil` if fewer than 2 intervals.
    static func sdnn(_ rr: [Double]) -> Double? {
        guard rr.count >= 2, let mean = meanRR(rr) else { return nil }
        let variance = rr.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(rr.count - 1)
        return variance.squareRoot()
    }

    /// pNN50 — percent of successive R-R differences greater than 50 ms. `nil` if fewer than 2.
    static func pnn50(_ rr: [Double]) -> Double? {
        guard rr.count >= 2 else { return nil }
        var over = 0
        for i in 1..<rr.count where abs(rr[i] - rr[i - 1]) > 50 { over += 1 }
        return Double(over) / Double(rr.count - 1) * 100
    }

    /// Elite-style 0–100 normalization of lnRMSSD (≈ lnRMSSD / 6.5 × 100, clamped). A friendly
    /// readiness number alongside the raw ms — not yet baseline-relative (that arrives with the
    /// rolling baseline + composite readiness score).
    static func readinessScore(lnRMSSD: Double) -> Int {
        Int((max(0, min(1, lnRMSSD / 6.5)) * 100).rounded())
    }
}
