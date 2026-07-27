import Foundation

/// Everything `WorkoutHeartRateTraceChart` draws, resolved once from a persisted trace.
///
/// Pure and `Equatable` on purpose: the clipping, the elapsed mapping, the axis range, the tick
/// values, the short-series guard, and the display decimation are all unit-testable without a view
/// tree, and the chart holds one of these in `@State` rather than recomputing it in `body` (the
/// version this is ported from re-filtered and re-sorted the whole series on every render frame,
/// including every tap-selection frame).
struct WorkoutHeartRateTraceDataSet: Equatable {

    /// Below this, a line is a lie: two points draw a straight segment that implies a trend nobody
    /// measured. Matches the source implementation's guard.
    static let minimumLineSampleCount = 3

    /// Samples kept for *display*. The stored series stays full-resolution; at ~390 pt wide and 180 pt
    /// tall there is no visible difference beyond this, and it removes the main-thread cliff of
    /// emitting one mark per second of a 90-minute session (~5400 marks in one chart).
    static let maximumPlottedPoints = 400

    /// A sample outside the session window by more than this is a different session's stray reading.
    private static let clipTolerance: TimeInterval = 60

    struct Point: Identifiable, Equatable {
        let id: Int
        /// Seconds from the workout start, clamped into `0...duration`.
        let elapsed: TimeInterval
        let bpm: Int
    }

    /// One zone's band behind the trace, already clipped to the drawn y-range.
    struct ZoneBand: Identifiable, Equatable {
        let zone: HeartRateZone
        let lowerBPM: Int
        let upperBPM: Int
        var id: Int { zone.rawValue }
    }

    /// Points to draw — decimated. `sampleCount` is what was actually recorded.
    let points: [Point]
    let sampleCount: Int
    let duration: TimeInterval
    let heartRateRange: ClosedRange<Int>
    let heartRateTickValues: [Int]
    let zoneBands: [ZoneBand]

    var isEmpty: Bool { points.isEmpty }

    /// Whether there is enough shape to draw a line: at least three points spread over at least two
    /// distinct whole seconds. One point, or three that all landed in the same second, is a dot.
    var canPlotLine: Bool {
        let distinctSeconds = Set(points.map { Int($0.elapsed.rounded()) })
        return points.count >= Self.minimumLineSampleCount && distinctSeconds.count >= 2
    }

    init(
        trace: WorkoutHeartRateTrace,
        startedAt: Date,
        duration: TimeInterval,
        zoneModel: HeartRateZoneModel? = nil,
        maximumPlottedPoints: Int = maximumPlottedPoints
    ) {
        let visibleDuration = max(duration, 1)
        let windowStart = startedAt.addingTimeInterval(-Self.clipTolerance)
        let windowEnd = startedAt.addingTimeInterval(visibleDuration + Self.clipTolerance)

        let retained = trace.points
            .filter { $0.bpm > 0 && $0.timestamp >= windowStart && $0.timestamp <= windowEnd }
            .sorted { $0.timestamp < $1.timestamp }
            .enumerated()
            .map { index, point in
                Point(
                    id: index,
                    elapsed: min(max(point.timestamp.timeIntervalSince(startedAt), 0), visibleDuration),
                    bpm: point.bpm
                )
            }

        sampleCount = retained.count
        self.duration = visibleDuration
        // The axis is computed from every retained sample, before decimation, so thinning the drawn
        // line can never move the scale under it.
        let range = Self.range(for: retained.map(\.bpm))
        heartRateRange = range
        heartRateTickValues = Self.tickValues(for: range)
        zoneBands = Self.zoneBands(model: zoneModel, clippedTo: range)
        points = Self.decimated(retained, to: maximumPlottedPoints)
    }

    /// Convenience for a persisted capture.
    ///
    /// The window is the **union** of the session's bookends and the trace's own span. In practice the
    /// trace is recorded during the session and the two agree within seconds, so the union changes
    /// nothing — but when they disagree (a log that lost a bookend, a clock that moved, a series
    /// restored beside a differently-stamped session) the union still shows every sample on a real
    /// axis. Intersecting them instead would silently collapse a half-hour trace into a one-second
    /// axis and show a stack of dots, which looks like a rendering bug and hides real training.
    init(
        capture: WorkoutHeartRateCapture,
        startedAt: Date?,
        finishedAt: Date?,
        maximumPlottedPoints: Int = maximumPlottedPoints
    ) {
        let start = [startedAt, capture.trace.startAt].compactMap { $0 }.min()
            ?? Date(timeIntervalSince1970: 0)
        let end = [finishedAt, capture.trace.endAt].compactMap { $0 }.max()
        self.init(
            trace: capture.trace,
            startedAt: start,
            duration: end.map { $0.timeIntervalSince(start) } ?? 0,
            zoneModel: capture.summary.zoneModel?.model,
            maximumPlottedPoints: maximumPlottedPoints
        )
    }

    /// The drawn point nearest an x position, for tap selection.
    func nearestPoint(toElapsed elapsed: TimeInterval) -> Point? {
        points.min { abs($0.elapsed - elapsed) < abs($1.elapsed - elapsed) }
    }

    /// Spoken description of the whole chart — the trace is one accessibility element, because 400
    /// individually-focusable points is not a usable VoiceOver experience.
    func accessibilityLabel(summary: WorkoutHeartRateSummary?) -> String {
        guard isEmpty == false else { return "No heart-rate samples" }
        var parts = ["Heart rate over time"]
        if let average = summary?.averageBPM { parts.append("average \(average) beats per minute") }
        if let maximum = summary?.maxBPM { parts.append("maximum \(maximum)") }
        parts.append("over \(MetricFormat.durationEditText(duration))")
        if let dominant = summary?.secondsByZoneOrdered.filter({ $0.seconds > 0 }).max(by: { $0.seconds < $1.seconds }) {
            parts.append("most time in \(dominant.zone.displayName) \(dominant.zone.title)")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Axis

    private static func range(for heartRates: [Int]) -> ClosedRange<Int> {
        guard let lowest = heartRates.min(), let highest = heartRates.max() else { return 60...180 }
        if lowest == highest { return max(30, lowest - 5)...(highest + 5) }
        let padding = max(3, Int(ceil(Double(highest - lowest) * 0.1)))
        return max(30, lowest - padding)...(highest + padding)
    }

    /// Exactly five ticks with the endpoints pinned, so the axis always states its own bounds.
    private static func tickValues(for range: ClosedRange<Int>) -> [Int] {
        let distance = range.upperBound - range.lowerBound
        guard distance > 0 else { return [range.lowerBound] }
        let interval = Double(distance) / 4
        var ticks = (0...4).map { range.lowerBound + Int((Double($0) * interval).rounded()) }
        ticks[0] = range.lowerBound
        ticks[4] = range.upperBound
        return ticks
    }

    // MARK: - Zone bands

    /// Zone bands read straight from `HeartRateZoneModel.lowerBPM(for:)` — the same shared accessor
    /// the settings preview and the live spectrum use — so a band behind the trace can never disagree
    /// with the zone a BPM was classified into.
    ///
    /// A band runs from its zone's floor to the *next* zone's floor, not to the inclusive display
    /// upper (`next floor − 1`): these are continuous areas, and using the display value would leave
    /// a one-bpm unpainted seam between every pair. The outermost bands extend to the plot edges so
    /// the whole area is covered.
    ///
    /// Deliberately *not* stretching `heartRateRange` down to the Z1 floor: on a hard session that
    /// would squash a 150–180 trace into the top of a 100–180 axis to reveal a band the athlete was
    /// never in. Bands exist to read the trace, not the other way round.
    private static func zoneBands(
        model: HeartRateZoneModel?,
        clippedTo range: ClosedRange<Int>
    ) -> [ZoneBand] {
        guard let model else { return [] }
        return HeartRateZone.allCases.compactMap { zone in
            let next = HeartRateZone(rawValue: zone.rawValue + 1)
            let floor = zone == HeartRateZone.allCases.first
                ? min(model.lowerBPM(for: zone), range.lowerBound)
                : model.lowerBPM(for: zone)
            let ceiling = next.map { model.lowerBPM(for: $0) } ?? max(model.maxHR, range.upperBound)
            let lower = max(floor, range.lowerBound)
            let upper = min(ceiling, range.upperBound)
            guard upper > lower else { return nil }
            return ZoneBand(zone: zone, lowerBPM: lower, upperBPM: upper)
        }
    }

    // MARK: - Decimation

    /// Largest-Triangle-Three-Buckets. Chosen over plain striding because it keeps the extremes of
    /// each bucket — and the peaks are the entire reason to look at a heart-rate trace. The first and
    /// last points are always kept, so the line still spans the full session.
    static func decimated(_ points: [Point], to threshold: Int) -> [Point] {
        guard threshold >= 3, points.count > threshold else { return points }

        let bucketSize = Double(points.count - 2) / Double(threshold - 2)
        var result: [Point] = [points[0]]
        var anchorIndex = 0

        for bucket in 0..<(threshold - 2) {
            // Mean of the *next* bucket is the triangle's third vertex.
            let nextStart = min(Int((Double(bucket + 1) * bucketSize).rounded(.down)) + 1, points.count - 1)
            let nextEnd = min(Int((Double(bucket + 2) * bucketSize).rounded(.down)) + 1, points.count - 1)
            let nextRange = nextStart..<max(nextEnd, nextStart + 1)
            var averageElapsed = 0.0
            var averageBPM = 0.0
            for index in nextRange {
                averageElapsed += points[index].elapsed
                averageBPM += Double(points[index].bpm)
            }
            let nextCount = Double(nextRange.count)
            averageElapsed /= nextCount
            averageBPM /= nextCount

            let start = min(Int((Double(bucket) * bucketSize).rounded(.down)) + 1, points.count - 1)
            let end = min(Int((Double(bucket + 1) * bucketSize).rounded(.down)) + 1, points.count - 1)
            let anchor = points[anchorIndex]
            var best = start
            var bestArea = -1.0
            for index in start..<max(end, start + 1) {
                let candidate = points[index]
                let area = abs(
                    (anchor.elapsed - averageElapsed) * (Double(candidate.bpm) - Double(anchor.bpm))
                        - (anchor.elapsed - candidate.elapsed) * (averageBPM - Double(anchor.bpm))
                ) / 2
                if area > bestArea {
                    bestArea = area
                    best = index
                }
            }
            result.append(points[best])
            anchorIndex = best
        }

        result.append(points[points.count - 1])
        return result
    }
}
