import Foundation

/// Pure display-state → strings mapping for `LiveHeartRateView`, so `body` renders text it is handed
/// rather than composing it inline. Also produces the VoiceOver label/value so the spoken form is
/// pinned by tests alongside the visual form.
enum LiveHeartRatePresentation {

    /// The large numeric readout: the BPM when there is a reading (`.streaming` or flagged
    /// `.sensorOff`), an em-dash placeholder otherwise (there is deliberately no fallback number — a
    /// non-reading state has no live BPM to show).
    static func bpmText(_ state: LiveHeartRateDisplayState) -> String {
        state.bpm.map(String.init) ?? "--"
    }

    /// A session-aggregate stat (AVG / MAX) as text, or an em-dash before any sample exists.
    static func statText(_ value: Int?) -> String {
        value.map(String.init) ?? "--"
    }

    /// Elapsed session time as `m:ss` (or `h:mm:ss` past an hour). Negative input clamps to `0:00`.
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// The zone headline, "Z{n} · {Title}" (e.g. "Z3 · Aerobic"), only when streaming.
    static func zoneText(_ state: LiveHeartRateDisplayState) -> String? {
        guard case let .streaming(_, zone, _) = state else { return nil }
        return "\(zone.displayName) · \(zone.title)"
    }

    /// The zone headline for any zone, independent of state (used by the target-band caption).
    static func zoneText(_ zone: HeartRateZone) -> String {
        "\(zone.displayName) · \(zone.title)"
    }

    /// Short status line shown under the readout for the non-streaming states (nil while streaming).
    static func statusText(_ state: LiveHeartRateDisplayState) -> String? {
        switch state {
        case .streaming: nil
        case .noSignal: "No signal — check the strap"
        case .sensorOff: "Sensor not detecting skin contact"
        case .connecting: "Connecting to strap…"
        case .reconnecting: "Reconnecting…"
        case .disconnected: "Strap disconnected"
        }
    }

    /// SF Symbol paired with the status line, so the state reads at a glance without color alone.
    static func statusSymbol(_ state: LiveHeartRateDisplayState) -> String? {
        switch state {
        case .streaming: nil
        case .noSignal: "wave.3.right"
        case .sensorOff: "hand.raised.slash"
        case .connecting, .reconnecting: "antenna.radiowaves.left.and.right"
        case .disconnected: "antenna.radiowaves.left.and.right.slash"
        }
    }

    // MARK: - Time in zone

    /// One zone's share of the session's credited time, for the TIME IN ZONE breakdown.
    struct ZoneTimeShare: Equatable {
        let zone: HeartRateZone
        /// Exact fraction of the total credited time (0…1) — drives the stacked bar's widths.
        let fraction: Double
        /// Integer percent for the per-zone figure. Across all five zones these sum to exactly 100.
        let percent: Int

        var percentText: String { "\(percent)%" }
    }

    /// Shares for every zone in Z1…Z5 order, or `[]` before any zone time has been credited (the
    /// breakdown is hidden rather than showing a fabricated all-zero split). Integer percents use
    /// largest-remainder rounding so they always sum to 100 — the bar and the figures can never
    /// disagree about the whole.
    static func zoneTimeShares(_ zoneTime: ZoneTimeAccumulator) -> [ZoneTimeShare] {
        let total = zoneTime.total
        guard total > 0 else { return [] }
        let fractions = HeartRateZone.allCases.map { zoneTime.seconds(in: $0) / total }
        let floors = fractions.map { Int(($0 * 100).rounded(.down)) }

        // Hand the leftover points to the largest fractional remainders; ties go to the lower zone
        // so the result is deterministic.
        var percents = floors
        let byRemainder = fractions.indices.sorted { a, b in
            let ra = fractions[a] * 100 - Double(floors[a])
            let rb = fractions[b] * 100 - Double(floors[b])
            return ra == rb ? a < b : ra > rb
        }
        for index in 0..<(100 - floors.reduce(0, +)) {
            percents[byRemainder[index % byRemainder.count]] += 1
        }

        return HeartRateZone.allCases.enumerated().map { index, zone in
            ZoneTimeShare(zone: zone, fraction: fractions[index], percent: percents[index])
        }
    }

    /// VoiceOver value for the TIME IN ZONE breakdown, e.g. "Z1 5 percent, Z2 18 percent, …".
    static func timeInZoneAccessibilityValue(_ shares: [ZoneTimeShare]) -> String {
        shares.map { "\($0.zone.displayName) \($0.percent) percent" }.joined(separator: ", ")
    }

    // MARK: - Accessibility

    /// VoiceOver label — the stable name of the element.
    static var accessibilityLabel: String { "Live heart rate" }

    /// VoiceOver value — the spoken current reading or state, mirroring what is shown.
    static func accessibilityValue(_ state: LiveHeartRateDisplayState) -> String {
        switch state {
        case let .streaming(bpm, zone, _):
            "\(bpm) beats per minute, \(zone.displayName) \(zone.title)"
        case let .sensorOff(bpm, zone, _):
            "\(bpm) beats per minute, \(zone.displayName) \(zone.title), sensor not detecting contact"
        case .noSignal: "No signal"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .disconnected: "Disconnected"
        }
    }

    /// A target zone or zone-range spoken form, e.g. "Target Z3 Aerobic" or "Target Z1 to Z2".
    /// Clamps to 1…5 and returns nil for an empty/degenerate range.
    static func targetZonesText(_ zones: ClosedRange<Int>) -> String? {
        let lo = max(zones.lowerBound, 1), hi = min(zones.upperBound, 5)
        guard lo <= hi, let low = HeartRateZone(rawValue: lo), let high = HeartRateZone(rawValue: hi) else {
            return nil
        }
        return low == high
            ? "Target \(low.displayName) \(low.title)"
            : "Target \(low.displayName) to \(high.displayName)"
    }

    /// Accessible summary for the zone gauge: current zone + BPM, or the reason none is shown, plus
    /// the planned target zone/range when one is set.
    static func gaugeAccessibilityValue(_ state: LiveHeartRateDisplayState, targetZones: ClosedRange<Int>?) -> String {
        let base: String
        switch state {
        case let .streaming(bpm, zone, _), let .sensorOff(bpm, zone, _):
            base = "Current zone \(zone.displayName) \(zone.title), \(bpm) beats per minute"
        case .noSignal, .connecting, .reconnecting, .disconnected:
            base = "No live zone"
        }
        guard let targetZones, let text = targetZonesText(targetZones) else { return base }
        return "\(base). \(text)"
    }
}
