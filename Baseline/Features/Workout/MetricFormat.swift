import Foundation

extension MetricType {
    /// Duration-shaped metrics share the smart time format everywhere.
    var isDurationKind: Bool { self == .duration || self == .heartRateZoneTime }
}

/// The **single source of truth** for how metric values read and parse across the app — workout cells,
/// history, plan aggregates, import review, agent summaries. Durations follow one rule: **anything of a
/// minute or more reads in minutes** (`10:00`), never raw seconds; only sub-minute values read as
/// seconds. Values are stored canonically (seconds/kg/meters); this is presentation + parsing only.
///
/// Both directions are hardened: display never traps on absurd stored values (a bad import/agent write
/// must not crash a render), and parse never returns non-finite, negative, or beyond-ceiling values
/// (`Int(Double)` traps above Int64.max — reproduced before this guard existed).
enum MetricFormat {

    /// Canonical ceilings — generous beyond any real training value, small enough to keep every
    /// downstream Int conversion safe. Durations cap at 7 days; everything else at 10 million.
    static let maxDurationSeconds: Double = 604_800
    static let maxCanonicalValue: Double = 10_000_000

    // MARK: - Duration (canonical seconds)

    /// Read-only display: `45s` · `10:00` · `1:05:00`.
    static func duration(_ seconds: Double) -> String {
        let total = safeInt(seconds)
        if total < 60 { return "\(total)s" }
        return clock(total)
    }

    /// Editable-field text — round-trip stable (a bare number parses as minutes, so sub-minute values
    /// must render with a colon): `0:45` · `10:00` · `1:05:00`.
    static func durationEditText(_ seconds: Double) -> String {
        clock(safeInt(seconds))
    }

    /// Coarse summary form for aggregates/cards: `45s` · `38m` · `4h 40m`.
    static func durationLong(_ seconds: Double) -> String {
        let total = safeInt(seconds)
        if total < 60 { return "\(total)s" }
        let m = total / 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    private static func safeInt(_ d: Double) -> Int {
        guard d.isFinite else { return 0 }
        return Int(min(max(d, 0), maxDurationSeconds).rounded())
    }

    private static func clock(_ total: Int) -> String {
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Parse duration text → canonical seconds. **Bare numbers are minutes** (the common case — typing
    /// "10" means a 10-minute effort); `1:30` = m:ss; `1:05:00` = h:mm:ss; `0:45` or a `s` suffix for
    /// seconds; `m`/`min`/`h` suffixes respected. Returns nil for garbage; results are sanitized
    /// (finite, non-negative, capped, whole seconds).
    static func parseDuration(_ raw: String) -> Double? {
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty else { return nil }

        if t.contains(":") {
            let parts = t.split(separator: ":", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
            // A trailing colon ("10:") means the seconds half is pending — treat as minutes.
            let values = parts.enumerated().compactMap { i, v -> Double? in
                if v == nil && i == parts.count - 1 && t.hasSuffix(":") { return 0 }
                return v
            }
            guard values.count == parts.count, !values.isEmpty else { return nil }
            switch values.count {
            case 1: return sanitizeDuration(values[0] * 60)
            case 2: return sanitizeDuration(values[0] * 60 + values[1])
            case 3: return sanitizeDuration(values[0] * 3600 + values[1] * 60 + values[2])
            default: return nil
            }
        }
        for (suffix, factor) in [("sec", 1.0), ("s", 1.0), ("min", 60.0), ("m", 60.0), ("h", 3600.0)] {
            if t.hasSuffix(suffix), let d = Double(t.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) {
                return sanitizeDuration(d * factor)
            }
        }
        guard let d = Double(t) else { return nil }
        return sanitizeDuration(d * 60)   // bare number = minutes
    }

    private static func sanitizeDuration(_ d: Double) -> Double? {
        guard d.isFinite else { return nil }
        return min(max(d, 0), maxDurationSeconds).rounded()   // whole seconds — duration is integer-kind
    }

    // MARK: - Any metric (canonical → display unit and back)

    /// Display a canonical value in the given unit, with the unit suffix (`80 kg`, `3.11 mi`, `10:00`).
    static func value(_ canonical: Double, _ metric: MetricType, unit: MetricUnit) -> String {
        if metric.isDurationKind { return duration(canonical) }
        let d = MetricConvert.fromCanonical(canonical, metric, to: unit)
        let num = number(d, metric)
        return unit.short.isEmpty ? num : "\(num) \(unit.short)"
    }

    /// Bare editable text for a table cell (no unit suffix — the column header carries the unit).
    static func editText(_ canonical: Double, _ metric: MetricType, unit: MetricUnit) -> String {
        if metric.isDurationKind { return durationEditText(canonical) }
        return number(MetricConvert.fromCanonical(canonical, metric, to: unit), metric)
    }

    /// Parse field text → canonical. Durations use the smart parser; everything else is a plain number
    /// in the display unit. Returns nil for garbage; results are finite, non-negative, capped, and
    /// rounded for integer metrics.
    static func parse(_ text: String, _ metric: MetricType, unit: MetricUnit) -> Double? {
        if metric.isDurationKind { return parseDuration(text) }
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let d = Double(t) else { return nil }
        let canonical = MetricConvert.toCanonical(d, metric, from: unit)
        guard canonical.isFinite else { return nil }
        let clamped = min(max(canonical, 0), maxCanonicalValue)
        return metric.isInteger ? clamped.rounded() : clamped
    }

    /// The column header for a metric cell — the unit where one exists, TIME for durations.
    static func columnHeader(_ metric: MetricType, unit: MetricUnit) -> String {
        if metric.isDurationKind { return "TIME" }
        return unit.short.isEmpty ? metric.label.uppercased() : unit.short.uppercased()
    }

    private static func number(_ d: Double, _ metric: MetricType) -> String {
        guard d.isFinite else { return "—" }
        let clamped = min(max(d, 0), maxCanonicalValue)
        if metric.isInteger || clamped == clamped.rounded() { return String(Int(clamped.rounded())) }
        // Up to two readable decimals, trailing zeros trimmed — "3.11", "102.5", never "3.10686".
        var s = String(format: "%.2f", clamped)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
