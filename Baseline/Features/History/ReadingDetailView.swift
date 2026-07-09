import SwiftUI

/// Full breakdown of a saved reading + an export of its raw data (incl. the R-R array) for
/// diagnostics.
struct ReadingDetailView: View {
    let reading: Reading
    @State private var exportItems: [URL] = []

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 4) {
                        Text("\(Int(reading.rmssd.rounded()))")
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .foregroundStyle(BaselineColor.textHi)
                        Text("HRV (ms)").font(.system(size: 13, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
                    }
                    .padding(.top, 16)

                    Text(reading.date, format: .dateTime.weekday().month().day().hour().minute())
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(BaselineColor.textMid)

                    LazyVGrid(columns: columns, spacing: 12) {
                        stat("Source", reading.source.title)
                        stat("Signal", reading.signalQuality.rawValue.capitalized)
                        stat("Avg HR", "\(Int(reading.meanHR.rounded())) bpm")
                        stat("HR range", "\(reading.minHR)–\(reading.maxHR)")
                        stat("Beats", "\(reading.beatCount)")
                        stat("Artifacts", "\(reading.artifacts) corrected")
                        stat("lnRMSSD", String(format: "%.2f", reading.lnRMSSD))
                        stat("Duration", "\(reading.durationSeconds)s")
                    }

                    if !exportItems.isEmpty {
                        ShareLink(items: exportItems) {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.up")
                                Text("Export raw data")
                            }
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.accent))
                        }
                        .padding(.top, 8)
                    }

                    Text(reading.hasRawSignal
                         ? "Exports the JSON (every R-R interval) + the raw per-frame camera signal — for diagnostics."
                         : "Exports a JSON file with every R-R interval — share it for diagnostics.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(BaselineColor.textFaint)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
        }
        .navigationTitle(reading.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BaselineColor.base, for: .navigationBar)
        .onAppear { exportItems = reading.exportShareItems() }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(BaselineColor.textHi)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BaselineColor.surface))
    }
}

#Preview {
    NavigationStack {
        ReadingDetailView(reading: Reading(kind: .morning, durationSeconds: 150, meanHR: 51,
                                           minHR: 42, maxHR: 62, rmssd: 219, lnRMSSD: 5.39,
                                           beatCount: 120, rrIntervalsMs: [900, 1100, 980, 1050]))
    }
}
