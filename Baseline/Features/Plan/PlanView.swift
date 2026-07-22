import SwiftUI

/// The **Plan tab** — Baseline's week-level training surface (`docs/implementation/plan-tab.md`). Slice 1:
/// program filter, week navigation, an explicit-state day strip, contribution-based weekly aggregates, a
/// chronological timeline of adaptive workout cards, and the start/resume/complete lifecycle. Structural
/// editing (drag-drop, versioning) and full WorkoutView execution-reuse arrive in later slices.
struct PlanView: View {
    @Environment(PlanStore.self) private var plan
    @Environment(AppSettings.self) private var settings
    @State private var selectedDay: Date = Calendar.planWeek.startOfDay(for: Date())
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
    struct ImportContext: Identifiable { let id = UUID(); let date: Date }
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
            AddToDaySheet(title: addSheetTitle(for: context.date), templates: plan.templates()) { option in
                pendingAdd = (context.date, option)
                addContext = nil
            }
        }
        .fullScreenCover(item: $importContext, onDismiss: { Task { await loadPendingImports() } }) { context in
            WorkoutImportView(suggestedDate: context.date) { scheduled in openExecution(scheduled) }
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
        .onAppear {
            if scrollPosition == nil {
                scrollPosition = today
            }
        }
        .onChange(of: scrollPosition) { _, date in
            if let date { visibleDate = date }
        }
    }

    private var calendarDays: [TrainingDay] {
        let start = cal.date(byAdding: .day, value: -60, to: today) ?? today
        let end = cal.date(byAdding: .day, value: 120, to: today) ?? today
        return plan.days(from: start, through: end)
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
            } label: {
                Text(visibleDate.formatted(.dateTime.weekday(.abbreviated).day()).uppercased())
                    .font(.caption.monospaced().weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(BaselineColor.textFaint)
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
                    Button {
                        addContext = AddContext(date: day.date)
                    } label: {
                        Text("Rest day")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(BaselineColor.textFaint)
                            .frame(maxWidth: .infinity, minHeight: BaselineSize.minimumTapTarget, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens options to add a workout")
                } else {
                    ForEach(day.sessions) { scheduled in
                        WorkoutSwipeActionRow(
                            actionTitle: "Delete",
                            systemImage: "trash",
                            contentBackground: isToday ? .clear : BaselineColor.base,
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
            if isToday {
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

    private func calendarSessionButton(_ scheduled: ScheduledWorkout) -> some View {
        Button {
            detailWorkout = scheduled
        } label: {
            VStack(alignment: .leading, spacing: BaselineSpacing.xxxSmall) {
                Text(scheduled.workout.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BaselineColor.textHi)
                    .lineLimit(1)
                Text(calendarSubtitle(scheduled))
                    .font(.caption)
                    .foregroundStyle(BaselineColor.textMid)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: BaselineSize.minimumTapTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens workout details")
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

    /// Human-friendly sheet title for the day being added to — "Today"/"Tomorrow" when close, else the weekday.
    private func addSheetTitle(for date: Date) -> String {
        if cal.isDateInToday(date) { return "Add to Today" }
        if cal.isDateInTomorrow(date) { return "Add to Tomorrow" }
        return "Add to \(date.formatted(.dateTime.weekday(.wide)))"
    }

    /// Runs the add-sheet choice after the sheet has finished dismissing, so the follow-on presentation
    /// isn't dropped by SwiftUI for racing the outgoing sheet.
    private func runPendingAdd() {
        guard let pending = pendingAdd else { return }
        pendingAdd = nil
        switch pending.option {
        case .buildWithBaseline: showChat = true
        case .emptySession: addWorkout(on: pending.date)
        case .template(let id): addFromTemplate(id, on: pending.date)
        case .importImage: importContext = ImportContext(date: pending.date)
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

    // MARK: Toolbar (program filter + today)

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("All Training") { plan.setFilter(.allTraining) }
                let programs = plan.programs().filter { $0.isActive && !$0.isArchived }
                if !programs.isEmpty {
                    Section("Programs") { ForEach(programs) { p in Button(p.name) { plan.setFilter(.program(p.id)) } } }
                }
                Section("Collections") {
                    Button("Ad Hoc") { plan.setFilter(.collection(.adHoc)) }
                    Button("Completed") { plan.setFilter(.collection(.completed)) }
                    Button("Archived") { plan.setFilter(.collection(.archived)) }
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
            Button { plan.prevWeek() } label: {
                Image(systemName: "chevron.left").foregroundStyle(BaselineColor.textFaint).frame(width: 44, height: 44)
            }
            Spacer()
            Text(weekRangeLabel).font(.subheadline.weight(.semibold).monospaced()).tracking(0.8).foregroundStyle(BaselineColor.textHi)
            Spacer()
            Button { plan.nextWeek() } label: {
                Image(systemName: "chevron.right").foregroundStyle(BaselineColor.textFaint).frame(width: 44, height: 44)
            }
        }
    }

    private var weekRangeLabel: String {
        let start = plan.week.startDate
        let end = cal.date(byAdding: .day, value: 6, to: start)!
        return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.day()))".uppercased()
    }

    // MARK: Aggregates

    private var aggregates: some View {
        let aggs = AggregateProvider.aggregates(for: plan.week.days.flatMap(\.sessions))
        return VStack(alignment: .leading, spacing: 6) {
            Text("THIS WEEK").font(.caption.weight(.bold)).tracking(1).foregroundStyle(BaselineColor.textFaint)
            if aggs.filter({ $0.key != .sessions }).isEmpty {
                Text("No planned volume yet.").font(.caption).foregroundStyle(BaselineColor.textFaint)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(aggs.filter { $0.key != .sessions }) { AggregateCard(aggregate: $0) }
                    }
                }
            }
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TIMELINE").font(.caption.weight(.bold)).tracking(1).foregroundStyle(BaselineColor.textFaint)
                .padding(.bottom, 10)
            ForEach(plan.week.days) { day in   // every day of the week — empty days are add points + drop targets
                HStack(alignment: .top, spacing: 10) {
                    dayDate(day.date)
                    VStack(alignment: .leading, spacing: 6) {
                        let pendingReview = reviewableImport(for: day.date)
                        if let pendingReview {
                            importIndicatorRow(pendingReview, on: day.date)
                        }
                        if !day.sessions.isEmpty {
                            ForEach(day.sessions) { sw in
                                WorkoutSwipeActionRow(actionTitle: "Delete", systemImage: "trash", action: { handle(.delete, sw) }) {
                                    ScheduledWorkoutCard(
                                        scheduled: sw,
                                        status: plan.status(for: sw, today: Date()),
                                        weekDays: plan.week.days.map(\.date),
                                        onAction: { handle($0, sw) })
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .draggable(sw.id.uuidString)
                            }
                        } else if pendingReview == nil {
                            addWorkoutRow(on: day.date)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
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

    /// Empty-day affordance: a lightweight "+ Add workout" row (rest until you add). The enclosing day is
    /// still a drop target, so a dragged workout can also land here. Tapping opens the per-day "Add to <day>"
    /// sheet rather than an inline menu.
    private func addWorkoutRow(on date: Date) -> some View {
        Button { addContext = AddContext(date: date) } label: { addWorkoutLabel }.buttonStyle(.plain)
    }

    /// Surfaces a parsed-and-waiting image import on the day it targets, so a draft the user closed
    /// mid-review is visible and resumable from the Plan rather than lost off-screen. Tapping reopens
    /// import for the day, which resumes the same-day draft straight into review.
    private func importIndicatorRow(_ summary: WorkoutImportPendingSummary, on date: Date) -> some View {
        Button { importContext = ImportContext(date: date) } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BaselineColor.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Import ready to review")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BaselineColor.textHi)
                    Text("Tap to review and save")
                        .font(.caption)
                        .foregroundStyle(BaselineColor.textFaint)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(BaselineColor.textFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(BaselineColor.accent.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BaselineColor.accent.opacity(0.35), lineWidth: 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the imported workout to review and save")
    }

    private var addWorkoutLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.subheadline.weight(.semibold))
            Text("Add workout").font(.subheadline.weight(.medium))
            Spacer()
        }
        .foregroundStyle(BaselineColor.textFaint)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(BaselineColor.surface.opacity(0.45)))
        .contentShape(Rectangle())
    }

    private func addWorkout(on date: Date) {
        openExecution(plan.newScheduledWorkout(on: date))   // blank workout for that date, then open the editor
    }
    private func addFromTemplate(_ id: UUID, on date: Date) {
        if let sw = plan.instantiateTemplate(id, on: date) { openExecution(sw) }
    }

    private func dayDate(_ date: Date) -> some View {
        let isToday = cal.isDate(date, inSameDayAs: today)
        let color = isToday ? BaselineColor.accent : BaselineColor.textFaint
        return VStack(spacing: 0) {
            Text(PlanFormat.weekdayAbbreviation(date, calendar: cal))
                .font(.caption.weight(.bold))
            Text(date.formatted(.dateTime.day()))
                .font(.headline.monospacedDigit())
            Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .frame(width: 52)
        .frame(minHeight: 64, alignment: .top)
        .padding(.top, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).month(.wide).day()) + (isToday ? ", today" : ""))
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
                    VStack(spacing: 4) {
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption.weight(.bold)).foregroundStyle(isToday ? BaselineColor.accent : BaselineColor.textFaint)
                        marker(for: day, isToday: isToday)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(isSel ? RoundedRectangle(cornerRadius: 10).fill(BaselineColor.surface) : nil)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(BaselineColor.line, lineWidth: 1))
    }

    @ViewBuilder private func marker(for day: TrainingDay, isToday: Bool) -> some View {
        let count = day.sessions.count
        if count == 0 {
            Circle().fill(.clear).frame(width: 12, height: 12)                       // rest — no marker
        } else if count > 1 {
            Text("\(count)").font(.caption.weight(.bold)).foregroundStyle(BaselineColor.textHi)
                .frame(width: 14, height: 14).background(Circle().fill(BaselineColor.amethyst))
        } else if isToday {
            Circle().strokeBorder(BaselineColor.accent, lineWidth: 2).frame(width: 11, height: 11)  // today ring
        } else {
            Circle().fill(BaselineColor.textFaint).frame(width: 6, height: 6)         // scheduled
        }
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
    static func weekdayAbbreviation(_ date: Date, calendar: Calendar) -> String {
        let weekday = calendar.component(.weekday, from: date)
        guard calendar.shortWeekdaySymbols.indices.contains(weekday - 1) else { return "" }
        return String(calendar.shortWeekdaySymbols[weekday - 1].prefix(2)).uppercased()
    }

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
