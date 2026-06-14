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
}
