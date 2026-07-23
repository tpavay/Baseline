import SwiftUI

/// The live heart-rate HUD, top to bottom: a semicircular Z1→Z5 `HeartRateZoneGauge` wrapping the big
/// BPM readout (segments proportional to the athlete's actual zone spans, current zone lit, a pulsing
/// marker at the live position), the zone name, the AVG · TIME · MAX session stats, and a TIME IN
/// ZONE breakdown of the session. Honest treatments remain when the signal is stale, the sensor loses
/// contact, or the strap is (re)connecting — a status line appears *only* for those states, never
/// while streaming normally.
///
/// It binds to an **injected** `LiveHeartRateProviding` (the real `HeartRateMonitor` in the app, a
/// fake in previews/tests). It only ever *reads* that provider: it never constructs a
/// `BluetoothManager` and never starts monitoring — the live capture lifecycle is owned by the future
/// workout-execution wiring (see `docs/implementation/live-heart-rate-go-live.md`), not by this view.
/// All state derivation is pure (`LiveHeartRateStateResolver` + `LiveHeartRatePresentation`); `body`
/// only renders.
struct LiveHeartRateView: View {
    /// The live source. `any` so previews/tests inject a fake; observation still tracks the concrete
    /// `@Observable` monitor, so the HUD re-renders as its state changes.
    let provider: any LiveHeartRateProviding
    /// The session's planned target zone range (each bound 1…5; a single zone is `n...n`). Currently
    /// passed nil by every caller and deliberately **not rendered** (target display is being held);
    /// the value still reaches the gauge's accessible summary so nothing is silently dropped.
    var targetZones: ClosedRange<Int>?

    private var state: LiveHeartRateDisplayState { LiveHeartRateStateResolver.resolve(provider) }

    /// A session has produced data once any sample has been recorded — gates the AVG · TIME · MAX row
    /// (which persists through a dropout, unlike the live number).
    private var hasSessionStats: Bool { provider.averageBPM != nil || provider.sessionElapsed > 0 }

    var body: some View {
        let shares = LiveHeartRatePresentation.zoneTimeShares(provider.zoneTime)
        VStack(spacing: 0) {
            gauge
            contextLine
                .padding(.top, 14)
            if hasSessionStats {
                statsRow
                    .padding(.top, 22)
            }
            if !shares.isEmpty {
                timeInZone(shares)
                    .padding(.top, 26)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.surface))
    }

    // MARK: - Gauge + readout

    /// The hero: the zone gauge wrapping the big BPM number. The number is tinted with the current
    /// zone's color when there is a reading and blanks to a faint placeholder — never a fabricated
    /// number — when there is none; the gauge dims and drops its marker in step.
    private var gauge: some View {
        HeartRateZoneGauge(
            model: provider.zoneModel,
            bpm: state.bpm,
            currentZone: state.zone,
            accessibilitySummary: LiveHeartRatePresentation
                .gaugeAccessibilityValue(state, targetZones: targetZones)
        ) {
            readout
        }
        .frame(maxWidth: 300)
    }

    private var readout: some View {
        VStack(spacing: 2) {
            Text(LiveHeartRatePresentation.bpmText(state))
                .font(.bMono(64, .bold))
                .foregroundStyle(bpmColor)
                .contentTransition(.numericText())
            Text("BPM")
                .font(.bMono(11, .medium)).tracking(3)
                .foregroundStyle(BaselineColor.textFaint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LiveHeartRatePresentation.accessibilityLabel)
        .accessibilityValue(LiveHeartRatePresentation.accessibilityValue(state))
    }

    private var bpmColor: Color {
        guard state.showsNumber else { return BaselineColor.textFaint }
        return state.zone?.color ?? BaselineColor.textHi
    }

    // MARK: - Context line (zone name or a real status)

    /// The single line under the gauge: the zone name ("Z3 · AEROBIC") while streaming normally, or —
    /// only on a real sensor/signal issue or while not yet live — the honest status. The two are
    /// mutually exclusive by construction (`zoneText` is non-nil only for `.streaming`, `statusText`
    /// only for everything else), so a healthy stream never shows a connection line.
    @ViewBuilder
    private var contextLine: some View {
        if let zoneText = LiveHeartRatePresentation.zoneText(state) {
            Text(zoneText.uppercased())
                .font(.bMono(13, .bold)).tracking(1)
                .foregroundStyle(state.zone?.color ?? BaselineColor.textMid)
        } else if let status = LiveHeartRatePresentation.statusText(state) {
            HStack(spacing: 6) {
                if let symbol = LiveHeartRatePresentation.statusSymbol(state) {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                }
                Text(status).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(statusColor)
            .accessibilityElement(children: .combine)
        }
    }

    /// Sensor-off and no-signal are warnings (the number is stale or untrustworthy); (re)connecting
    /// and disconnected are calm neutral text — nothing is wrong, we are just not live yet.
    private var statusColor: Color {
        switch state {
        case .sensorOff, .noSignal: BaselineColor.zoneAmber
        case .streaming, .connecting, .reconnecting, .disconnected: BaselineColor.textMid
        }
    }

    // MARK: - Session stats

    /// AVG · TIME · MAX — session aggregates. Hairline dividers, mono numerals, comfortable spacing.
    /// Persist through a dropout since they summarize recorded samples.
    private var statsRow: some View {
        HStack(spacing: 0) {
            stat("AVG", LiveHeartRatePresentation.statText(provider.averageBPM))
            statDivider
            stat("TIME", LiveHeartRatePresentation.durationText(provider.sessionElapsed))
            statDivider
            stat("MAX", LiveHeartRatePresentation.statText(provider.maxBPM))
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.bMono(20, .bold)).foregroundStyle(BaselineColor.textMid)
                .contentTransition(.numericText())
            Text(label)
                .font(.bMono(9, .medium)).tracking(2).foregroundStyle(BaselineColor.textFaint)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private var statDivider: some View {
        Rectangle().fill(BaselineColor.line).frame(width: 1, height: 30)
    }

    // MARK: - Time in zone

    /// The session's % of time in each zone: a stacked bar (zone colors, width ∝ share) over per-zone
    /// figures. Only rendered once real zone time has been credited — never a fabricated split.
    private func timeInZone(_ shares: [LiveHeartRatePresentation.ZoneTimeShare]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TIME IN ZONE")
                .font(.bMono(10, .medium)).tracking(1.8)
                .foregroundStyle(BaselineColor.textFaint)

            GeometryReader { geo in
                let visible = shares.filter { $0.fraction > 0 }
                let gaps = CGFloat(max(visible.count - 1, 0)) * 2
                HStack(spacing: 2) {
                    ForEach(visible, id: \.zone) { share in
                        Rectangle()
                            .fill(share.zone.color)
                            .frame(width: max((geo.size.width - gaps) * share.fraction, 0))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .frame(height: 22)

            HStack(spacing: 0) {
                ForEach(shares, id: \.zone) { share in
                    VStack(spacing: 3) {
                        Text(share.percentText)
                            .font(.bMono(11, .bold))
                            .foregroundStyle(share.percent > 0 ? share.zone.color : BaselineColor.textFaint)
                            .contentTransition(.numericText())
                        Text(share.zone.displayName)
                            .font(.bMono(9, .medium)).tracking(0.5)
                            .foregroundStyle(BaselineColor.textFaint)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time in zone")
        .accessibilityValue(LiveHeartRatePresentation.timeInZoneAccessibilityValue(shares))
    }
}

// MARK: - Previews

#if DEBUG
/// Preview/test-only fake so the HUD can render every state without a `BluetoothManager` or a live
/// connection. Mirrors `HeartRateMonitor`'s derivation (fresh BPM → zone/contact) so the states it
/// produces are exactly the ones the resolver would see in the app.
@MainActor
final class PreviewLiveHeartRateProvider: LiveHeartRateProviding {
    var freshSample: HeartRateSample?
    var latestSample: HeartRateSample?
    var connectionStatus: BluetoothManager.Status
    var zoneModel: HeartRateZoneModel
    var averageBPM: Int?
    var maxBPM: Int?
    var sessionElapsed: TimeInterval
    var zoneTime: ZoneTimeAccumulator

    var currentBPM: Int? { freshSample?.bpm }
    var currentZone: HeartRateZone? { freshSample.map { zoneModel.zone(forBPM: $0.bpm) } }
    var sensorContact: HeartRateSample.SensorContact? { freshSample?.sensorContact }

    init(freshSample: HeartRateSample?, latestSample: HeartRateSample?,
         connectionStatus: BluetoothManager.Status, zoneModel: HeartRateZoneModel,
         averageBPM: Int? = nil, maxBPM: Int? = nil, sessionElapsed: TimeInterval = 0,
         zoneTime: ZoneTimeAccumulator = ZoneTimeAccumulator()) {
        self.freshSample = freshSample
        self.latestSample = latestSample
        self.connectionStatus = connectionStatus
        self.zoneModel = zoneModel
        self.averageBPM = averageBPM
        self.maxBPM = maxBPM
        self.sessionElapsed = sessionElapsed
        self.zoneTime = zoneTime
    }

    /// A mid-session zone-time spread matching the approved mock's 5 / 18 / 52 / 20 / 5 split.
    static func sessionZoneTime(total: TimeInterval) -> ZoneTimeAccumulator {
        var time = ZoneTimeAccumulator()
        time.credit(.z1, seconds: total * 0.05)
        time.credit(.z2, seconds: total * 0.18)
        time.credit(.z3, seconds: total * 0.52)
        time.credit(.z4, seconds: total * 0.20)
        time.credit(.z5, seconds: total * 0.05)
        return time
    }

    /// A streaming provider at `bpm` with skin contact detected, mid-session (so the stat row and
    /// time-in-zone breakdown show).
    static func streaming(bpm: Int, model: HeartRateZoneModel = .preview) -> PreviewLiveHeartRateProvider {
        let sample = HeartRateSample(bpm: bpm, sensorContact: .detected, receivedAt: Date())
        return PreviewLiveHeartRateProvider(freshSample: sample, latestSample: sample,
                                            connectionStatus: .connected, zoneModel: model,
                                            averageBPM: bpm - 7, maxBPM: bpm + 5, sessionElapsed: 1458,
                                            zoneTime: sessionZoneTime(total: 1439))
    }

    /// Connected but stale (no fresh sample) — the no-signal state, mid-session so aggregates persist.
    static func noSignal(model: HeartRateZoneModel = .preview) -> PreviewLiveHeartRateProvider {
        let last = HeartRateSample(bpm: 150, sensorContact: .detected, receivedAt: Date())
        return PreviewLiveHeartRateProvider(freshSample: nil, latestSample: last,
                                            connectionStatus: .connected, zoneModel: model,
                                            averageBPM: 152, maxBPM: 178, sessionElapsed: 1170,
                                            zoneTime: sessionZoneTime(total: 1150))
    }

    /// A fresh sample that reports lost skin contact — the number is shown but flagged.
    static func sensorOff(model: HeartRateZoneModel = .preview) -> PreviewLiveHeartRateProvider {
        let sample = HeartRateSample(bpm: 150, sensorContact: .notDetected, receivedAt: Date())
        return PreviewLiveHeartRateProvider(freshSample: sample, latestSample: sample,
                                            connectionStatus: .connected, zoneModel: model,
                                            averageBPM: 149, maxBPM: 178, sessionElapsed: 1270,
                                            zoneTime: sessionZoneTime(total: 1250))
    }

    /// Re-establishing after a dropout (a sample arrived earlier, now connecting again).
    static func reconnecting(model: HeartRateZoneModel = .preview) -> PreviewLiveHeartRateProvider {
        let last = HeartRateSample(bpm: 150, sensorContact: .detected, receivedAt: Date())
        return PreviewLiveHeartRateProvider(freshSample: nil, latestSample: last,
                                            connectionStatus: .connecting, zoneModel: model,
                                            averageBPM: 150, maxBPM: 178, sessionElapsed: 1184,
                                            zoneTime: sessionZoneTime(total: 1160))
    }

    /// Initial connection, no sample yet (no session data → no stat row, no zone-time breakdown).
    static func connecting(model: HeartRateZoneModel = .preview) -> PreviewLiveHeartRateProvider {
        PreviewLiveHeartRateProvider(freshSample: nil, latestSample: nil,
                                     connectionStatus: .connecting, zoneModel: model)
    }

    /// No connection, no session (no stat row, no zone-time breakdown).
    static func disconnected(model: HeartRateZoneModel = .preview) -> PreviewLiveHeartRateProvider {
        PreviewLiveHeartRateProvider(freshSample: nil, latestSample: nil,
                                     connectionStatus: .idle, zoneModel: model)
    }
}

extension HeartRateZoneModel {
    /// A representative athlete for previews: max 190, resting 50 → Karvonen bands (Z1 120, Z2 134,
    /// Z3 148, Z4 162, Z5 176).
    static let preview = HeartRateZoneModel(maxHR: 190, restingHR: 50)
}

@MainActor
private func hudPreview(_ provider: PreviewLiveHeartRateProvider, target: ClosedRange<Int>? = nil) -> some View {
    ScrollView {
        LiveHeartRateView(provider: provider, targetZones: target)
            .padding(20)
    }
    .frame(maxWidth: .infinity)
    .background(BaselineColor.base)
}

#Preview("HUD · Z1 streaming · dark") {
    hudPreview(.streaming(bpm: 122)).preferredColorScheme(.dark)
}
#Preview("HUD · Z2 streaming · dark") {
    hudPreview(.streaming(bpm: 138)).preferredColorScheme(.dark)
}
#Preview("HUD · Z3 streaming · dark") {
    hudPreview(.streaming(bpm: 152)).preferredColorScheme(.dark)
}
#Preview("HUD · Z4 streaming · dark") {
    hudPreview(.streaming(bpm: 168)).preferredColorScheme(.dark)
}
#Preview("HUD · Z5 streaming · dark") {
    hudPreview(.streaming(bpm: 184)).preferredColorScheme(.dark)
}
#Preview("HUD · Z3 streaming · light") {
    hudPreview(.streaming(bpm: 152)).preferredColorScheme(.light)
}
#Preview("HUD · no signal · dark") {
    hudPreview(.noSignal()).preferredColorScheme(.dark)
}
#Preview("HUD · sensor off · dark") {
    hudPreview(.sensorOff()).preferredColorScheme(.dark)
}
#Preview("HUD · reconnecting · dark") {
    hudPreview(.reconnecting()).preferredColorScheme(.dark)
}
#Preview("HUD · connecting · dark") {
    hudPreview(.connecting()).preferredColorScheme(.dark)
}
#Preview("HUD · disconnected · dark") {
    hudPreview(.disconnected()).preferredColorScheme(.dark)
}
#endif
