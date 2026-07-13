import SwiftUI

/// Read-only **exercise history** — every past completed session for one exercise, newest-first, with
/// metric-aware bests. Matched by **stable definition identity** (never display name), so an
/// AI-added one-off with no identity shows guidance instead of silently merging into another
/// exercise's history. Values compare canonically and render in the athlete's preferred units.
struct ExerciseHistoryView: View {
    let exercise: PlannedExercise
    @Environment(PlanStore.self) private var plan
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var performances: [ExercisePerformance] {
        guard let id = exercise.definitionId else { return [] }
        return plan.history(exerciseDefinitionID: id)   // newest-first, global across programs
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                if exercise.definitionId == nil { unidentified }
                else if performances.isEmpty { empty }
                else { ScrollView { content } }
            }
            .navigationTitle(exercise.exerciseName).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.foregroundStyle(BaselineColor.accent) } }
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            bests
            ForEach(Array(performances.enumerated()), id: \.element.id) { i, p in
                performanceCard(p, mostRecent: i == 0)
            }
        }.padding(20)
    }

    // MARK: Bests (metric-aware)

    private var bests: some View {
        let metrics = metricsInHistory
        return VStack(alignment: .leading, spacing: 10) {
            Text("BESTS").font(.system(size: 12, weight: .bold)).tracking(1).foregroundStyle(BaselineColor.textFaint)
            HStack(alignment: .top, spacing: 22) {
                ForEach(metrics, id: \.self) { m in
                    if let best = bestValue(m) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.label.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(BaselineColor.textFaint)
                            Text(format(best, m)).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(BaselineColor.textHi)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(BaselineColor.surface))
    }

    private func performanceCard(_ p: ExercisePerformance, mostRecent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(p.date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 15, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                if mostRecent { Text("MOST RECENT").font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(BaselineColor.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(BaselineColor.accent.opacity(0.15))) }
                Spacer()
                Text([p.workoutTitle, plan.programName(p.programID)].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint).lineLimit(1)
            }
            ForEach(Array(p.sets.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 10) {
                    Text("\(i + 1)").font(.system(size: 13, weight: .bold)).foregroundStyle(BaselineColor.textFaint).frame(width: 18)
                    Text(formatSet(s)).font(.system(size: 14)).foregroundStyle(BaselineColor.textMid)
                    Spacer()
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).strokeBorder(BaselineColor.line, lineWidth: 1))
    }

    // MARK: Empty states

    private var empty: some View {
        centered("clock.arrow.circlepath", "No history yet",
                 "Complete a session with \(exercise.exerciseName) and it'll show up here.")
    }
    private var unidentified: some View {
        centered("questionmark.circle", "Not tracked yet",
                 "This exercise isn't in your catalog, so its history isn't tracked. Save it as a custom exercise to start building history.")
    }
    private func centered(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(BaselineColor.textFaint)
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(BaselineColor.textMid).multilineTextAlignment(.center)
        }.padding(40)
    }

    // MARK: Metric math (canonical compare, preferred-unit display)

    private var metricsInHistory: [MetricType] {
        var seen = Set<MetricType>()
        for p in performances { for s in p.sets { for m in s.present { seen.insert(m) } } }
        return MetricType.allCases.filter { seen.contains($0) }
    }
    /// Best per metric on canonical values: pace = fastest (lowest); everything else = highest.
    private func bestValue(_ m: MetricType) -> Double? {
        let values = performances.flatMap { $0.sets.compactMap { $0[m] } }
        guard !values.isEmpty else { return nil }
        return m == .pace ? values.min() : values.max()
    }
    private func format(_ canonical: Double, _ m: MetricType) -> String {
        if m == .duration { return mmss(Int(canonical)) }
        let unit = store.displayUnit(m, for: exercise)
        let d = MetricConvert.fromCanonical(canonical, m, to: unit)
        let num = (m.isInteger || d == d.rounded()) ? String(Int(d.rounded())) : String(format: "%.1f", d)
        return unit.short.isEmpty ? num : "\(num) \(unit.short)"
    }
    private func formatSet(_ values: MetricValues) -> String {
        let parts = values.present.map { format(values[$0]!, $0) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
    private func mmss(_ s: Int) -> String { s >= 60 ? "\(s / 60):\(String(format: "%02d", s % 60))" : "\(s)s" }
}
