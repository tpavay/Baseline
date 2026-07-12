import SwiftUI

/// The **Plan tab** — Baseline's week-level training surface (`docs/implementation/plan-tab.md`). Slice 1:
/// program filter, week navigation, an explicit-state day strip, contribution-based weekly aggregates, a
/// chronological timeline of adaptive workout cards, and the start/resume/complete lifecycle. Structural
/// editing (drag-drop, versioning) and full WorkoutView execution-reuse arrive in later slices.
struct PlanView: View {
    @Environment(PlanStore.self) private var plan
    @State private var selectedDay: Date = Calendar.planWeek.startOfDay(for: Date())
    @State private var detail: ScheduledWorkout?
    @State private var confirmComplete: ScheduledWorkout?
    @State private var openWorkMessage = ""
    @State private var showChat = false

    private let cal = Calendar.planWeek
    private var today: Date { cal.startOfDay(for: Date()) }

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        weekNav
                        SevenDayStrip(week: plan.week, today: today, selected: selectedDay) { selectedDay = $0 }
                            .padding(.top, 14)
                        aggregates.padding(.top, 22)
                        timeline.padding(.top, 22)
                        Color.clear.frame(height: 90)
                    }
                    .padding(.horizontal, 16)
                }
                chatBar
            }
            .navigationTitle("").toolbar { toolbar }
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
        }
        .sheet(item: $detail) { ScheduledWorkoutDetailView(scheduled: $0) }
        .sheet(isPresented: $showChat) { AskBaselineSheet() }
        .alert("Finish workout?", isPresented: Binding(get: { confirmComplete != nil }, set: { if !$0 { confirmComplete = nil } })) {
            Button("Finish anyway", role: .destructive) { if let sw = confirmComplete { _ = plan.complete(sw.id, acknowledgingOpenWork: true) }; confirmComplete = nil }
            Button("Keep logging", role: .cancel) { confirmComplete = nil }
        } message: { Text(openWorkMessage) }
    }

    // MARK: Toolbar (program filter + today)

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("All Training") { plan.setFilter(.allTraining) }
                ForEach(plan.programs().filter { $0.isActive && !$0.isArchived }) { p in
                    Button(p.name) { plan.setFilter(.program(p.id)) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(filterLabel).font(.system(size: 20, weight: .bold)).italic().foregroundStyle(BaselineColor.textHi)
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(BaselineColor.textMid)
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { selectedDay = today; plan.showWeek(of: today) } label: {
                Image(systemName: "calendar").foregroundStyle(BaselineColor.textHi)
            }
        }
    }

    private var filterLabel: String {
        switch plan.filter {
        case .allTraining: return "ALL TRAINING"
        case .program(let id): return (plan.programs().first { $0.id == id }?.name ?? "PROGRAM").uppercased()
        case .collection(let c): return c.rawValue.uppercased()
        }
    }

    // MARK: Week nav

    private var weekNav: some View {
        HStack {
            Button { plan.prevWeek() } label: { Image(systemName: "chevron.left").foregroundStyle(BaselineColor.textFaint) }
            Spacer()
            Text(weekRangeLabel).font(.system(size: 15, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(BaselineColor.textHi)
            Spacer()
            Button { plan.nextWeek() } label: { Image(systemName: "chevron.right").foregroundStyle(BaselineColor.textFaint) }
        }.padding(.top, 8)
    }

    private var weekRangeLabel: String {
        let start = plan.week.startDate
        let end = cal.date(byAdding: .day, value: 6, to: start)!
        return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.day()))".uppercased()
    }

    // MARK: Aggregates

    private var aggregates: some View {
        let sessions = plan.week.days.flatMap(\.sessions)
        let aggs = AggregateProvider.aggregates(for: sessions)
        let completed = sessions.filter { plan.completed(for: $0.id) != nil }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("THIS WEEK").font(.system(size: 13, weight: .bold)).tracking(1.5).foregroundStyle(BaselineColor.textFaint)
                Spacer()
                Text("\(completed) / \(sessions.count) SESSIONS").font(.system(size: 13, weight: .bold)).tracking(0.5).foregroundStyle(BaselineColor.zoneGreen)
            }
            if aggs.filter({ $0.key != .sessions }).isEmpty {
                Text("No planned volume yet.").font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(aggs.filter { $0.key != .sessions }) { AggregateCard(aggregate: $0) }
                    }
                }
            }
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        let daysWithContent = plan.week.days.filter { !$0.sessions.isEmpty || cal.isDate($0.date, inSameDayAs: today) }
        return VStack(alignment: .leading, spacing: 0) {
            Text("TIMELINE").font(.system(size: 13, weight: .bold)).tracking(1.5).foregroundStyle(BaselineColor.textFaint)
                .padding(.bottom, 14)
            if daysWithContent.allSatisfy(\.sessions.isEmpty) {
                Text("Nothing scheduled this week — ask Baseline or add a workout.")
                    .font(.system(size: 14)).foregroundStyle(BaselineColor.textFaint).padding(.vertical, 20)
            }
            ForEach(daysWithContent) { day in
                dayHeader(day)
                if day.sessions.isEmpty {
                    Text("Rest").font(.system(size: 14, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
                        .padding(.leading, 22).padding(.bottom, 20)
                } else {
                    ForEach(day.sessions) { sw in
                        ScheduledWorkoutCard(
                            scheduled: sw,
                            status: plan.status(for: sw, today: Date()),
                            onPrimary: { primaryAction(sw) },
                            onOpen: { detail = sw },
                            onComplete: { attemptComplete(sw) },
                            onSkip: { plan.discard(sw.id) })
                        .padding(.leading, 22).padding(.bottom, 14)
                    }
                }
            }
        }
    }

    private func dayHeader(_ day: TrainingDay) -> some View {
        let isToday = cal.isDate(day.date, inSameDayAs: today)
        return HStack(spacing: 8) {
            Circle().fill(isToday ? BaselineColor.zoneAmber : BaselineColor.textFaint).frame(width: 7, height: 7)
            Text(day.date.formatted(.dateTime.weekday(.wide)).uppercased())
                .font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(1)
                .foregroundStyle(isToday ? BaselineColor.accent : BaselineColor.textMid)
            if isToday { Text("· TODAY").font(.system(size: 12, weight: .bold)).foregroundStyle(BaselineColor.accent) }
            else { Text("// \(day.date.formatted(.dateTime.month(.abbreviated).day()))".uppercased()).font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint) }
            Spacer()
        }.padding(.bottom, 12)
    }

    // MARK: Actions

    private func primaryAction(_ sw: ScheduledWorkout) {
        switch plan.status(for: sw, today: Date()) {
        case .today, .missed, .planned, .modifiedIntent:
            _ = plan.start(sw.id); detail = sw
        case .inProgress, .paused:
            _ = plan.resume(sw.id); detail = sw
        case .completed, .skipped:
            detail = sw
        }
    }

    private func attemptComplete(_ sw: ScheduledWorkout) {
        if case .unloggedWork(let sets, let exercises) = plan.complete(sw.id, acknowledgingOpenWork: false) {
            openWorkMessage = "You still have \(sets) unlogged set\(sets == 1 ? "" : "s") across \(exercises) exercise\(exercises == 1 ? "" : "s")."
            confirmComplete = sw
        }
    }

    private var chatBar: some View {
        VStack {
            Spacer()
            Button { showChat = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkle").font(.system(size: 15)).foregroundStyle(BaselineColor.accent)
                    Text("Ask about your week…").font(.system(size: 15)).foregroundStyle(BaselineColor.textMid)
                    Spacer()
                    Image(systemName: "mic.fill").font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint)
                }
                .padding(.horizontal, 16).frame(height: 50)
                .background(Capsule().fill(BaselineColor.surface).overlay(Capsule().strokeBorder(BaselineColor.line, lineWidth: 1)))
            }
            .buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 8)
        }
    }
}

// MARK: - Seven-day strip (explicit states, not recovery-color dots)

struct SevenDayStrip: View {
    let week: TrainingWeek
    let today: Date
    let selected: Date
    let onSelect: (Date) -> Void
    private let cal = Calendar.planWeek

    var body: some View {
        HStack(spacing: 0) {
            ForEach(week.days) { day in
                let isToday = cal.isDate(day.date, inSameDayAs: today)
                let isSel = cal.isDate(day.date, inSameDayAs: selected)
                Button { onSelect(day.date) } label: {
                    VStack(spacing: 6) {
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(isToday ? BaselineColor.accent : BaselineColor.textFaint)
                        marker(for: day, isToday: isToday)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(isSel ? RoundedRectangle(cornerRadius: 10).fill(BaselineColor.surface) : nil)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 14).strokeBorder(BaselineColor.line, lineWidth: 1))
    }

    @ViewBuilder private func marker(for day: TrainingDay, isToday: Bool) -> some View {
        let count = day.sessions.count
        if count == 0 {
            Circle().fill(.clear).frame(width: 16, height: 16)                       // rest — no marker
        } else if count > 1 {
            Text("\(count)").font(.system(size: 11, weight: .bold)).foregroundStyle(BaselineColor.textHi)
                .frame(width: 16, height: 16).background(Circle().fill(BaselineColor.amethyst))
        } else if isToday {
            Circle().strokeBorder(BaselineColor.accent, lineWidth: 2).frame(width: 14, height: 14)  // today ring
        } else {
            Circle().fill(BaselineColor.textFaint).frame(width: 7, height: 7)         // scheduled
        }
    }
}

// MARK: - Aggregate card

struct AggregateCard: View {
    let aggregate: Aggregate
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(PlanFormat.aggregateTitle(aggregate.key)).font(.system(size: 12, weight: .semibold)).tracking(0.5).foregroundStyle(BaselineColor.textFaint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(PlanFormat.aggregateValue(aggregate)).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(BaselineColor.textHi)
                if let u = PlanFormat.aggregateUnit(aggregate.key) { Text(u).font(.system(size: 12, weight: .bold)).foregroundStyle(BaselineColor.textFaint) }
            }
        }
        .padding(16).frame(minWidth: 120, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).strokeBorder(BaselineColor.line, lineWidth: 1))
    }
}

// MARK: - Formatting

enum PlanFormat {
    static func aggregateTitle(_ k: AggregateKey) -> String {
        switch k { case .sessions: "SESSIONS"; case .duration: "DURATION"; case .distance: "RUNNING"; case .strengthSets: "STRENGTH"; case .calories: "CALORIES" }
    }
    static func aggregateUnit(_ k: AggregateKey) -> String? {
        switch k { case .distance: "MI"; case .strengthSets: "SETS"; case .calories: "CAL"; default: nil }
    }
    static func aggregateValue(_ a: Aggregate) -> String {
        switch a.key {
        case .duration: return durationShort(Int(a.total))
        case .distance: return String(format: "%.1f", a.total / 1609.344)   // meters → miles
        case .strengthSets, .sessions, .calories: return String(Int(a.total))
        }
    }
    static func durationShort(_ seconds: Int) -> String {
        let m = seconds / 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}
