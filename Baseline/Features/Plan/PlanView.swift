import SwiftUI

/// The **Plan tab** - Baseline's calendar-level training surface (`docs/implementation/plan-tab.md`).
/// A continuous day-per-row calendar (about two months back, four ahead) with month headers, the
/// program/collection filter, weekly aggregates for the visible week, drag-drop rescheduling, and the
/// start/resume/complete lifecycle reached through each session's row and detail screen.
struct PlanView: View {
    @Environment(PlanStore.self) private var plan
    @Environment(AppSettings.self) private var settings
    @State private var execContext: ExecContext?
    @State private var showChat = false
    @State private var dropTargetDate: Date?
    @State private var pendingDrop: PendingDrop?
    @State private var deleteTarget: DeleteTarget?
    @State private var undoMessage: String?
    @State private var importContext: ImportContext?
    /// A scheduled workout the user chose to remove from inside its editor. The deletion runs on sheet
    /// dismissal (in `flushExecution`) so the alert/undo never races the dismissing execution sheet.
    @State private var queuedDeletionID: UUID?
    /// Unfinished image imports, so a day whose import is still being reviewed shows a resume affordance
    /// instead of silently losing the draft off-screen.
    @State private var pendingImports: [WorkoutImportPendingSummary] = []
    /// The day whose "Add to <day>" sheet is open, if any.
    @State private var addContext: AddContext?
    /// The option chosen inside the add sheet, run on its dismissal so the follow-on presentation (chat,
    /// editor, import) never races the dismissing sheet.
    @State private var pendingAdd: (date: Date, option: AddToDayOption)?
    @State private var visibleDate = Calendar.planWeek.startOfDay(for: Date())
    @State private var scrollPosition: Date?
    @State private var detailWorkout: ScheduledWorkout?
    /// Cached calendar projection (-60…+120 days) and derived per-session statuses. Refreshed on appear
    /// and once per plan mutation (`plan.revision`) - never re-fetched inside `body`, which re-runs on
    /// every scroll tick because `scrollPosition` drives `visibleDate`.
    @State private var calendarDays: [TrainingDay] = []
    @State private var statusByID: [UUID: ScheduleStatus] = [:]

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
    struct ImportContext: Identifiable { let id = UUID(); let date: Date; var source: WorkoutImportImageSource? }
    struct AddContext: Identifiable { let id = UUID(); let date: Date }

    private let cal = Calendar.planWeek
    private var today: Date { cal.startOfDay(for: Date()) }

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()

                calendarList

                if let msg = undoMessage { undoBar(msg) }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { calendarToolbar }
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .sheet(item: $execContext, onDismiss: flushExecution) { ctx in
            WorkoutView(onRequestDelete: { queuedDeletionID = ctx.id }).environment(ctx.store)
        }
        .sheet(isPresented: $showChat) { AskBaselineSheet(surface: .plan) }
        .sheet(item: $addContext, onDismiss: runPendingAdd) { context in
            AddToDaySheet(date: context.date, templates: plan.templates()) { option in
                pendingAdd = (context.date, option)
                addContext = nil
            }
        }
        .fullScreenCover(item: $importContext, onDismiss: { Task { await loadPendingImports() } }) { context in
            WorkoutImportView(suggestedDate: context.date, initialSource: context.source) { scheduled in
                openExecution(scheduled)
            }
        }
        .fullScreenCover(item: $detailWorkout) { scheduled in
            WorkoutDetailView(scheduledWorkoutID: scheduled.id)
        }
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
        .onAppear(perform: refreshCalendar)
        .onChange(of: plan.revision) { refreshCalendar() }
        .task { await loadPendingImports() }
    }

    private var calendarList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(calendarDays.enumerated()), id: \.element.date) { index, day in
                    if index == 0 || cal.component(.month, from: calendarDays[index - 1].date) != cal.component(.month, from: day.date) {
                        calendarMonthHeader(day.date)
                    }
                    calendarDayRow(day)
                        .id(day.date)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, BaselineSpacing.large)
            .padding(.bottom, BaselineSpacing.screenBottom)
        }
        .scrollIndicators(.hidden)
        .scrollPosition(id: $scrollPosition, anchor: .center)
        .safeAreaInset(edge: .top, spacing: 0) { weeklyAggregates }
        .onChange(of: scrollPosition) { _, date in
            if let date { visibleDate = date }
        }
    }

    /// One repository pass per plan mutation: the 181-day projection plus each session's derived
    /// status, both held in `@State` so scrolling and other body re-evaluations stay fetch-free.
    private func refreshCalendar() {
        let start = cal.date(byAdding: .day, value: -60, to: today) ?? today
        let end = cal.date(byAdding: .day, value: 120, to: today) ?? today
        let days = plan.days(from: start, through: end)
        calendarDays = days
        statusByID = plan.statuses(for: days.flatMap(\.sessions), today: Date())
        if scrollPosition == nil { scrollPosition = today }
    }

    @ToolbarContentBuilder
    private var calendarToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("Ask Baseline", systemImage: "sparkles") {
                    showChat = true
                }
                Divider()
                Button("All Training") { plan.setFilter(.allTraining) }
                let programs = plan.programs().filter { $0.isActive && $0.isArchived == false }
                if programs.isEmpty == false {
                    Section("Programs") {
                        ForEach(programs) { program in
                            Button(program.name) { plan.setFilter(.program(program.id)) }
                        }
                    }
                }
                Section("Collections") {
                    Button("Ad Hoc") { plan.setFilter(.collection(.adHoc)) }
                    Button("Completed") { plan.setFilter(.collection(.completed)) }
                    Button("Archived") { plan.setFilter(.collection(.archived)) }
                }
            } label: {
                Text(calendarMenuLabel)
                    .font(.caption.monospaced().weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(plan.filter == .allTraining ? BaselineColor.textFaint : BaselineColor.accent)
            }
            .accessibilityLabel("Calendar options")
        }

        ToolbarItem(placement: .principal) {
            Text(visibleDate.formatted(.dateTime.month(.wide).year()))
                .font(.headline.weight(.semibold))
                .foregroundStyle(BaselineColor.textHi)
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button("Today") {
                visibleDate = today
                scrollPosition = today
                plan.showWeek(of: today)
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(BaselineColor.accent)
        }
    }

    /// The leading chip doubles as filter visibility: the visible date under All Training, the active
    /// program or collection name once a narrower filter is applied.
    private var calendarMenuLabel: String {
        if plan.filter == .allTraining {
            return visibleDate.formatted(.dateTime.weekday(.abbreviated).day()).uppercased()
        }
        return filterLabel
    }

    private var filterLabel: String {
        switch plan.filter {
        case .allTraining: return "ALL TRAINING"
        case .program(let id): return (plan.programs().first { $0.id == id }?.name ?? "PROGRAM").uppercased()
        case .collection(let c): return c.rawValue.uppercased()
        }
    }

    // MARK: Weekly aggregates (visible week, pinned above the calendar)

    private var weeklyAggregates: some View {
        let weekStart = cal.weekStart(for: visibleDate)
        let weekEnd = cal.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let sessions = calendarDays
            .filter { $0.date >= weekStart && $0.date < weekEnd }
            .flatMap(\.sessions)
        let aggs = AggregateProvider.aggregates(for: sessions).filter { $0.key != .sessions }
        return VStack(alignment: .leading, spacing: BaselineSpacing.xxSmall) {
            InstrumentLabel(visibleWeekRangeLabel, tracking: 1)
            if aggs.isEmpty {
                Text("No planned volume yet.").font(.caption).foregroundStyle(BaselineColor.textFaint)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: BaselineSpacing.xSmall) {
                        ForEach(aggs) { AggregateCard(aggregate: $0) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BaselineSpacing.large)
        .padding(.vertical, BaselineSpacing.xSmall)
        .background(BaselineColor.base)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var visibleWeekRangeLabel: String {
        let start = cal.weekStart(for: visibleDate)
        let end = cal.date(byAdding: .day, value: 6, to: start) ?? start
        return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.day()))".uppercased()
    }

    private func calendarMonthHeader(_ date: Date) -> some View {
        InstrumentLabel(date.formatted(.dateTime.month(.wide).year()).uppercased(), tracking: 1.2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BaselineSpacing.xxxSmall)
            .padding(.top, BaselineSpacing.row)
            .padding(.bottom, BaselineSpacing.compact)
            .background(BaselineColor.base)
            .overlay(alignment: .bottom) { Hairline() }
    }

    private func calendarDayRow(_ day: TrainingDay) -> some View {
        let isToday = cal.isDate(day.date, inSameDayAs: today)
        let isFuture = day.date > today
        let isDropTarget = dropTargetDate.map { cal.isDate($0, inSameDayAs: day.date) } ?? false
        let pendingReview = reviewableImport(for: day.date)

        return HStack(alignment: .center, spacing: BaselineSpacing.medium) {
            VStack(spacing: BaselineSpacing.xxxSmall) {
                Text(day.date.formatted(.dateTime.day()))
                    .font(.headline.monospacedDigit().weight(.bold))
                Text(day.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.caption2.monospaced().weight(.semibold))
                    .tracking(0.8)
            }
            .foregroundStyle(isToday ? BaselineColor.accent : BaselineColor.textMid)
            .frame(width: BaselineSize.minimumTapTarget - BaselineSpacing.xxSmall)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))

            VStack(alignment: .leading, spacing: BaselineSpacing.compact) {
                if let pendingReview {
                    calendarImportButton(pendingReview, date: day.date)
                }

                if day.sessions.isEmpty && pendingReview == nil {
                    emptyDayRow(day)
                } else {
                    ForEach(day.sessions) { scheduled in
                        WorkoutSwipeActionRow(
                            actionTitle: "Delete",
                            systemImage: "trash",
                            contentBackground: isToday || isDropTarget ? .clear : BaselineColor.base,
                            action: { handle(.delete, scheduled) }
                        ) {
                            calendarSessionButton(scheduled)
                        }
                        .draggable(scheduled.id.uuidString)
                    }
                }
            }

            if let first = day.sessions.first {
                Image(systemName: isCardio(first) ? "clock.arrow.circlepath" : "diamond.fill")
                    .font(.caption)
                    .foregroundStyle(isCardio(first) ? BaselineColor.zoneBlue : BaselineColor.accent)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, isToday ? BaselineSpacing.compact : BaselineSpacing.xxxSmall)
        .padding(.vertical, BaselineSpacing.medium)
        .frame(maxWidth: .infinity, minHeight: BaselineSize.tabBarHeight, alignment: .leading)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: BaselineRadius.row)
                    .fill(BaselineColor.accent.opacity(0.12))
            } else if isToday {
                RoundedRectangle(cornerRadius: BaselineRadius.row)
                    .fill(
                        LinearGradient(
                            colors: [BaselineColor.amethyst.opacity(0.5), BaselineColor.surface.opacity(0.35)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
        }
        .overlay(alignment: .bottom) {
            Hairline(color: isToday ? BaselineColor.accent.opacity(0.4) : BaselineColor.line.opacity(0.7))
        }
        .opacity(isFuture ? 0.68 : 1)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let first = items.first, let dragged = UUID(uuidString: first) else { return false }
            return drop(dragged, on: day.date)
        } isTargeted: { targeted in
            dropTargetDate = targeted ? day.date : nil
        }
    }

    /// An empty day is a decision waiting to be made. The row leads with an explicit affordance —
    /// "Add workout" (plus glyph, opens the per-day add sheet), or "Rest day" once the athlete has
    /// marked it — and carries a trailing one-tap moon toggle so declaring a rest day never requires
    /// opening the sheet. Un-marking is the same tap, so the toggle is its own undo.
    private func emptyDayRow(_ day: TrainingDay) -> some View {
        let dayLabel = day.date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        return HStack(spacing: BaselineSpacing.xSmall) {
            Button {
                addContext = AddContext(date: day.date)
            } label: {
                HStack(spacing: BaselineSpacing.xxSmall) {
                    if day.isRestDay {
                        Text("Rest day")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(BaselineColor.textMid)
                    } else {
                        Image(systemName: "plus.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(BaselineColor.accent.opacity(0.8))
                        Text("Add workout")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(BaselineColor.textFaint)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: BaselineSize.minimumTapTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(day.isRestDay ? "Rest day" : "Add workout")
            .accessibilityHint("Opens options to add training to \(dayLabel)")

            Button {
                plan.setRestDay(day.date, !day.isRestDay)
            } label: {
                Image(systemName: day.isRestDay ? "moon.zzz.fill" : "moon.zzz")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(day.isRestDay ? BaselineColor.accent : BaselineColor.textFaint)
                    .frame(width: BaselineSize.minimumTapTarget, height: BaselineSize.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(day.isRestDay ? "Remove rest day" : "Mark as rest day")
            .accessibilityHint(day.isRestDay
                ? "Removes the rest-day mark from \(dayLabel)"
                : "Marks \(dayLabel) as a rest day")
        }
    }

    private func calendarSessionButton(_ scheduled: ScheduledWorkout) -> some View {
        let status = statusByID[scheduled.id] ?? .planned
        return Button {
            detailWorkout = scheduled
        } label: {
            VStack(alignment: .leading, spacing: BaselineSpacing.xxxSmall) {
                Text(scheduled.workout.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BaselineColor.textHi)
                    .lineLimit(1)
                HStack(spacing: BaselineSpacing.xxSmall) {
                    if let (label, color) = PlanStatusStyle.chip(status) {
                        Text(label)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(color)
                    }
                    Text(calendarSubtitle(scheduled))
                        .font(.caption)
                        .foregroundStyle(BaselineColor.textMid)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: BaselineSize.minimumTapTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens workout details")
        .contextMenu { sessionMenu(scheduled, status: status) }
        // The context menu is invisible to assistive tech, so its primary start/resume/review action
        // must also be a custom action or the session cannot be started from the calendar at all.
        .accessibilityAction(named: Text(openLabel(status))) { handle(.open, scheduled) }
    }

    /// Plan-level organization for a session, one press away from its row: start/resume, move within
    /// its week, duplicate, skip/unskip, delete. Mirrors what the old timeline card's menu offered.
    @ViewBuilder
    private func sessionMenu(_ scheduled: ScheduledWorkout, status: ScheduleStatus) -> some View {
        Button(openLabel(status), systemImage: "play") { handle(.open, scheduled) }
        Menu("Move to") {
            ForEach(weekDates(around: scheduled.date), id: \.self) { date in
                Button(date.formatted(.dateTime.weekday(.wide))) { handle(.move(date), scheduled) }
                    .disabled(cal.isDate(date, inSameDayAs: scheduled.date))
            }
        }
        Button("Duplicate") { handle(.duplicate, scheduled) }
        if scheduled.skipped {
            Button("Unskip") { handle(.unskip, scheduled) }
        } else {
            Button("Skip") { handle(.skip, scheduled) }
        }
        Button("Delete", role: .destructive) { handle(.delete, scheduled) }
    }

    private func openLabel(_ status: ScheduleStatus) -> String {
        switch status {
        case .inProgress, .paused: "Resume workout"
        case .completed: "View session"
        default: "Start workout"
        }
    }

    private func weekDates(around date: Date) -> [Date] {
        let start = cal.weekStart(for: date)
        return (0 ..< 7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private func calendarImportButton(_ summary: WorkoutImportPendingSummary, date: Date) -> some View {
        Button {
            importContext = ImportContext(date: date)
        } label: {
            VStack(alignment: .leading, spacing: BaselineSpacing.xxxSmall) {
                Text("Import ready to review")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BaselineColor.textHi)
                Text("Tap to review and save")
                    .font(.caption)
                    .foregroundStyle(BaselineColor.textMid)
            }
            .frame(maxWidth: .infinity, minHeight: BaselineSize.minimumTapTarget, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the imported workout to review and save")
    }

    private func calendarSubtitle(_ scheduled: ScheduledWorkout) -> String {
        let descriptors = scheduled.workout.allExercises.prefix(2).map(\.exerciseName)
        let work = descriptors.isEmpty ? (scheduled.workout.goal ?? "Training") : descriptors.joined(separator: " + ")
        let duration = AggregateProvider.aggregates(for: [scheduled]).first { $0.key == .duration }
            .map { MetricFormat.durationLong($0.total) } ?? "Planned"
        return "\(work) · \(duration)"
    }

    private func isCardio(_ scheduled: ScheduledWorkout) -> Bool {
        let exercises = scheduled.workout.allExercises
        return exercises.isEmpty == false && exercises.allSatisfy {
            [.cycling, .running, .erg].contains($0.definition.category)
        }
    }

    /// Refresh the unfinished-import snapshots that drive the per-day resume affordance. Delegates to the
    /// coordinator so "what counts as reviewable" stays defined in exactly one place.
    private func loadPendingImports() async {
        pendingImports = await WorkoutImportCoordinator().pendingImports()
    }

    /// Runs the add-sheet choice after the sheet has finished dismissing, so the follow-on presentation
    /// isn't dropped by SwiftUI for racing the outgoing sheet.
    private func runPendingAdd() {
        guard let pending = pendingAdd else { return }
        pendingAdd = nil
        switch pending.option {
        case .buildWithBaseline: showChat = true
        case .restDay: plan.setRestDay(pending.date, true)
        case .startEmptyWorkout: startEmptyWorkout(on: pending.date)
        case .template(let id): addFromTemplate(id, on: pending.date)
        case .importImage(let source): importContext = ImportContext(date: pending.date, source: source)
        }
    }

    /// A parsed-and-waiting import scheduled for `date`, if any — matched on the draft's target day. Only
    /// reviewable drafts surface on the Plan; an import still processing stays silent until it has content.
    private func reviewableImport(for date: Date) -> WorkoutImportPendingSummary? {
        pendingImports.first { summary in
            guard summary.isReviewable, let scheduled = summary.scheduleDate else { return false }
            return cal.isDate(scheduled, inSameDayAs: date)
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

    /// "Start an empty workout": the athlete wants to train *now*. Schedule a blank workout on the
    /// day and go straight into live logging with the timer running — identical to a template's
    /// "Start Workout" — rather than landing on the prescription view.
    private func startEmptyWorkout(on date: Date) {
        openExecution(plan.newScheduledWorkout(on: date))
        execContext?.store.startWorkout()
    }
    private func addFromTemplate(_ id: UUID, on date: Date) {
        if let sw = plan.instantiateTemplate(id, on: date) { openExecution(sw) }
    }

    // MARK: Actions

    private func handle(_ action: PlanCardAction, _ sw: ScheduledWorkout) {
        switch action {
        case .open: openExecution(sw)
        case .duplicate: apply(plan.duplicate(sw.id, toDate: nil), "Duplicated")
        case .skip: apply(plan.setSkipped(sw.id, true), "Skipped")
        case .unskip: apply(plan.setSkipped(sw.id, false), "Unskipped")
        case .move(let d): apply(plan.move(sw.id, toDate: d), "Moved")
        case .delete:
            if case .confirmationRequired(_, _, let pid) = plan.delete(sw.id) { deleteTarget = DeleteTarget(sw: sw, proposalID: pid) }
        }
    }

    /// A drag dropped on `day`. Empty day → move directly; occupied → offer Move/Swap. The occupancy
    /// check queries the repository for that exact day: the calendar spans months, so the focused-week
    /// projection cannot answer for an arbitrary drop target.
    private func drop(_ dragged: UUID, on day: Date) -> Bool {
        dropTargetDate = nil
        guard let sw = plan.scheduledWorkout(dragged), !cal.isDate(sw.date, inSameDayAs: day) else { return false }
        let existing = (plan.days(from: day, through: day).first?.sessions ?? []).filter { $0.id != dragged }
        if existing.isEmpty { apply(plan.move(dragged, toDate: day), "Moved") }
        else { pendingDrop = PendingDrop(dragged: dragged, day: day, existing: existing) }
        return true
    }

    /// Surface an Undo affordance after an applied mutation.
    private func apply(_ result: MutationResult, _ verb: String) {
        if result.isApplied { withAnimation { undoMessage = verb } }
    }

    // MARK: Execution bridge — reuse WorkoutView, write through to the repository

    private func openExecution(_ sw: ScheduledWorkout) {
        // A scratch store bound to this scheduled workout — logging + lifecycle write through immediately;
        // structural content edits are coalesced and flushed as one revision on dismiss.
        let store = WorkoutStore(units: settings, defaults: UserDefaults(suiteName: "plan.exec.buffer") ?? .standard)
        store.bind(plan.sink(forScheduled: sw.id), coalesceContent: true)
        execContext = ExecContext(id: sw.id, store: store, original: sw.workout)
    }

    /// On dismiss, flush any coalesced structural edits as one immutable revision — only when the
    /// workout actually changed (logging already wrote through live).
    private func flushExecution() {
        if let id = queuedDeletionID {
            queuedDeletionID = nil
            let result = plan.delete(id)
            if case .confirmationRequired(_, _, let pid) = result, let sw = plan.scheduledWorkout(id) {
                deleteTarget = DeleteTarget(sw: sw, proposalID: pid)
            } else {
                apply(result, "Removed")
            }
            return   // the workout is being removed — skip the normal write-through flush
        }
        guard let ctx = execContext else { return }
        if ctx.store.current != ctx.original { ctx.store.flush() }
        plan.reload()
    }
}

// MARK: - Aggregate card

struct AggregateCard: View {
    @Environment(AppSettings.self) private var settings
    let aggregate: Aggregate
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(PlanFormat.aggregateTitle(aggregate.key)).font(.caption.weight(.semibold)).tracking(0.4).foregroundStyle(BaselineColor.textFaint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(PlanFormat.aggregateValue(aggregate, in: settings.unitSystem)).font(.headline).bold().foregroundStyle(BaselineColor.textHi)
                if let u = PlanFormat.aggregateUnit(aggregate.key, in: settings.unitSystem) { Text(u).font(.caption.weight(.bold)).foregroundStyle(BaselineColor.textFaint) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6).frame(minWidth: 88, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(BaselineColor.line, lineWidth: 1))
    }
}

// MARK: - Formatting

enum PlanFormat {
    static func aggregateTitle(_ k: AggregateKey) -> String {
        switch k { case .sessions: "SESSIONS"; case .duration: "DURATION"; case .distance: "RUNNING"; case .strengthSets: "STRENGTH"; case .calories: "CALORIES" }
    }
    /// Distance follows the athlete's unit system like every other display path — it used to be
    /// hard-coded to miles, which read as "MI" to a metric athlete. The weekly card sums a whole
    /// week's work across every exercise, so it resolves with no exercise in hand: endurance, which
    /// is the sense the "RUNNING" tile is counting in.
    static func aggregateUnit(_ k: AggregateKey, in system: UnitSystem) -> String? {
        switch k {
        case .distance: system.displayUnit(metric: .distance, exercise: nil).short.uppercased()
        case .strengthSets: "SETS"
        case .calories: "CAL"
        default: nil
        }
    }
    static func aggregateValue(_ a: Aggregate, in system: UnitSystem) -> String {
        switch a.key {
        case .duration: return durationShort(Int(a.total))
        case .distance:
            return String(format: "%.1f", MetricConvert.fromCanonical(a.total, .distance,
                                                                      to: system.displayUnit(metric: .distance, exercise: nil)))
        case .strengthSets, .sessions, .calories: return String(Int(a.total))
        }
    }
    static func durationShort(_ seconds: Int) -> String { MetricFormat.durationLong(Double(seconds)) }
}
