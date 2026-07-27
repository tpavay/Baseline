import Combine
import SwiftUI

/// The **Plan tab** - Baseline's calendar-level training surface (`docs/implementation/plan-tab.md`).
///
/// One week at a time: a `‹ JUL 20 – 26 ›` pager, a seven-day status strip, and a filled-cell day grid
/// where each day is a full-width row rather than a floating card. A performed day is filled green and
/// opens its log; today's and future sessions are neutral and carry a reorder handle; a decided rest day
/// shows its moon; an undecided day shows a single accent "+". Today is marked by its accent date alone,
/// and the other days sit slightly muted behind it.
///
/// The week is *owned* state (`weekStart`), not something inferred from scroll geometry - which is what
/// removed the old 181-day calendar's range header jumping weeks when the list re-estimated row heights.
struct PlanView: View {
    /// The clock every date decision on this screen reads. Injectable so a screen test can render a
    /// week that always contains a past, a present and a future day. Production reads the live clock
    /// on each access, and the day-derived cache is rebuilt whenever the calendar day turns over -
    /// on foreground and on `NSCalendarDayChanged` - so the tab never leaves yesterday marked today.
    var now: () -> Date = { Date() }
    #if DEBUG
    /// Render-only seam used by app-hosted tests to capture the otherwise transient lift and
    /// mid-drag states. Compiled out of release builds; schedule mutation tests drive real writes.
    var dragEvidence: DragEvidence? = nil
    #endif

    @Environment(PlanStore.self) private var plan
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var execContext: ExecContext?
    @State private var showChat = false
    @State private var dragState: DragState?
    /// True only while the lift gesture is live. SwiftUI resets a `@GestureState` on cancellation as
    /// well as on completion, which is the one signal that distinguishes an interrupted drag - a
    /// system alert, an incoming call, a competing gesture - from a finished one.
    @GestureState private var dragGestureActive = false
    @State private var sessionFrames: [UUID: CGRect] = [:]
    @State private var dayFrames: [Date: CGRect] = [:]
    #if DEBUG
    @State private var evidenceDragInstalled = false
    #endif
    @State private var deleteTarget: DeleteTarget?
    @State private var undoMessage: String?
    @State private var importContext: ImportContext?
    /// A scheduled workout the user chose to remove from inside its editor. The deletion runs on sheet
    /// dismissal (in `flushExecution`) so the alert/undo never races the dismissing execution sheet.
    @State private var queuedDeletionID: UUID?
    /// A provisional empty workout the user discarded from live logging. Purged on sheet dismissal (in
    /// `flushExecution`), same deferral as `queuedDeletionID`, so the placeholder leaves the day empty
    /// and the discard lands the user back on the Plan page.
    @State private var queuedProvisionalPurgeID: UUID?
    /// Unfinished image imports, so a day whose import is still being reviewed shows a resume affordance
    /// instead of silently losing the draft off-screen.
    @State private var pendingImports: [WorkoutImportPendingSummary] = []
    /// The day whose "Add to <day>" sheet is open, if any.
    @State private var addContext: AddContext?
    /// The option chosen inside the add sheet, run on its dismissal so the follow-on presentation (chat,
    /// editor, import) never races the dismissing sheet.
    @State private var pendingAdd: (date: Date, option: AddToDayOption)?
    @State private var detailWorkout: ScheduledWorkout?
    /// The Monday of the week on screen - the only input to what the grid shows. Moved by the pager,
    /// by the Today button, and by a calendar rollover that finds the athlete still on what was then
    /// the current week. Nil until the first refresh resolves it from the clock.
    @State private var weekStart: Date?
    /// Cached week projection, derived statuses and the built presentation. Refreshed on appear, on each
    /// plan mutation (`plan.revision`) and on week navigation - never fetched or rebuilt inside `body`.
    @State private var presentation: PlanWeekPresentation?
    @State private var sessionByID: [UUID: ScheduledWorkout] = [:]

    /// A live execution buffer — a scratch `WorkoutStore` driving the reused `WorkoutView`, wired to
    /// write through to the Plan repository. Identifiable so it drives a `.sheet(item:)`.
    struct ExecContext: Identifiable {
        let id: UUID
        let store: WorkoutStore
        let original: Workout
        /// This scheduled workout was created only to start an empty workout right now; discarding its
        /// log purges the placeholder instead of keeping a blank scheduled workout on the day.
        var isProvisionalEmpty = false
    }
    struct DragState {
        let sourceID: UUID
        let sourceRow: PlanDayRow
        let sourceIndex: Int
        let sourceShowsDate: Bool
        let entry: PlanSessionEntry
        let sourceFrame: CGRect
        var translation: CGSize = .zero
        var target: PlanDragReorderModel.Target = .noChange
    }
    #if DEBUG
    struct DragEvidence {
        let sourceID: UUID
        let destinationDate: Date?
        let destinationIndex: Int

        init(sourceID: UUID, destinationDate: Date? = nil, destinationIndex: Int = 0) {
            self.sourceID = sourceID
            self.destinationDate = destinationDate
            self.destinationIndex = destinationIndex
        }
    }
    #endif
    struct DeleteTarget: Identifiable { let id = UUID(); let sw: ScheduledWorkout; let proposalID: UUID }
    struct ImportContext: Identifiable { let id = UUID(); let date: Date; var source: WorkoutImportImageSource? }
    struct AddContext: Identifiable { let id = UUID(); let date: Date }

    private let cal = Calendar.planWeek
    private var today: Date { cal.startOfDay(for: now()) }
    private var focusedWeekStart: Date { weekStart ?? cal.weekStart(for: today) }
    /// Non-today rows sit back so the accent date on today reads first.
    private let mutedDayOpacity = 0.72
    /// A floor for the week label so the pager's chevrons hold still when a range straddles a month
    /// ("JUL 27 – AUG 2" is wider than "JUL 20 – 26"); the label still grows with Dynamic Type.
    private let weekRangeMinimumWidth: CGFloat = 132

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()

                VStack(spacing: 0) {
                    weekPager
                    weekdayStrip
                    dayGrid
                }

                if let msg = undoMessage { undoBar(msg) }
                if let dragState { liftedSession(dragState) }
            }
            .coordinateSpace(name: "planDrag")
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { calendarToolbar }
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .sheet(item: $execContext, onDismiss: flushExecution) { ctx in
            WorkoutView(
                onRequestDelete: { queuedDeletionID = ctx.id },
                onRequestDiscard: ctx.isProvisionalEmpty ? { queuedProvisionalPurgeID = ctx.id } : nil
            )
            .environment(ctx.store)
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
        .task(id: undoMessage) {
            guard undoMessage != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            undoMessage = nil
        }
        .onAppear(perform: syncToCurrentDay)
        .onChange(of: plan.revision) { refreshWeek() }
        .onChange(of: dragGestureActive) { _, active in
            guard active == false else { return }
            cancelInterruptedDrag()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { cancelDrag(); return }
            syncToCurrentDay()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            syncToCurrentDay()
        }
        .task { await loadPendingImports() }
    }

    /// One repository pass per plan mutation or week change: the seven-day projection, each session's
    /// derived status, and the built presentation, all held in `@State` so `body` stays fetch-free.
    private func refreshWeek() {
        let start = focusedWeekStart
        weekStart = start
        let week = plan.week(containing: start)
        let sessions = week.days.flatMap(\.sessions)
        sessionByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        presentation = PlanWeekPresentation.build(
            week: week,
            statuses: plan.statuses(for: sessions, today: now()),
            today: today,
            calendar: cal
        )
    }

    /// Brings the screen back onto the real calendar day after the clock has moved underneath it:
    /// carry the visible week forward when the athlete was still sitting on what was then the current
    /// week, re-anchor the store's focused week, and rebuild the day-derived cache when the day it was
    /// built for has passed. A week the athlete deliberately paged to is never moved for them.
    private func syncToCurrentDay() {
        carryVisibleWeekForward()
        reanchorFocusedWeek()
        if presentation?.today != today { refreshWeek() }
    }

    /// The cached projection records the day its rules were resolved against, which is what tells a
    /// week the athlete chose from a week they merely left open: if the week on screen is still the
    /// one that contained *that* day, it was the current week and the clock should carry it forward.
    private func carryVisibleWeekForward() {
        guard let previousDay = presentation?.today else { return }
        let currentWeek = cal.weekStart(for: today)
        guard cal.weekStart(for: previousDay) == focusedWeekStart, currentWeek != focusedWeekStart else { return }
        weekStart = currentWeek
    }

    /// `PlanStore.week` is what "this week" means to the agent and to every non-calendar consumer, so
    /// it has to track the real current week on a process that outlives a week boundary. Paging the
    /// calendar deliberately never comes through here (see `showWeek(offsetBy:)`), and the guard keeps
    /// the `reload()` inside `showWeek(of:)` from bouncing off `.onChange(of: plan.revision)`.
    private func reanchorFocusedWeek() {
        let currentDay = today
        guard cal.weekStart(for: plan.focusedDate) != cal.weekStart(for: currentDay) else { return }
        plan.showWeek(of: currentDay)
    }

    private func showWeek(offsetBy weeks: Int) {
        guard let moved = cal.date(byAdding: .day, value: 7 * weeks, to: focusedWeekStart) else { return }
        cancelDrag()
        weekStart = cal.weekStart(for: moved)
        refreshWeek()
    }

    private func showCurrentWeek() {
        cancelDrag()
        weekStart = cal.weekStart(for: today)
        reanchorFocusedWeek()
        refreshWeek()
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
                Text(filterLabel)
                    .font(.caption.monospaced().weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(plan.filter == .allTraining ? BaselineColor.textFaint : BaselineColor.accent)
            }
            .accessibilityLabel("Calendar options")
        }

        ToolbarItem(placement: .principal) {
            Text(presentation?.monthLabel ?? PlanWeekPresentation.monthLabel(weekStart: focusedWeekStart, calendar: cal))
                .font(.headline.weight(.semibold))
                .foregroundStyle(BaselineColor.textHi)
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button("Today") { showCurrentWeek() }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(BaselineColor.accent)
                .accessibilityHint("Shows the current week")
        }
    }

    private var filterLabel: String {
        switch plan.filter {
        case .allTraining: return "ALL TRAINING"
        case .program(let id): return (plan.programs().first { $0.id == id }?.name ?? "PROGRAM").uppercased()
        case .collection(let c): return c.rawValue.uppercased()
        }
    }

    // MARK: Week pager

    private var weekPager: some View {
        HStack(spacing: BaselineSpacing.medium) {
            pagerButton(systemImage: "chevron.left", label: "Previous week") { showWeek(offsetBy: -1) }
            InstrumentLabel(presentation?.rangeLabel ?? "", color: BaselineColor.textMid, tracking: 1.5)
                .frame(minWidth: weekRangeMinimumWidth)
                .accessibilityAddTraits(.isHeader)
            pagerButton(systemImage: "chevron.right", label: "Next week") { showWeek(offsetBy: 1) }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, BaselineSpacing.xSmall)
    }

    private func pagerButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(BaselineColor.textFaint)
                .frame(width: BaselineSize.minimumTapTarget, height: BaselineSize.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Seven-day strip

    private var weekdayStrip: some View {
        HStack(spacing: BaselineSpacing.xxxSmall) {
            ForEach(presentation?.weekdays ?? []) { cell in
                VStack(spacing: BaselineSpacing.xxxSmall) {
                    weekdayMark(cell.mark)
                        .frame(height: BaselineSize.dayStatusMarkSlot)
                    Text(cell.letter)
                        .font(.caption2.monospaced().weight(cell.isToday ? .heavy : .semibold))
                        .foregroundStyle(cell.isToday ? BaselineColor.accent : BaselineColor.textFaint)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(weekdayAccessibilityLabel(cell))
            }
        }
        .padding(.vertical, BaselineSpacing.compact)
        .padding(.horizontal, BaselineSpacing.xSmall)
        .background(
            RoundedRectangle(cornerRadius: BaselineRadius.search, style: .continuous)
                .fill(BaselineColor.surface.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: BaselineRadius.search, style: .continuous)
                        .strokeBorder(BaselineColor.line, lineWidth: BaselineSize.hairline)
                )
        )
        .padding(.horizontal, BaselineSpacing.large)
        .padding(.bottom, BaselineSpacing.medium)
    }

    @ViewBuilder
    private func weekdayMark(_ mark: PlanWeekdayMark) -> some View {
        switch mark {
        case .none:
            Color.clear
        case .completed:
            Circle()
                .fill(BaselineColor.zoneGreen)
                .frame(width: BaselineSize.dayStatusDot, height: BaselineSize.dayStatusDot)
        case .rest:
            Image(systemName: "moon.fill")
                .font(.system(size: BaselineSize.dayStatusMoon))
                .foregroundStyle(BaselineColor.textFaint)
        }
    }

    private func weekdayAccessibilityLabel(_ cell: PlanWeekdayCell) -> String {
        let day = cell.date.formatted(.dateTime.weekday(.wide))
        if cell.isToday { return "\(day), today" }
        switch cell.mark {
        case .completed: return "\(day), workout completed"
        case .rest: return "\(day), rest day"
        case .none: return day
        }
    }

    // MARK: Day grid

    private var dayGrid: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(presentation?.days ?? []) { row in
                    dayGroup(row)
                }
                Hairline(color: BaselineColor.line.opacity(0.7))
            }
            .padding(.bottom, BaselineSpacing.screenBottom)
        }
        .scrollIndicators(.hidden)
        // The lift freezes the frame snapshot the drop resolves against, so the content underneath it
        // has to hold still too: a scroll mid-drag would slide rows out from under the frozen geometry
        // and silently land the session on a neighbouring day.
        .scrollDisabled(dragState != nil)
        .onPreferenceChange(PlanDragGeometryPreferences.SessionFrames.self) { frames in
            if dragState == nil {
                sessionFrames = frames
                installEvidenceDragIfReadyInDebug()
            }
        }
        .onPreferenceChange(PlanDragGeometryPreferences.DayFrames.self) { frames in
            if dragState == nil {
                dayFrames = frames
                installEvidenceDragIfReadyInDebug()
            }
        }
    }

    private func installEvidenceDragIfReadyInDebug() {
        #if DEBUG
        installEvidenceDragIfReady()
        #endif
    }

    /// A day is a stack of full-width cells sharing one top rule: its sessions (plus an "add a second"
    /// cell on today and future days), or its rest marker, or the single "+" of an undecided day.
    private func dayGroup(_ row: PlanDayRow) -> some View {
        let pendingReview = reviewableImport(for: row.date)
        let insertion = insertionDestination(for: row)
        let lockText = dragLockText(for: row)
        return VStack(spacing: 0) {
            Hairline(color: BaselineColor.line.opacity(0.7))
            if let pendingReview {
                importCell(row, summary: pendingReview)
            }
            switch row.content {
            case .sessions(let entries):
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if insertion?.displayIndex == index {
                        insertionIndicator
                    }
                    if let scheduled = sessionByID[entry.id] {
                        sessionCell(row, entry,
                                    scheduled: scheduled,
                                    showsDate: pendingReview == nil && index == 0,
                                    index: index)
                    }
                }
                if insertion?.displayIndex == entries.count {
                    insertionIndicator
                }
                if row.showsAddAnother {
                    addAnotherCell(row)
                }
            case .rest:
                if insertion != nil { insertionIndicator }
                restCell(row, showsDate: pendingReview == nil)
            case .empty:
                if insertion != nil { insertionIndicator }
                if pendingReview == nil { emptyCell(row) }
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PlanDragGeometryPreferences.DayFrames.self,
                    value: [cal.startOfDay(for: row.date): proxy.frame(in: .named("planDrag"))]
                )
            }
        }
        .overlay(alignment: .trailing) {
            if let lockText {
                Label(lockText, systemImage: "lock.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(BaselineColor.textMid)
                    .padding(.horizontal, BaselineSpacing.xSmall)
                    .padding(.vertical, BaselineSpacing.xxxSmall)
                    .background(Capsule().fill(BaselineColor.surface))
                    .overlay(Capsule().strokeBorder(BaselineColor.line, lineWidth: BaselineSize.hairline))
                    .padding(.trailing, BaselineSpacing.large)
                    .accessibilityLabel(lockText)
            }
        }
        .opacity(lockText == nil ? (row.isToday || insertion != nil ? 1 : mutedDayOpacity) : 0.48)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: insertion)
    }

    /// The shared cell scaffold: a leading date column (blank but reserved on a day's later cells so
    /// every title lines up) and the cell's own content, filling the row edge to edge.
    private func cell<Content: View>(
        _ row: PlanDayRow,
        showsDate: Bool,
        dateTint: Color,
        fill: Color = .clear,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: BaselineSpacing.medium) {
            VStack(spacing: BaselineSpacing.xxxSmall) {
                Text(row.dayNumber)
                    .font(.headline.monospacedDigit().weight(.bold))
                Text(row.weekdayAbbreviation)
                    .font(.caption2.monospaced().weight(.semibold))
                    .tracking(0.8)
            }
            .foregroundStyle(dateTint)
            .frame(width: dateColumnWidth)
            .opacity(showsDate ? 1 : 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(dayLabel(row.date))
            .accessibilityHidden(!showsDate)

            content()
        }
        .padding(.horizontal, BaselineSpacing.large)
        .padding(.vertical, BaselineSpacing.xSmall)
        .frame(maxWidth: .infinity, minHeight: BaselineSize.minimumTapTarget, alignment: .leading)
        .background(fill)
    }

    /// Every cell reserves the same leading column, so titles, glyphs and the "+" of a day's later
    /// cells all line up under its date.
    private var dateColumnWidth: CGFloat { BaselineSize.minimumTapTarget - BaselineSpacing.xxSmall }

    private func dateTint(_ row: PlanDayRow) -> Color {
        if row.isToday { return BaselineColor.accent }
        if row.sessions.contains(where: \.isCompleted) { return BaselineColor.zoneGreen }
        return BaselineColor.textMid
    }

    // MARK: Cells

    /// The swipe row's own background has to stay opaque so the sliding content hides the Delete
    /// action behind it - except while the day is a drop target, where an opaque row would paint over
    /// the highlight `dayGroup` draws behind the whole day.
    private func sessionCell(
        _ row: PlanDayRow,
        _ entry: PlanSessionEntry,
        scheduled: ScheduledWorkout,
        showsDate: Bool,
        index: Int
    ) -> some View {
        reorderable(
            WorkoutSwipeActionRow(
                actionTitle: "Delete",
                systemImage: "trash",
                contentBackground: BaselineColor.base,
                action: { handle(.delete, scheduled) }
            ) {
                cell(row,
                     showsDate: showsDate,
                     dateTint: dateTint(row),
                     fill: entry.isCompleted ? BaselineColor.zoneGreen.opacity(0.13) : .clear) {
                    HStack(spacing: BaselineSpacing.xSmall) {
                        if entry.showsReorderHandle {
                            reorderHandle
                                .gesture(
                                    planDragGesture(
                                        row: row,
                                        entry: entry,
                                        index: index,
                                        showsDate: showsDate
                                    )
                                )
                        }
                        sessionButton(entry, scheduled: scheduled)
                            .contextMenu { sessionMenu(scheduled, status: entry.status, row: row) }
                    }
                }
            }
            .opacity(dragState?.sourceID == entry.id ? 0.08 : 1)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PlanDragGeometryPreferences.SessionFrames.self,
                        value: [entry.id: proxy.frame(in: .named("planDrag"))]
                    )
                }
            },
            entry: entry
        )
    }

    private func sessionButton(_ entry: PlanSessionEntry, scheduled: ScheduledWorkout) -> some View {
        Button {
            detailWorkout = scheduled
        } label: {
            HStack(spacing: BaselineSpacing.xSmall) {
                VStack(alignment: .leading, spacing: BaselineSpacing.xxxSmall) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BaselineColor.textHi)
                        .lineLimit(1)
                    HStack(spacing: BaselineSpacing.xxSmall) {
                        if entry.isCompleted == false, let (label, color) = PlanStatusStyle.chip(entry.status) {
                            Text(label)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(color)
                        }
                        Text(entry.detail)
                            .font(.caption)
                            .foregroundStyle(entry.isCompleted ? BaselineColor.zoneGreen : BaselineColor.textMid)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: BaselineSpacing.xSmall)
                if entry.isCompleted {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BaselineColor.zoneGreen)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: BaselineSize.minimumTapTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(entry.isCompleted ? "Opens the logged session" : "Opens workout details")
        // Context menus do not expose their primary action to assistive tech.
        .accessibilityAction(named: Text(openLabel(entry.status))) { handle(.open, scheduled) }
    }

    private var reorderHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(BaselineColor.accent)
            .frame(width: BaselineSize.minimumTapTarget, height: BaselineSize.minimumTapTarget)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }

    /// The assistive-tech route to the same reorder the handle offers by touch. The gesture itself
    /// belongs to the handle, not to the row: the row body carries the long-press menu, so the two
    /// long presses own disjoint areas and can never race for the same touch.
    @ViewBuilder
    private func reorderable<Content: View>(_ content: Content, entry: PlanSessionEntry) -> some View {
        if entry.showsReorderHandle {
            content
                .accessibilityAction(named: Text("Move earlier")) {
                    moveAccessibly(entry.id, direction: -1)
                }
                .accessibilityAction(named: Text("Move later")) {
                    moveAccessibly(entry.id, direction: 1)
                }
                .accessibilityHint("Opens workout details. Press and hold the reorder handle, then drag")
        } else {
            content
        }
    }

    private func planDragGesture(
        row: PlanDayRow,
        entry: PlanSessionEntry,
        index: Int,
        showsDate: Bool
    ) -> some Gesture {
        LongPressGesture(minimumDuration: 0.22, maximumDistance: 16)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("planDrag")))
            .updating($dragGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                switch value {
                case .first(true):
                    beginDrag(row: row, entry: entry, index: index, showsDate: showsDate)
                case .second(true, let drag?):
                    beginDrag(row: row, entry: entry, index: index, showsDate: showsDate)
                    updateDrag(drag)
                default:
                    break
                }
            }
            .onEnded { _ in finishDrag() }
    }

    private func beginDrag(
        row: PlanDayRow,
        entry: PlanSessionEntry,
        index: Int,
        showsDate: Bool
    ) {
        guard dragState == nil, let measuredFrame = sessionFrames[entry.id] else { return }
        let frame = liftFrame(measuredFrame, on: row.date)
        let state = DragState(
            sourceID: entry.id,
            sourceRow: row,
            sourceIndex: index,
            sourceShowsDate: showsDate,
            entry: entry,
            sourceFrame: frame
        )
        Haptics.select()
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
            dragState = state
        }
    }

    private func updateDrag(_ drag: DragGesture.Value) {
        guard var state = dragState else { return }
        let newTarget = PlanDragReorderModel.target(
            at: drag.location,
            sourceID: state.sourceID,
            sourceDate: state.sourceRow.date,
            days: dragDayGeometry()
        )
        if newTarget != state.target {
            Haptics.select()
        }
        state.translation = drag.translation
        state.target = newTarget
        dragState = state
    }

    private func finishDrag() {
        guard let state = dragState else { return }
        let destination: PlanDragReorderModel.Destination?
        if case .destination(let value) = state.target {
            destination = value
        } else {
            destination = nil
        }

        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
            dragState = nil
        }
        guard let destination else { return }
        apply(
            plan.reposition(
                state.sourceID,
                toDate: destination.date,
                at: destination.index,
                notBefore: today
            ),
            "Moved"
        )
    }

    /// Put the grid back the way an uninterrupted drag would have left it, without moving anything.
    private func cancelDrag() {
        guard dragState != nil else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
            dragState = nil
        }
    }

    /// A cancelled gesture never delivers `onEnded`, so the lift would otherwise stay pinned over the
    /// grid forever - source row faded out, days locked, and `beginDrag` refusing to start another.
    /// The reset of the gesture-backed flag is the signal; the hop to the next main-actor turn lets a
    /// gesture that merely *finished* commit its drop first, whichever order SwiftUI delivers them in.
    private func cancelInterruptedDrag() {
        guard let liftedID = dragState?.sourceID else { return }
        Task { @MainActor in
            guard dragState?.sourceID == liftedID else { return }
            cancelDrag()
        }
    }

    private func dragDayGeometry() -> [PlanDragReorderModel.DayGeometry] {
        (presentation?.days ?? []).compactMap { row in
            let date = cal.startOfDay(for: row.date)
            guard let frame = dayFrames[date] else { return nil }
            let sessions = row.sessions.compactMap { entry -> PlanDragReorderModel.SessionGeometry? in
                guard let frame = sessionFrames[entry.id] else { return nil }
                return PlanDragReorderModel.SessionGeometry(id: entry.id, frame: frame)
            }
            return PlanDragReorderModel.DayGeometry(
                date: date,
                frame: frame,
                sessions: sessions,
                isPast: row.isPast,
                isCompleted: row.sessions.contains(where: \.isCompleted)
            )
        }
    }

    #if DEBUG
    private func installEvidenceDragIfReady() {
        guard evidenceDragInstalled == false,
              let evidence = dragEvidence,
              let rows = presentation?.days,
              let sourceRow = rows.first(where: { $0.sessions.contains { $0.id == evidence.sourceID } }),
              let sourceIndex = sourceRow.sessions.firstIndex(where: { $0.id == evidence.sourceID }),
              let entry = sourceRow.sessions.first(where: { $0.id == evidence.sourceID }),
              let measuredFrame = sessionFrames[evidence.sourceID],
              dayFrames[cal.startOfDay(for: sourceRow.date)] != nil else {
            return
        }
        let sourceFrame = liftFrame(measuredFrame, on: sourceRow.date)

        var state = DragState(
            sourceID: evidence.sourceID,
            sourceRow: sourceRow,
            sourceIndex: sourceIndex,
            sourceShowsDate: sourceIndex == 0,
            entry: entry,
            sourceFrame: sourceFrame
        )
        if let destinationDate = evidence.destinationDate,
           let destinationRow = rows.first(where: {
               cal.isDate($0.date, inSameDayAs: destinationDate)
           }),
           let destinationFrame = dayFrames[cal.startOfDay(for: destinationDate)] {
            let finalIndex = min(max(evidence.destinationIndex, 0), destinationRow.sessions.count)
            let sameDay = cal.isDate(sourceRow.date, inSameDayAs: destinationDate)
            let displayIndex = sameDay && finalIndex > sourceIndex ? finalIndex + 1 : finalIndex
            state.target = .destination(
                .init(date: destinationDate, index: finalIndex, displayIndex: displayIndex)
            )
            state.translation = CGSize(
                width: destinationFrame.midX - sourceFrame.midX,
                height: destinationFrame.midY - sourceFrame.midY - sourceFrame.height * 0.65
            )
        }
        evidenceDragInstalled = true
        dragState = state
    }
    #endif

    private func liftFrame(_ measuredFrame: CGRect, on date: Date) -> CGRect {
        guard let dayFrame = dayFrames[cal.startOfDay(for: date)] else { return measuredFrame }
        return CGRect(
            x: dayFrame.minX,
            y: measuredFrame.minY,
            width: dayFrame.width,
            height: measuredFrame.height
        )
    }

    private func insertionDestination(for row: PlanDayRow) -> PlanDragReorderModel.Destination? {
        guard let target = dragState?.target,
              case .destination(let destination) = target,
              cal.isDate(destination.date, inSameDayAs: row.date) else {
            return nil
        }
        return destination
    }

    private func dragLockText(for row: PlanDayRow) -> String? {
        guard dragState != nil else { return nil }
        if row.isPast { return "Past day - can't drop here" }
        if row.sessions.contains(where: \.isCompleted) { return "Completed day - can't drop here" }
        return nil
    }

    private var insertionIndicator: some View {
        HStack(spacing: 0) {
            Circle().frame(width: 7, height: 7)
            Rectangle().frame(height: 3)
            Circle().frame(width: 7, height: 7)
        }
        .foregroundStyle(BaselineColor.accent)
        .shadow(color: BaselineColor.accent.opacity(0.45), radius: 5)
        .padding(.leading, BaselineSpacing.large + dateColumnWidth + BaselineSpacing.medium)
        .padding(.trailing, BaselineSpacing.large)
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drop position")
    }

    private func liftedSession(_ state: DragState) -> some View {
        GeometryReader { proxy in
            cell(
                state.sourceRow,
                showsDate: state.sourceShowsDate,
                dateTint: dateTint(state.sourceRow)
            ) {
                HStack(spacing: BaselineSpacing.xSmall) {
                    reorderHandle
                    VStack(alignment: .leading, spacing: BaselineSpacing.xxxSmall) {
                        Text(state.entry.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(BaselineColor.textHi)
                            .lineLimit(1)
                        Text(state.entry.detail)
                            .font(.caption)
                            .foregroundStyle(BaselineColor.textMid)
                            .lineLimit(1)
                    }
                    Spacer(minLength: BaselineSpacing.xSmall)
                }
            }
            .frame(
                width: max(0, proxy.size.width - BaselineSpacing.medium),
                height: state.sourceFrame.height
            )
            .background(BaselineColor.base)
            .clipShape(RoundedRectangle(cornerRadius: BaselineRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BaselineRadius.card, style: .continuous)
                    .strokeBorder(BaselineColor.accent, lineWidth: 1.5)
            }
            .shadow(color: BaselineColor.accent.opacity(0.22), radius: 18, y: 8)
            .scaleEffect(reduceMotion ? 1 : 1.025)
            .position(
                x: proxy.size.width / 2 + state.translation.width,
                y: state.sourceFrame.midY + state.translation.height
            )
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dragging \(state.entry.title)")
        .zIndex(10)
    }

    private func moveAccessibly(_ id: UUID, direction: Int) {
        guard direction == -1 || direction == 1,
              let days = presentation?.days,
              let sourceDayIndex = days.firstIndex(where: { $0.sessions.contains { $0.id == id } }),
              let sourceIndex = days[sourceDayIndex].sessions.firstIndex(where: { $0.id == id }) else {
            announceNoMove(direction: direction)
            return
        }

        let sourceDay = days[sourceDayIndex]
        let withinDayIndex = sourceIndex + direction
        if sourceDay.sessions.indices.contains(withinDayIndex) {
            apply(
                plan.reposition(
                    id,
                    toDate: sourceDay.date,
                    at: withinDayIndex,
                    notBefore: today
                ),
                "Moved"
            )
            return
        }

        var dayIndex = sourceDayIndex + direction
        while days.indices.contains(dayIndex) {
            let candidate = days[dayIndex]
            let locked = candidate.isPast || candidate.sessions.contains(where: \.isCompleted)
            if locked == false {
                let destinationIndex = direction < 0 ? candidate.sessions.count : 0
                apply(
                    plan.reposition(
                        id,
                        toDate: candidate.date,
                        at: destinationIndex,
                        notBefore: today
                    ),
                    "Moved"
                )
                return
            }
            dayIndex += direction
        }
        announceNoMove(direction: direction)
    }

    /// A reorder action that finds nowhere legal to go has to say so: silence reads as a move that
    /// happened somewhere off-screen. The week on screen bounds the search, so the reason is always
    /// either the edge of that week or a locked day between here and it.
    private func announceNoMove(direction: Int) {
        let phrase = direction < 0
            ? "Can't move earlier. This is the first open slot in the week"
            : "Can't move later. This is the last open slot in the week"
        AccessibilityNotification.Announcement(phrase).post()
    }

    /// An undecided day is a decision waiting to be made, and the whole row is the invitation: one
    /// accent "+" opening the per-day add sheet (which is also where "Make it a rest day" lives).
    private func emptyCell(_ row: PlanDayRow) -> some View {
        cell(row, showsDate: true, dateTint: dateTint(row)) {
            Button {
                addContext = AddContext(date: row.date)
            } label: {
                plusGlyph
                    .frame(maxWidth: .infinity, minHeight: BaselineSize.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add workout")
            .accessibilityHint("Opens options to add training to \(dayLabel(row.date))")
        }
    }

    /// A second session on a day that already has one - offered on today and future days only.
    private func addAnotherCell(_ row: PlanDayRow) -> some View {
        Button {
            addContext = AddContext(date: row.date)
        } label: {
            HStack(spacing: BaselineSpacing.medium) {
                Color.clear.frame(width: dateColumnWidth, height: BaselineSize.hairline)
                plusGlyph.frame(maxWidth: .infinity)
            }
            .padding(.horizontal, BaselineSpacing.large)
            .padding(.bottom, BaselineSpacing.compact)
            .frame(maxWidth: .infinity, minHeight: BaselineSize.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add another workout")
        .accessibilityHint("Adds a second session to \(dayLabel(row.date))")
    }

    private var plusGlyph: some View {
        Image(systemName: "plus")
            .font(.system(size: BaselineSize.selectionGlyph, weight: .light))
            .foregroundStyle(BaselineColor.accent)
    }

    /// A decided rest day: a moon and the word for it. The moon is its own undo - the same tap that
    /// declared the day un-declares it - and the label opens the add sheet, so replacing rest with
    /// training never needs the day to be cleared first.
    private func restCell(_ row: PlanDayRow, showsDate: Bool) -> some View {
        cell(row, showsDate: showsDate, dateTint: dateTint(row)) {
            HStack(spacing: 0) {
                Button {
                    plan.setRestDay(row.date, false)
                } label: {
                    Image(systemName: "moon.zzz.fill")
                        .font(.subheadline)
                        .foregroundStyle(BaselineColor.textFaint)
                        .frame(width: BaselineSize.minimumTapTarget, height: BaselineSize.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove rest day")
                .accessibilityHint("Removes the rest-day mark from \(dayLabel(row.date))")

                Button {
                    addContext = AddContext(date: row.date)
                } label: {
                    Text("Rest day")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(BaselineColor.textMid)
                        .frame(maxWidth: .infinity, minHeight: BaselineSize.minimumTapTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rest day")
                .accessibilityHint("Opens options to add training to \(dayLabel(row.date))")
            }
        }
    }

    private func importCell(_ row: PlanDayRow, summary: WorkoutImportPendingSummary) -> some View {
        cell(row, showsDate: true, dateTint: dateTint(row)) {
            Button {
                importContext = ImportContext(date: row.date)
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the imported workout to review and save")
        }
    }

    private func dayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    // MARK: Session actions

    /// Plan-level organization for a session, one press away from its row: start/resume, move within
    /// its week, duplicate, skip/unskip, delete. Mirrors what the old timeline card's menu offered.
    @ViewBuilder
    private func sessionMenu(_ scheduled: ScheduledWorkout, status: ScheduleStatus, row: PlanDayRow) -> some View {
        Button(openLabel(status), systemImage: "play") { handle(.open, scheduled) }
        let destinations = moveDestinations(from: row)
        if destinations.isEmpty == false {
            Menu("Move to") {
                ForEach(destinations, id: \.self) { date in
                    Button(date.formatted(.dateTime.weekday(.wide))) { handle(.move(date), scheduled) }
                }
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

    /// The days the menu is allowed to offer - the same today-or-later, nothing-performed-here rule the
    /// drag path enforces, so the two reorder routes cannot disagree about which days are locked. A
    /// session sitting on a locked day is not going anywhere either, and gets no submenu at all.
    private func moveDestinations(from row: PlanDayRow) -> [Date] {
        guard isLocked(row) == false else { return [] }
        return (presentation?.days ?? [])
            .filter { candidate in
                isLocked(candidate) == false && cal.isDate(candidate.date, inSameDayAs: row.date) == false
            }
            .map(\.date)
    }

    private func isLocked(_ row: PlanDayRow) -> Bool {
        row.isPast || row.sessions.contains(where: \.isCompleted)
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
        openExecution(plan.newScheduledWorkout(on: date), isProvisionalEmpty: true).store.startWorkout()
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
        // The menu is the drag's secondary route, so it lands on the same guarded mutation: appended to
        // the end of the target day, and rejected outright for a past or performed day.
        case .move(let d): apply(plan.reposition(sw.id, toDate: d, at: .max, notBefore: today), "Moved")
        case .delete:
            if case .confirmationRequired(_, _, let pid) = plan.delete(sw.id) { deleteTarget = DeleteTarget(sw: sw, proposalID: pid) }
        }
    }

    /// Surface an Undo affordance after an applied mutation.
    private func apply(_ result: MutationResult, _ verb: String) {
        if result.isApplied { withAnimation { undoMessage = verb } }
    }

    // MARK: Execution bridge — reuse WorkoutView, write through to the repository

    @discardableResult
    private func openExecution(_ sw: ScheduledWorkout, isProvisionalEmpty: Bool = false) -> ExecContext {
        // A scratch store bound to this scheduled workout — logging + lifecycle write through immediately;
        // structural content edits are coalesced and flushed as one revision on dismiss.
        let store = WorkoutStore(units: settings, defaults: UserDefaults(suiteName: "plan.exec.buffer") ?? .standard)
        store.bind(plan.sink(forScheduled: sw.id), coalesceContent: true)
        let context = ExecContext(id: sw.id, store: store, original: sw.workout, isProvisionalEmpty: isProvisionalEmpty)
        execContext = context
        return context
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
        if let id = queuedProvisionalPurgeID {
            queuedProvisionalPurgeID = nil
            plan.purgeProvisional(id)   // discarded empty workout — leave the day undecided
            return
        }
        guard let ctx = execContext else { return }
        if ctx.store.current != ctx.original { ctx.store.flush() }
        plan.reload()
    }
}
