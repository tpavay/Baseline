import SwiftUI
import SwiftData
import Charts

/// All saved readings: an HRV (ms) trend plus a reverse-chronological list. The payoff for
/// taking lots of quick snapshots.
struct ReadingHistoryView: View {
    @Query(sort: \Reading.date, order: .reverse) private var readings: [Reading]

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            if readings.isEmpty {
                ContentUnavailableView(
                    "No readings yet",
                    systemImage: "waveform.path.ecg",
                    description: Text("Your readings will show up here.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        trend
                        VStack(spacing: 10) {
                            ForEach(readings) { reading in
                                NavigationLink {
                                    ReadingDetailView(reading: reading)
                                } label: {
                                    ReadingRow(reading: reading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BaselineColor.base, for: .navigationBar)
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HRV TREND (ms)").font(.system(size: 12, weight: .semibold)).tracking(0.5).foregroundStyle(BaselineColor.accent)
            Chart(readings.reversed()) { r in
                LineMark(x: .value("Date", r.date), y: .value("HRV", r.rmssd))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(BaselineColor.accent)
                PointMark(x: .value("Date", r.date), y: .value("HRV", r.rmssd))
                    .foregroundStyle(BaselineColor.accent)
                    .symbolSize(28)
            }
            .frame(height: 180)
            .chartYAxis {
                AxisMarks(position: .leading) {
                    AxisGridLine().foregroundStyle(BaselineColor.line)
                    AxisValueLabel().foregroundStyle(BaselineColor.textFaint)
                }
            }
            .chartXAxis {
                AxisMarks {
                    AxisGridLine().foregroundStyle(BaselineColor.line)
                    AxisValueLabel().foregroundStyle(BaselineColor.textFaint)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BaselineColor.surface))
    }
}

private struct ReadingRow: View {
    let reading: Reading
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(reading.kind.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                Text(reading.date, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(reading.rmssd.rounded()))").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(BaselineColor.textHi)
                    Text("ms").font(.system(size: 11, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
                }
                Text("\(Int(reading.meanHR.rounded())) bpm").font(.system(size: 12, weight: .medium)).foregroundStyle(BaselineColor.textMid)
            }
        }
        .padding(.horizontal, 16).frame(height: 60)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.surface))
    }
}

#Preview {
    NavigationStack { ReadingHistoryView() }
        .modelContainer(for: Reading.self, inMemory: true)
}
