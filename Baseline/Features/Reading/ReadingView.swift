import SwiftUI
import SwiftData
import UIKit

/// The full HRV reading flow in the Instrument design system. The Start screen is a focused,
/// connected monitor — short live-signal strip, a one-line device status, collapsed settings,
/// and a clear call to action; tapping Start drops straight into the natural-breath read;
/// the result shows HRV ms + 0–100 readiness + metrics, auto-saved.
struct ReadingView: View {
    let type: ReadingType

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    private let bluetooth: BluetoothManager
    /// Embedded mode (onboarding): the flow owns navigation — the result screen's primary
    /// action hands the finished result back instead of dismissing, and export/discard hide.
    private let onFinish: ((ReadingResult?) -> Void)?
    @State private var session: ReadingSession
    @State private var cues: ReadingCues?
    @State private var savedReading: Reading?
    @State private var exportURL: URL?

    init(type: ReadingType,
         duration: TimeInterval? = nil,
         usesLivePreview: Bool,
         bluetooth: BluetoothManager,
         onFinish: ((ReadingResult?) -> Void)? = nil) {
        self.type = type
        self.bluetooth = bluetooth
        self.onFinish = onFinish
        _session = State(initialValue: ReadingSession(type: type, duration: duration, usesLivePreview: true, source: bluetooth))
    }

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            switch session.phase {
            case .intro, .connecting, .preview, .countdown, .reading:
                ReadingSurfaceView(
                    session: session,
                    style: .strap,
                    background: { BaselineColor.base },
                    onGotIt: {},
                    onStop: { close() }
                )
            case .complete:             resultContent
            case .failed:               failedContent
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            let engine = ReadingCues()
            engine.prepare()
            cues = engine
            session.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            cues?.stop()
            session.stop()
        }
        .onChange(of: session.phase) { _, phase in
            switch phase {
            case .complete:
                cues?.complete()
                if savedReading == nil, let result = session.result {
                    let reading = Reading(result: result, position: settings.readingPosition,
                                          source: .chestStrap,
                                          deviceName: bluetooth.connectedDeviceName ?? "Chest strap")
                    modelContext.insert(reading)
                    if let ecg = bluetooth.rawECGCSV() { reading.saveRawSignal(ecg) }   // raw 130Hz ECG if captured
                    savedReading = reading
                    exportURL = reading.exportFileURL()
                }
            default:
                break
            }
        }
    }

    private func close() {
        cues?.stop()
        session.stop()
        if let onFinish {
            onFinish(session.phase == .complete ? session.result : nil)
        } else {
            dismiss()
        }
    }

    private func discard() {
        if let savedReading { modelContext.delete(savedReading) }
        close()
    }

    // MARK: - Result

    private var resultContent: some View {
        let r = session.result
        let rr = r?.rrIntervalsMs ?? []
        let score = r.map { HRV.readinessScore(lnRMSSD: $0.lnRMSSD) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                InstrumentLabel("READING COMPLETE")
                Spacer()
                Circle().fill(BaselineColor.zoneGreen).frame(width: 7, height: 7)
                Text("SAVED").font(.bMono(11, .medium)).tracking(1).foregroundStyle(BaselineColor.zoneGreen)
            }
            .padding(.top, 8)
            Hairline().padding(.top, 14)

            HStack(spacing: 0) {
                InstrumentStat(value: r.map { String(Int($0.rmssd.rounded())) } ?? "—", label: "HRV · RMSSD (MS)", size: 52)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(BaselineColor.line).frame(width: 1, height: 64)
                InstrumentStat(value: score.map { "\($0)" } ?? "—", label: "READINESS / 100", size: 52, color: BaselineColor.zoneGreen)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 20)
            }
            .padding(.vertical, 18)

            Hairline()
            metricRow("SDNN", ms(HRV.sdnn(rr)))
            metricRow("pNN50", pct(HRV.pnn50(rr)))
            metricRow("lnRMSSD", r.map { String(format: "%.2f", $0.lnRMSSD) } ?? "—")
            metricRow("Mean RR", ms(HRV.meanRR(rr)))
            metricRow("Avg HR", r.map { "\(Int($0.meanHR.rounded())) bpm" } ?? "—")
            metricRow("Beats", r.map { "\($0.beatCount)" } ?? "—")

            Spacer(minLength: 12)

            Button { close() } label: { Text(onFinish == nil ? "DONE" : "CONTINUE") }
                .buttonStyle(InstrumentButtonStyle())
            if onFinish == nil {
                HStack(spacing: 12) {
                    if let exportURL {
                        ShareLink(item: exportURL) { Text("EXPORT") }
                            .buttonStyle(InstrumentOutlineButtonStyle())
                    }
                    Button { discard() } label: { Text("DISCARD") }
                        .buttonStyle(InstrumentOutlineButtonStyle(color: BaselineColor.textFaint))
                }
                .padding(.top, 12).padding(.bottom, 16)
            } else {
                Spacer().frame(height: 16)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                InstrumentLabel(label, tracking: 1)
                Spacer()
                Text(value).font(.bMono(15, .bold)).foregroundStyle(BaselineColor.textHi)
            }
            .frame(height: 40)
            Hairline()
        }
    }

    private func ms(_ v: Double?) -> String { v.map { "\(Int($0.rounded())) ms" } ?? "—" }
    private func pct(_ v: Double?) -> String { v.map { "\(Int($0.rounded())) %" } ?? "—" }

    // MARK: - Failed

    private var failedContent: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "heart.slash").font(.system(size: 38, weight: .semibold)).foregroundStyle(BaselineColor.textMid)
            Text("COULDN'T FIND YOUR STRAP").font(.bMono(15, .bold)).tracking(1).foregroundStyle(BaselineColor.textHi).padding(.top, 4)
            Text("Make sure your chest strap is on and Bluetooth is enabled.")
                .font(.system(size: 14)).foregroundStyle(BaselineColor.textMid)
                .multilineTextAlignment(.center).padding(.horizontal, 44)
            Spacer()
            VStack(spacing: 12) {
                Button { session.start() } label: { Text("TRY AGAIN") }.buttonStyle(InstrumentButtonStyle())
                Button { close() } label: { Text("CLOSE").font(.bMono(11)).tracking(1).foregroundStyle(BaselineColor.textFaint) }
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
    }
}

#Preview {
    ReadingView(type: .snapshot, usesLivePreview: true, bluetooth: BluetoothManager())
        .environment(AppSettings())
        .modelContainer(for: Reading.self, inMemory: true)
}
