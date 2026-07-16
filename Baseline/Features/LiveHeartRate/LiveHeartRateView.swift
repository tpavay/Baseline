import SwiftUI

/// The live heart-rate HUD: a large BPM number, the zone name ("Z3 · Aerobic"), the full Z1→Z5
/// `HeartRateZoneSpectrum` with a marker and an optional planned-target outline, and honest
/// treatments when the signal is stale, the sensor loses contact, or the strap is (re)connecting.
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
    /// The session's planned target zone range (each bound 1…5; a single zone is `n...n`), outlined on
    /// the spectrum. nil hides the outline. Per design review the outline is the *only* target cue —
    /// there is no target text.
    var targetZones: ClosedRange<Int>?

    private var state: LiveHeartRateDisplayState { LiveHeartRateStateResolver.resolve(provider) }

    /// A session has produced data once any sample has been recorded — gates the AVG · TIME · MAX row
    /// (which persists through a dropout, unlike the live number).
    private var hasSessionStats: Bool { provider.averageBPM != nil || provider.sessionElapsed > 0 }

    var body: some View {
        VStack(spacing: 18) {
            readout
            if hasSessionStats { statsRow }
            statusLine
            HeartRateZoneSpectrum(
                currentZone: state.zone,
                position: state.position,
                targetZones: targetZones,
                accessibilitySummary: LiveHeartRatePresentation
                    .spectrumAccessibilityValue(state, targetZones: targetZones)
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.surface))
    }

    // MARK: - Readout

    /// The hero number: big, mono, tinted with the current zone's color when there is a reading (the
    /// zone identity now lives in the tint + the spectrum, not a text label). Blanks to a faint
    /// placeholder — never a fabricated number — when there is no live reading.
    private var readout: some View {
        VStack(spacing: 4) {
            Text(LiveHeartRatePresentation.bpmText(state))
                .font(.bMono(64, .bold))
                .foregroundStyle(bpmColor)
                .contentTransition(.numericText())
            Text("BPM")
                .font(.bMono(11, .medium)).tracking(3)
                .foregroundStyle(BaselineColor.textFaint)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LiveHeartRatePresentation.accessibilityLabel)
        .accessibilityValue(LiveHeartRatePresentation.accessibilityValue(state))
    }

    private var bpmColor: Color {
        guard state.showsNumber else { return BaselineColor.textFaint }
        return state.zone?.color ?? BaselineColor.textHi
    }

    /// AVG · TIME · MAX — session aggregates, replacing the old zone-name line. Hairline dividers, mono
    /// numerals. Persist through a dropout since they summarize recorded samples.
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
        VStack(spacing: 4) {
            Text(value)
                .font(.bMono(17, .bold)).foregroundStyle(BaselineColor.textMid)
                .contentTransition(.numericText())
            Text(label)
                .font(.bMono(9, .medium)).tracking(1.5).foregroundStyle(BaselineColor.textFaint)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private var statDivider: some View {
        Rectangle().fill(BaselineColor.line).frame(width: 1, height: 26)
    }

    /// The honest-state line under the stats: a warning for a stale signal or lost sensor contact,
    /// calm neutral text while (re)connecting or disconnected, and nothing at all while streaming.
    @ViewBuilder
    private var statusLine: some View {
        if let status = LiveHeartRatePresentation.statusText(state) {
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

    var currentBPM: Int? { freshSample?.bpm }
    var currentZone: HeartRateZone? { freshSample.map { zoneModel.zone(forBPM: $0.bpm) } }
    var sensorContact: HeartRateSample.SensorContact? { freshSample?.sensorContact }

    init(freshSample: HeartRateSample?, latestSample: HeartRateSample?,
         connectionStatus: BluetoothManager.Status, zoneModel: HeartRateZoneModel,
         averageBPM: Int? = nil, maxBPM: Int? = nil, sessionElapsed: TimeInterval = 0) {
        self.freshSample = freshSample
        self.latestSample = latestSample
        self.connectionStatus = connectionStatus
        self.zoneModel = zoneModel
        self.averageBPM = averageBPM
        self.maxBPM = maxBPM
        self.sessionElapsed = sessionElapsed
    }

    /// A streaming provider at `bpm` with skin contact detected, mid-session (so the stat row shows).
    static func streaming(bpm: Int, model: HeartRateZoneModel = .preview) -> PreviewLiveHeartRateProvider {
        let sample = HeartRateSample(bpm: bpm, sensorContact: .detected, receivedAt: Date())
        return PreviewLiveHeartRateProvider(freshSample: sample, latestSample: sample,
                                            connectionStatus: .connected, zoneModel: model,
                                            averageBPM: bpm - 7, maxBPM: bpm + 5, sessionElapsed: 1458)
    }

    /// Connected but stale (no fresh sample) — the no-signal state, mid-session so aggregates persist.
    static func noSignal(model: HeartRateZoneModel = .preview) -> PreviewLiveHeartRateProvider {
        let last = HeartRateSample(bpm: 150, sensorContact: .detected, receivedAt: Date())
        return PreviewLiveHeartRateProvider(freshSample: nil, latestSample: last,
                                            connectionStatus: .connected, zoneModel: model,
                                            averageBPM: 152, maxBPM: 178, sessionElapsed: 1170)
    }

    /// A fresh sample that reports lost skin contact — the number is shown but flagged.
    static func sensorOff(model: HeartRateZoneModel = .preview) -> PreviewLiveHeartRateProvider {
        let sample = HeartRateSample(bpm: 150, sensorContact: .notDetected, receivedAt: Date())
        return PreviewLiveHeartRateProvider(freshSample: sample, latestSample: sample,
                                            connectionStatus: .connected, zoneModel: model,
                                            averageBPM: 149, maxBPM: 178, sessionElapsed: 1270)
    }

    /// Re-establishing after a dropout (a sample arrived earlier, now connecting again).
    static func reconnecting(model: HeartRateZoneModel = .preview) -> PreviewLiveHeartRateProvider {
        let last = HeartRateSample(bpm: 150, sensorContact: .detected, receivedAt: Date())
        return PreviewLiveHeartRateProvider(freshSample: nil, latestSample: last,
                                            connectionStatus: .connecting, zoneModel: model,
                                            averageBPM: 150, maxBPM: 178, sessionElapsed: 1184)
    }

    /// Initial connection, no sample yet (no session data → no stat row).
    static func connecting(model: HeartRateZoneModel = .preview) -> PreviewLiveHeartRateProvider {
        PreviewLiveHeartRateProvider(freshSample: nil, latestSample: nil,
                                     connectionStatus: .connecting, zoneModel: model)
    }

    /// No connection, no session (no stat row).
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

private func hudPreview(_ provider: PreviewLiveHeartRateProvider, target: ClosedRange<Int>? = nil) -> some View {
    LiveHeartRateView(provider: provider, targetZones: target)
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(BaselineColor.base)
}

#Preview("HUD · Z1 streaming · dark") {
    hudPreview(.streaming(bpm: 122)).preferredColorScheme(.dark)
}
#Preview("HUD · Z2 streaming · target Z1–Z2 · dark") {
    hudPreview(.streaming(bpm: 138), target: 1...2).preferredColorScheme(.dark)
}
#Preview("HUD · Z3 streaming · target Z4 · dark") {
    hudPreview(.streaming(bpm: 152), target: 4...4).preferredColorScheme(.dark)
}
#Preview("HUD · Z4 streaming · dark") {
    hudPreview(.streaming(bpm: 168)).preferredColorScheme(.dark)
}
#Preview("HUD · Z5 streaming · dark") {
    hudPreview(.streaming(bpm: 184)).preferredColorScheme(.dark)
}
#Preview("HUD · Z3 streaming · light") {
    hudPreview(.streaming(bpm: 152), target: 4...4).preferredColorScheme(.light)
}
#Preview("HUD · no signal · dark") {
    hudPreview(.noSignal(), target: 3...3).preferredColorScheme(.dark)
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
