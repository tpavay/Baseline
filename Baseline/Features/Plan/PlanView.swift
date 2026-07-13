import SwiftUI

/// The **Plan tab** — Baseline's week-level training surface (`docs/implementation/plan-tab.md`). Slice 1:
/// program filter, week navigation, an explicit-state day strip, contribution-based weekly aggregates, a
/// chronological timeline of adaptive workout cards, and the start/resume/complete lifecycle. Structural
/// editing (drag-drop, versioning) and full WorkoutView execution-reuse arrive in later slices.
struct PlanView: View {
    @Environment(PlanStore.self) private var plan
    @State private var selectedDay: Date = Calendar.planWeek.startOfDay(for: Date())
    @State private var execContext: ExecContext?
    @State private var confirmComplete: ScheduledWorkout?
    @State private var openWorkMessage = ""
    @State private var showChat = false
    @State private var dropTargetDate: Date?
    @State private var pendingDrop: PendingDrop?
    @State private var deleteTarget: DeleteTarget?
    @State private var undoMessage: String?

    /// A live execution buffer — a scratch `WorkoutStore` driving the reused `WorkoutView`, wired to
    /// write through to the Plan repository. Identifiable so it drives a `.sheet(item:)`.
    struct ExecContext: Identifiable {
        let id: UUID
        let store: WorkoutStore
        let original: Workout
    }
    /// A drag dropped onto a day that already has session(s) — resolved via an action sheet.
    struct PendingDrop: Identifiable { let id = UUID(); let dragged: UUID; let day: Date; let existing: [ScheduledWorkout] }
    struct DeleteTarget: Identifiable { let id = UUID(); let sw: ScheduledWorkout; let proposalID: UUID }

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
                if let msg = undoMessage { undoBar(msg) }
            }
            .navigationTitle("").toolbar { toolbar }
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
        }
        .sheet(item: $execContext, onDismiss: flushExecution) { ctx in
            WorkoutView().environment(ctx.store)
        }
        .sheet(isPresented: $showChat) { AskBaselineSheet() }
        .alert("Finish workout?", isPresented: Binding(get: { confirmComplete != nil }, set: { if !$0 { confirmComplete = nil } })) {
            Button("Finish anyway", role: .destructive) { if let sw = confirmComplete { _ = plan.complete(sw.id, acknowledgingOpenWork: true) }; confirmComplete = nil }
            Button("Keep logging", role: .cancel) { confirmComplete = nil }
        } message: { Text(openWorkMessage) }
        .alert("Delete workout?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), presenting: deleteTarget) { t in
            Button("Delete", role: .destructive) { apply(plan.delete(t.sw.id, proposalID: t.proposalID), "Deleted"); deleteTarget = nil }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { t in Text("This removes \(t.sw.workout.title) from the plan. You can undo it.") }
        .confirmationDialog("Drop onto this day", isPresented: Binding(get: { pendingDrop != nil }, set: { if !$0 { pendingDrop = nil } }), presenting: pendingDrop) { pd in
            Button("Move here") { apply(plan.move(pd.dragged, toDate: pd.day), "Moved"); pendingDrop = nil }
            if pd.existing.count == 1 {
                Button("Swap with \(pd.existing[0].workout.title)") { apply(plan.swap(pd.dragged, pd.existing[0].id), "Swapped"); pendingDrop = nil }
            }
            Button("Cancel", role: .cancel) { pendingDrop = nil }
        }
        .task(id: undoMessage) {
            guard undoMessage != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            undoMessage = nil
        }
    }

    private func undoBar(_ message: String) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Text(message).font(.system(size: 14, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                Spacer()
                Button("Undo") { _ = plan.undo(); undoMessage = nil }
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(BaselineColor.accent)
            }
            .padding(.horizontal, 18).frame(height: 46)
            .background(Capsule().fill(BaselineColor.amethyst).overlay(Capsule().strokeBorder(BaselineColor.accent.opacity(0.4), lineWidth: 1)))
            .padding(.horizontal, 16).padding(.bottom, 66)   // above the chat bar
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
                VStack(alignment: .leading, spacing: 0) {
                    dayHeader(day)
                    if day.sessions.isEmpty {
                        Text("Rest").font(.system(size: 14, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 22).padding(.bottom, 20)
                    } else {
                        ForEach(day.sessions) { sw in
                            ScheduledWorkoutCard(
                                scheduled: sw,
                                status: plan.status(for: sw, today: Date()),
                                weekDays: plan.week.days.map(\.date),
                                onAction: { handle($0, sw) })
                            .padding(.leading, 22).padding(.bottom, 14)
                            .draggable(sw.id.uuidString)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    guard let first = items.first, let dragged = UUID(uuidString: first) else { return false }
                    return drop(dragged, on: day.date)
                } isTargeted: { dropTargetDate = $0 ? day.date : (cal.isDate(dropTargetDate ?? .distantPast, inSameDayAs: day.date) ? nil : dropTargetDate) }
                .background(cal.isDate(dropTargetDate ?? .distantPast, inSameDayAs: day.date)
                    ? RoundedRectangle(cornerRadius: 12).fill(BaselineColor.accent.opacity(0.08)) : nil)
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

    private func handle(_ action: PlanCardAction, _ sw: ScheduledWorkout) {
        switch action {
        case .primary: primaryAction(sw)
        case .open: openExecution(sw)
        case .complete: attemptComplete(sw)
        case .duplicate: apply(plan.duplicate(sw.id, toDate: nil), "Duplicated")
        case .skip: apply(plan.setSkipped(sw.id, true), "Skipped")
        case .unskip: apply(plan.setSkipped(sw.id, false), "Unskipped")
        case .move(let d): apply(plan.move(sw.id, toDate: d), "Moved")
        case .delete:
            if case .confirmationRequired(_, _, let pid) = plan.delete(sw.id) { deleteTarget = DeleteTarget(sw: sw, proposalID: pid) }
        }
    }

    /// A drag dropped on `day`. Empty day → move directly; occupied → offer Move/Swap.
    private func drop(_ dragged: UUID, on day: Date) -> Bool {
        dropTargetDate = nil
        guard let sw = plan.scheduledWorkout(dragged), !cal.isDate(sw.date, inSameDayAs: day) else { return false }
        let existing = (plan.week.days.first { cal.isDate($0.date, inSameDayAs: day) }?.sessions ?? []).filter { $0.id != dragged }
        if existing.isEmpty { apply(plan.move(dragged, toDate: day), "Moved") }
        else { pendingDrop = PendingDrop(dragged: dragged, day: day, existing: existing) }
        return true
    }

    /// Surface an Undo affordance after an applied mutation.
    private func apply(_ result: MutationResult, _ verb: String) {
        if result.isApplied { withAnimation { undoMessage = verb } }
    }

    private func primaryAction(_ sw: ScheduledWorkout) {
        switch plan.status(for: sw, today: Date()) {
        case .today, .missed, .planned, .modifiedIntent:
            _ = plan.start(sw.id)
        case .inProgress, .paused:
            _ = plan.resume(sw.id)
        case .completed, .skipped:
            break
        }
        openExecution(plan.scheduledWorkout(sw.id) ?? sw)
    }

    private func attemptComplete(_ sw: ScheduledWorkout) {
        if case .unloggedWork(let sets, let exercises) = plan.complete(sw.id, acknowledgingOpenWork: false) {
            openWorkMessage = "You still have \(sets) unlogged set\(sets == 1 ? "" : "s") across \(exercises) exercise\(exercises == 1 ? "" : "s")."
            confirmComplete = sw
        }
    }

    // MARK: Execution bridge — reuse WorkoutView, write through to the repository

    private func openExecution(_ sw: ScheduledWorkout) {
        let planStore = plan                                   // concrete ref captured once (safe in closures)
        let store = WorkoutStore(defaults: UserDefaults(suiteName: "plan.exec.buffer") ?? .standard)
        store.loadExecution(workout: sw.workout, log: planStore.session(for: sw.id)?.log)
        let id = sw.id
        store.onLogChange = { log in planStore.updateSessionLog(id) { $0 = log } }
        store.onStart = { [weak store] in
            _ = planStore.start(id)
            if let s = planStore.session(for: id), let w = planStore.scheduledWorkout(id)?.workout {
                store?.loadExecution(workout: w, log: s.log)
            }
        }
        store.onComplete = { _ = planStore.complete(id, acknowledgingOpenWork: true) }
        store.onDiscard = { planStore.discard(id) }
        execContext = ExecContext(id: id, store: store, original: sw.workout)
    }

    /// On dismiss, flush any *structural* plan edits as one immutable revision (logging already
    /// write-through). Only when the workout actually changed — no spurious revisions.
    private func flushExecution() {
        guard let ctx = execContext else { return }
        if let edited = ctx.store.current, edited != ctx.original {
            plan.updateWorkout(ctx.id) { $0 = edited }
        }
        plan.reload()
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
