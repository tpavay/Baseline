import Charts
import SwiftUI

/// A completed workout's measured heart rate over time: the trace, the zones it moved through, and
/// the avg/max it produced.
///
/// Distinct from `WorkoutHeartRateChart`, which plots manually-logged per-set heart rates on an index
/// axis. Those are unordered point measurements and an index axis is honest for them; this one has a
/// real time axis and must never be fed anything else.
///
/// The data set is resolved once into `@State` and recomputed only when the trace identity changes —
/// never inside `body`, where tap selection would re-filter and re-sort the whole series on every
/// frame.
struct WorkoutHeartRateTraceChart: View {
    let capture: WorkoutHeartRateCapture
    var startedAt: Date?
    var finishedAt: Date?

    @State private var dataSet: WorkoutHeartRateTraceDataSet?
    @State private var selectedElapsed: TimeInterval?

    var body: some View {
        // Resolved once per pass and handed down: the nearest-point scan is linear in the drawn
        // series, and the header, the animation, the selection marks and the change handler all want
        // the same answer while the athlete scrubs.
        let selected = selectedPoint
        return VStack(alignment: .leading, spacing: BaselineSpacing.small) {
            header(selected)
            if let dataSet {
                chart(dataSet, selected: selected)
            }
        }
        .task(id: identity) { resolve() }
    }

    /// Recompute only when the trace this view is showing actually changes.
    private var identity: String {
        "\(capture.trace.count)-\(capture.trace.startAt?.timeIntervalSince1970 ?? 0)-\(startedAt?.timeIntervalSince1970 ?? 0)"
    }

    private func resolve() {
        dataSet = WorkoutHeartRateTraceDataSet(
            capture: capture,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
        selectedElapsed = nil
    }

    // MARK: - Header

    private func header(_ selected: WorkoutHeartRateTraceDataSet.Point?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            InstrumentLabel("HEART RATE", tracking: 1)
            Spacer()
            if let selected {
                // The tapped reading replaces the summary rather than crowding in beside it: one
                // number in that slot at a time keeps the row readable while scrubbing.
                Text("\(selected.bpm) BPM at \(MetricFormat.durationEditText(selected.elapsed))")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(BaselineColor.textHi)
                    .transition(.opacity)
            } else if let readout = capture.summary.readout {
                Text(readout)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(BaselineColor.textFaint)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: selected?.id)
    }

    private var selectedPoint: WorkoutHeartRateTraceDataSet.Point? {
        guard let dataSet, let selectedElapsed else { return nil }
        return dataSet.nearestPoint(toElapsed: selectedElapsed)
    }

    // MARK: - Chart

    private func chart(
        _ dataSet: WorkoutHeartRateTraceDataSet,
        selected: WorkoutHeartRateTraceDataSet.Point?
    ) -> some View {
        Chart {
            // Bands first so the trace always reads on top of them.
            ForEach(dataSet.zoneBands) { band in
                RectangleMark(
                    yStart: .value("Zone floor", band.lowerBPM),
                    yEnd: .value("Zone ceiling", band.upperBPM)
                )
                .foregroundStyle(band.zone.color.opacity(0.10))
            }

            ForEach(dataSet.points) { point in
                if dataSet.canPlotLine {
                    LineMark(
                        x: .value("Time", point.elapsed),
                        y: .value("Heart rate", point.bpm)
                    )
                    .foregroundStyle(BaselineColor.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
                } else {
                    // One or two readings: show the measurements, never a line implying a trend
                    // between them.
                    PointMark(
                        x: .value("Time", point.elapsed),
                        y: .value("Heart rate", point.bpm)
                    )
                    .foregroundStyle(BaselineColor.accent)
                    .symbolSize(40)
                }
            }

            if let selected {
                RuleMark(x: .value("Time", selected.elapsed))
                    .foregroundStyle(BaselineColor.accent.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: BaselineSize.hairline))
                PointMark(
                    x: .value("Time", selected.elapsed),
                    y: .value("Heart rate", selected.bpm)
                )
                .foregroundStyle(BaselineColor.accent)
                .symbolSize(56)
            }
        }
        .frame(height: BaselineSize.traceChartHeight)
        .chartXScale(domain: 0...dataSet.duration)
        .chartYScale(domain: dataSet.heartRateRange)
        .chartXSelection(value: $selectedElapsed)
        .chartXAxis { xAxis(dataSet) }
        .chartYAxis { yAxis(dataSet) }
        .chartOverlay { proxy in zoneLabels(dataSet, proxy: proxy) }
        // A scrub is continuous value-picking, not a discrete tap: `chartXSelection` moves through
        // every nearest point the finger crosses, so an impact generator would machine-gun hundreds
        // of hits across one slow drag. The selection generator is the one built for this.
        .onChange(of: selected?.id) { _, newValue in
            if newValue != nil { Haptics.select() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dataSet.accessibilityLabel(summary: capture.summary))
    }

    /// The zone letter inside its own band, at the left edge of the plot.
    ///
    /// Positioned rather than listed: the bands are horizontal strips, so a row of letters along the
    /// top would name them in an order that has nothing to do with where they are. A band too short
    /// to hold its label is left unlabelled rather than crowded — the colour still reads, and the
    /// spoken summary carries the same information for VoiceOver.
    private func zoneLabels(_ dataSet: WorkoutHeartRateTraceDataSet, proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let plot = geometry[anchor]
                ForEach(dataSet.zoneBands) { band in
                    if let top = proxy.position(forY: band.upperBPM),
                       let bottom = proxy.position(forY: band.lowerBPM),
                       bottom - top >= Self.minimumLabelledBandHeight {
                        Text(band.zone.displayName)
                            .font(.bMono(9, .medium))
                            .foregroundStyle(band.zone.color.opacity(0.75))
                            .position(
                                x: plot.minX + BaselineSpacing.large,
                                y: plot.minY + (top + bottom) / 2
                            )
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Below this a band cannot hold a 9 pt label without touching its own edges.
    private static let minimumLabelledBandHeight: CGFloat = 16

    private func xAxis(_ dataSet: WorkoutHeartRateTraceDataSet) -> some AxisContent {
        AxisMarks(values: (0...4).map { Double($0) * dataSet.duration / 4 }) { value in
            AxisGridLine().foregroundStyle(BaselineColor.line)
            if let elapsed = value.as(Double.self) {
                let anchor: UnitPoint = elapsed == 0 ? .topLeading
                    : elapsed == dataSet.duration ? .topTrailing : .top
                AxisValueLabel(anchor: anchor) {
                    Text(MetricFormat.durationEditText(elapsed))
                        .font(.bMono(10, .medium))
                        .foregroundStyle(BaselineColor.textFaint)
                }
            }
        }
    }

    private func yAxis(_ dataSet: WorkoutHeartRateTraceDataSet) -> some AxisContent {
        AxisMarks(position: .leading, values: dataSet.heartRateTickValues) { value in
            AxisGridLine().foregroundStyle(BaselineColor.line)
            if let bpm = value.as(Int.self) {
                AxisValueLabel {
                    Text("\(bpm)")
                        .font(.bMono(10, .medium))
                        .foregroundStyle(BaselineColor.textFaint)
                }
            }
        }
    }
}

#if DEBUG
extension WorkoutHeartRateCapture {
    /// A realistic half-hour session, shared by the preview and the render tests so both look at the
    /// same trace.
    static func previewSession(
        startingAt start: Date,
        seconds: Int = 1_800,
        model: HeartRateZoneModel = HeartRateZoneModel(maxHR: 190, restingHR: 52)
    ) -> WorkoutHeartRateCapture {
        var points: [HeartRateTracePoint] = []
        points.reserveCapacity(seconds)
        for second in 0..<seconds {
            let drift = 26 * sin(Double(second) / 190)
            let ripple = 6 * sin(Double(second) / 23)
            let bpm = Int((138 + drift + ripple).rounded())
            points.append(HeartRateTracePoint(timestamp: start.addingTimeInterval(Double(second)), bpm: bpm))
        }
        let rates = points.map(\.bpm)
        let summary = WorkoutHeartRateSummary(
            averageBPM: rates.isEmpty ? nil : rates.reduce(0, +) / rates.count,
            maxBPM: rates.max(),
            sampleCount: points.count,
            zoneSeconds: [120, 460, 780, 380, 60],
            zoneModel: HeartRateZoneModelSnapshot(model)
        )
        return WorkoutHeartRateCapture(trace: WorkoutHeartRateTrace(points: points), summary: summary)
    }
}

#Preview("Heart-rate trace") {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    return BaselineCard {
        WorkoutHeartRateTraceChart(
            capture: .previewSession(startingAt: start),
            startedAt: start,
            finishedAt: start.addingTimeInterval(1_800)
        )
    }
    .padding(BaselineSpacing.large)
    .background(BaselineColor.base)
    .preferredColorScheme(.dark)
}
#endif
