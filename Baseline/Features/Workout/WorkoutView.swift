import SwiftData
import SwiftUI
import UIKit

/// The manual surface for a workout template and its performed log. The hierarchy stays visually
/// stable across reading, editing, and logging; only the controls inside each row change.
struct WorkoutView: View {
    /// When present, the workout is a scheduled plan session and the ••• menu offers a destructive
    /// "Remove Workout" that hands removal back to the presenter (Plan). Absent for standalone use.
    var onRequestDelete: (() -> Void)?

    /// When present, this log belongs to a *provisional* empty workout — one scheduled solely to start
    /// logging right now (Plan's "Start an empty workout"). Discarding it is not "keep the plan, drop
    /// the log": there is no plan to keep, so discard hands the whole placeholder back to the presenter
    /// to purge and dismisses to Plan, rather than dropping to a blank template view. Absent for a real
    /// scheduled workout, whose discard keeps the saved revision and stays put.
    var onRequestDiscard: (() -> Void)?

    @Environment(WorkoutStore.self) private var store
    @Environment(PlanStore.self) private var plan
    @Environment(BluetoothManager.self) private var bluetooth
    @Environment(HeartRateZoneSettingsStore.self) private var heartRateZones
    @Environment(\.dismiss) private var dismiss

    @State private var isEditingTemplate = false
    @State private var editSnapshot: Workout?
    @State private var showChat = false
    /// Captured when the athlete taps Share, never derived in `body`: building it reads the plan's
    /// completed record and re-aggregates every set, and holding it also means the composer cannot be
    /// left on screen with nothing in it if the store's session state changes underneath.
    @State private var shareRequest: ShareComposerRequest?
    @State private var showFinishConfirmation = false
    @State private var showDiscardConfirmation = false
    @State private var showSaveTemplate = false
    @State private var templateName = ""
    @State private var templateConflict: WorkoutTemplate?

    /// Mid-workout structural editing. These edits are session-scoped — they shape this workout only,
    /// and reach the saved plan solely through the completion prompt below.
    @State private var showReorder = false
    @State private var addExerciseRequest: AddExerciseRequest?
    /// Captures the reconciliation just before completing — so the "update your plan?" decision never
    /// depends on post-completion store state — and defers the prompt past the finish alert's dismissal.
    @State private var finishing = WorkoutFinishCoordinator()

    /// Live heart-rate monitor for the active log, created only while logging with a saved strap.
    /// The HUD reads it; the workout owns its start/stop lifecycle (this is the go-live wiring).
    @State private var hrMonitor: HeartRateMonitor?
    /// Captures the live series behind the HUD so the workout keeps its heart rate after the monitor
    /// is gone. Owned by the view, handed to the monitor, and reset by it on each run.
    @State private var hrRecorder = WorkoutHeartRateRecorder()
    /// The completed workout's persisted heart rate, resolved once on entering `.completed` rather
    /// than in `body`: building it decodes the whole sample array.
    @State private var completedHeartRate: WorkoutHeartRateCapture?
    /// Whether the log surface is showing the live-HR HUD instead of the exercise log.
    @State private var showLiveHR = false

    private var mode: WorkoutPresentationMode {
        if let log = store.currentLog { return log.isComplete ? .completed : .log }
        return isEditingTemplate ? .editTemplate : .view
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                if let workout = store.current {
                    workoutContent(workout)
                } else {
                    emptyState
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbar { workoutToolbar }
        }
        .tint(BaselineColor.accent)
        .sheet(isPresented: $showChat) { AskBaselineSheet(surface: .workout) }
        .fullScreenCover(item: $shareRequest) { request in
            ShareComposerView(summary: request.summary, units: request.units)
        }
        .alert("Save as template", isPresented: $showSaveTemplate) {
            TextField("Template name", text: $templateName)
            Button("Save") { saveTemplate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reuse this workout later from Add Workout on the Plan tab.")
        }
        .alert("Finish workout?", isPresented: $showFinishConfirmation) {
            Button("Finish Workout") { finishWorkout() }
            Button("Keep Logging", role: .cancel) {}
        } message: {
            Text("Logged work will be kept even if you changed, skipped, or did not finish part of the prescription.")
        }
        .sheet(isPresented: $showReorder) { WorkoutReorderSheet() }
        .sheet(item: $addExerciseRequest) { request in
            AddExerciseFlow(blockID: request.id, scope: mode.editScope) { _ in }
        }
        .alert(
            "Update your plan?",
            isPresented: Binding(
                get: { finishing.pendingReconciliation != nil },
                set: { if !$0 { finishing.pendingReconciliation = nil } }
            ),
            presenting: finishing.pendingReconciliation
        ) { reconciliation in
            Button("Update Plan") { finishing.apply(reconciliation, to: store) }
            Button("Keep Original", role: .cancel) { finishing.decline(store) }
        } message: { reconciliation in
            Text("We noticed changes from your plan:\n\(reconciliation.diff.summaryLine)")
        }
        .alert(onRequestDiscard != nil ? "Discard this workout?" : "Discard this log?", isPresented: $showDiscardConfirmation) {
            Button(onRequestDiscard != nil ? "Discard Workout" : "Discard Log", role: .destructive) {
                if let onRequestDiscard {
                    // Provisional empty workout: the presenter removes the placeholder entirely and this
                    // dismisses back to Plan, rather than dropping to a blank template view.
                    onRequestDiscard()
                    dismiss()
                } else {
                    store.discardLog()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(onRequestDiscard != nil
                ? "This workout and anything you logged in it will be removed, and the day is left with no workout scheduled."
                : "Everything you logged will be removed, along with any exercises you added, removed, replaced, or reordered during this workout. Your saved plan stays as it was.")
        }
        .confirmationDialog(
            "A template named \"\(templateName)\" already exists",
            isPresented: Binding(
                get: { templateConflict != nil },
                set: { if !$0 { templateConflict = nil } }
            ),
            presenting: templateConflict
        ) { existing in
            Button("Update \"\(existing.name)\"") {
                if let workout = store.current { plan.updateTemplate(existing.id, from: workout) }
                templateConflict = nil
            }
            Button("Save as New") {
                if let workout = store.current { plan.saveAsTemplate(name: templateName, from: workout) }
                templateConflict = nil
            }
            Button("Cancel", role: .cancel) { templateConflict = nil }
        }
        .onDisappear {
            if isEditingTemplate { finishEditing() }
            stopLiveMonitor()
            // Leaving the workout always restores normal idle behavior. The system also auto-clears
            // this on background and re-applies it via onAppear on return, matching ReadingView.
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onAppear {
            syncLiveMonitor()
            syncKeepAwake()
            syncCompletedHeartRate()
        }
        .onChange(of: mode) { _, _ in
            syncLiveMonitor()
            syncKeepAwake()
            syncCompletedHeartRate()
        }
        // A mid-workout zone edit must reach the *running* monitor: swap its live `zoneModel` so the
        // gauge and current zone re-resolve without tearing down the session. Zone-time is an
        // accumulator credited at sample-arrival time, so only subsequent seconds use the new bands —
        // seconds already banked keep the attribution they were earned under.
        .onChange(of: heartRateZones.resolvedModel) { _, newModel in
            hrMonitor?.zoneModel = newModel
        }
    }

    // MARK: - Navigation

    @ToolbarContentBuilder private var workoutToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            navigationTitleView
        }

        if isEditingTemplate {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel", action: cancelEditing)
                    .accessibilityHint("Discards changes made since editing began")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done", action: finishEditing).fontWeight(.semibold)
            }
        } else if store.current != nil {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if mode == .view {
                    Button("Edit", action: beginEditing).fontWeight(.semibold)
                } else if store.currentLog?.isComplete == false {
                    Button("Finish") { showFinishConfirmation = true }.fontWeight(.semibold)
                }
                Menu {
                    Button { showChat = true } label: {
                        Label("Talk to Baseline", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    if mode == .view {
                        Button { beginSaveTemplate() } label: {
                            Label("Save as Template", systemImage: "square.and.arrow.down")
                        }
                    }
                    if mode == .view, let onRequestDelete {
                        Button(role: .destructive) { onRequestDelete(); dismiss() } label: {
                            Label("Remove Workout", systemImage: "trash")
                        }
                    }
                    if mode == .log {
                        Button { showReorder = true } label: {
                            Label("Reorder Workout", systemImage: "arrow.up.arrow.down")
                        }
                        Divider()
                        Button(role: .destructive) { showDiscardConfirmation = true } label: {
                            Label(onRequestDiscard != nil ? "Discard Workout" : "Discard Log", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel("More workout actions")
                }
            }
        }
    }

    private var navigationTitle: String {
        if isEditingTemplate { return "Edit Workout" }
        if store.currentLog?.isComplete == true { return "Workout Summary" }
        return "Workout"
    }

    /// Cheap enough for `body`: it only reads stored store state. The summary itself is built once, on
    /// tap, in `presentShareComposer`.
    private var canShareWorkout: Bool {
        mode == .completed && store.currentLogStartedAt != nil && store.currentLogFinishedAt != nil
    }

    private func presentShareComposer() {
        guard let workout = store.current,
              let log = store.currentLog,
              log.isComplete,
              let startedAt = store.currentLogStartedAt,
              let finishedAt = store.currentLogFinishedAt
        else { return }
        let units = ShareUnitResolver(workout: workout, store: store)
        shareRequest = ShareComposerRequest(
            summary: WorkoutLogSummary(
                title: workout.title,
                log: log,
                startedAt: startedAt,
                finishedAt: finishedAt,
                units: units
            ),
            units: units
        )
    }

    @ViewBuilder private var navigationTitleView: some View {
        if mode == .log, let startedAt = store.currentLogStartedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = WorkoutPresentationFormatter.elapsedDuration(
                    from: startedAt,
                    to: context.date
                )
                Text(elapsed)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(BaselineColor.textHi)
                    .accessibilityLabel("Workout duration \(elapsed)")
            }
        } else if mode == .log {
            Text("00:00:00")
                .font(.headline.monospacedDigit())
                .foregroundStyle(BaselineColor.textHi)
                .accessibilityLabel("Workout duration 00:00:00")
        } else {
            Text(navigationTitle)
                .font(.headline)
                .foregroundStyle(BaselineColor.textHi)
        }
    }

    // MARK: - Content

    @ViewBuilder private func workoutContent(_ workout: Workout) -> some View {
        if mode.isEditing {
            WorkoutTemplateEditor {
                EmptyView()
            } bottomContent: {
                Button("Ask Baseline about this workout", systemImage: "sparkles") {
                    showChat = true
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BaselineColor.textMid)
                .frame(maxWidth: .infinity, minHeight: 48)
                .buttonStyle(.plain)
                .padding(.top, 18)
            }
        } else {
            VStack(spacing: 0) {
                // In an active log with a saved strap, offer a Log ↔ ♥ Live toggle (no strap → no
                // toggle, and the workout looks exactly as before).
                if mode == .log, hrMonitor != nil {
                    liveHRToggle
                }

                if showLiveHR, let monitor = hrMonitor {
                    ScrollView {
                        LiveHeartRateView(provider: monitor, targetZones: nil)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                            .padding(.bottom, 28)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            workoutHeader(workout)
                                .padding(.bottom, 18)

                            // The trace is the first thing below the title on a finished workout, and
                            // renders only when heart rate was actually measured — no placeholder, no
                            // empty state. While logging, the live HUD is the correct surface.
                            if mode == .completed, let heartRate = completedHeartRate, heartRate.trace.hasSamples {
                                BaselineCard {
                                    WorkoutHeartRateTraceChart(
                                        capture: heartRate,
                                        startedAt: store.currentLogStartedAt,
                                        finishedAt: store.currentLogFinishedAt
                                    )
                                }
                                .padding(.bottom, 18)
                            }

                            if mode == .view {
                                startButton
                                    .padding(.bottom, 22)
                            }

                            if canShareWorkout {
                                Button("Share workout", systemImage: "square.and.arrow.up", action: presentShareComposer)
                                    .buttonStyle(InstrumentOutlineButtonStyle(color: BaselineColor.textHi))
                                    .padding(.bottom, 18)
                            }

                            ForEach(workout.blocks) { block in
                                blockSection(block, blockCount: workout.blocks.count)
                            }

                            Button("Ask Baseline about this workout", systemImage: "sparkles") {
                                showChat = true
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(BaselineColor.textMid)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .buttonStyle(.plain)
                            .padding(.top, 18)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 28)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
        }
    }

    // MARK: - Live heart rate (active log)

    /// Create + start the monitor when a log is active and a strap is saved; tear it down otherwise.
    /// Idempotent, so it is safe to call from `onAppear` and every `mode` change.
    private func syncLiveMonitor() {
        guard mode == .log, bluetooth.savedDeviceID != nil else {
            stopLiveMonitor()
            return
        }
        guard hrMonitor == nil else { return }
        let monitor = HeartRateMonitor(source: bluetooth, zoneModel: heartRateZones.resolvedModel)
        // Attach before starting: `startMonitoring` resets the trace along with zone-time and the
        // session stats, so a new run can never inherit the previous one's samples. Re-entering a
        // live workout therefore restarts the trace exactly as it already restarts those aggregates —
        // one run, one consistent set of measurements, rather than a full trace beside partial zone
        // seconds.
        monitor.recorder = hrRecorder
        hrMonitor = monitor
        monitor.startMonitoring()
    }

    /// Resolve the persisted heart rate for a finished workout. Only on entering `.completed`, so the
    /// sample-array decode happens once per visit and never during logging.
    private func syncCompletedHeartRate() {
        completedHeartRate = mode == .completed ? store.loadHeartRate() : nil
    }

    private func stopLiveMonitor() {
        hrMonitor?.stopMonitoring()
        hrMonitor = nil
        showLiveHR = false
    }

    /// Keep the screen awake only while actively logging, so a user can glance at their live heart
    /// rate without the display dimming or locking. Viewing a template or the completed summary keeps
    /// normal idle behavior. Called from the same lifecycle as the live monitor; onDisappear restores it.
    private func syncKeepAwake() {
        UIApplication.shared.isIdleTimerDisabled = Self.shouldKeepScreenAwake(for: mode)
    }

    /// Pure mode→keep-awake mapping so the "only while logging" rule is testable without a view tree.
    static func shouldKeepScreenAwake(for mode: WorkoutPresentationMode) -> Bool {
        mode.isLogging
    }

    /// The segmented Log ↔ ♥ Live control. The live tab shows the current BPM once streaming, tinted
    /// with the live zone — heart rate is glanceable even from the log.
    private var liveHRToggle: some View {
        HStack(spacing: 4) {
            liveToggleButton(title: "LOG", isLive: false)
            liveToggleButton(title: hrMonitor?.currentBPM.map { "♥ \($0)" } ?? "♥ LIVE", isLive: true)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(BaselineColor.surface))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func liveToggleButton(title: String, isLive: Bool) -> some View {
        let selected = showLiveHR == isLive
        let fill: Color = !selected ? .clear
            : isLive ? (hrMonitor?.currentZone?.color ?? BaselineColor.accent) : BaselineColor.amethyst
        let fg: Color = !selected ? BaselineColor.textFaint
            : isLive ? BaselineColor.base : BaselineColor.textHi
        return Button { showLiveHR = isLive } label: {
            Text(title)
                .font(.bMono(12, .bold)).tracking(1)
                .frame(maxWidth: .infinity).frame(height: 34)
                .foregroundStyle(fg)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLive ? "Live heart rate" : "Workout log")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func workoutHeader(_ workout: Workout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workout.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(BaselineColor.textHi)
                .fixedSize(horizontal: false, vertical: true)

            if mode.usesPerformedData {
                WorkoutNotesField(
                    prompt: "Add a note here…",
                    text: sessionNotesBinding,
                    font: .body,
                    lineLimit: 2...,
                    accessibilityLabel: "Workout note"
                )
            } else if let note = workout.goal, !note.isEmpty {
                Text(note)
                    .font(.body)
                    .foregroundStyle(BaselineColor.textMid)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if mode.usesPerformedData {
                    let completed = store.currentLog?.isComplete == true
                    Label(completed ? "Completed" : "In progress",
                          systemImage: completed ? "checkmark.circle.fill" : "circle.dotted")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(completed ? BaselineColor.zoneGreen : BaselineColor.accent)
                }
                if !store.currentIsForToday, let date = workout.scheduledDate {
                    Text("Scheduled \(date.formatted(.dateTime.month().day()))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BaselineColor.zoneAmber)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }

    private var startButton: some View {
        Button { store.startWorkout() } label: {
            Label("Start Workout", systemImage: "play.fill")
                .font(.headline)
                .foregroundStyle(BaselineColor.base)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(RoundedRectangle(cornerRadius: 12).fill(BaselineColor.accent))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Creates a log while keeping this prescription unchanged")
    }

    private func blockSection(_ block: WorkoutBlock, blockCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if shouldShowHeader(for: block, blockCount: blockCount) {
                blockHeader(block)
                    .padding(.top, 16)
                    .padding(.bottom, 10)
            }

            StructuredWorkoutBlockView(block: block, mode: mode)

            if block.nodes.isEmpty {
                Text("No exercises yet.")
                    .font(.subheadline)
                    .foregroundStyle(BaselineColor.textFaint)
                    .padding(.vertical, 16)
            }

            // Adding mid-workout is a first-class move, not an edit-mode-only affordance: the athlete
            // decides to do extra work far more often than they sit down to redraft a template.
            if mode == .log {
                Button {
                    addExerciseRequest = AddExerciseRequest(id: block.id)
                } label: {
                    Label("Add Exercise", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BaselineColor.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(BaselineColor.surface))
                }
                .buttonStyle(.plain)
                .padding(.vertical, 10)
                .accessibilityHint("Adds an exercise to this workout without changing your saved plan")
            }
        }
    }

    private func blockHeader(_ block: WorkoutBlock) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(block.name.isEmpty ? "Main" : block.name)
                .font(.title3.weight(.bold))
                .foregroundStyle(BaselineColor.textHi)
            if let intent = WorkoutPresentationFormatter.blockIntent(
                name: block.name,
                intent: block.intent
            ) {
                Text(intent)
                    .font(.subheadline)
                    .foregroundStyle(BaselineColor.textMid)
            }
        }
    }

    private func shouldShowHeader(for block: WorkoutBlock, blockCount: Int) -> Bool {
        blockCount > 1 || !block.isDefault || !block.name.isEmpty || !(block.intent?.isEmpty ?? true)
    }

    // MARK: - Editing

    private func beginEditing() {
        guard store.currentLog == nil, let workout = store.current else { return }
        editSnapshot = workout
        isEditingTemplate = true
    }

    private func cancelEditing() {
        if let snapshot = editSnapshot {
            store.edit(.plan) { $0 = snapshot }
            store.flush()
        }
        editSnapshot = nil
        isEditingTemplate = false
    }

    /// The one workout-level note during and after a session — the only workout-level text surface here,
    /// so nothing appears or disappears around it as the athlete types. Until the field has been edited
    /// it shows the plan's own note; the first edit adopts whatever is on screen into the log, which is
    /// the athlete's action rather than a seed `startLog` wrote. From then on it is exactly the performed
    /// note, independent of later plan changes, and clearing it leaves it cleared. The workout level has
    /// no `CoachGuidance` for this field to compete with; guidance starts at the block and the exercise.
    private var sessionNotesBinding: Binding<String> {
        Binding(
            get: {
                guard store.currentLog?.hasAuthoredNotes == true else { return store.current?.goal ?? "" }
                return store.currentLog?.notesText ?? ""
            },
            set: { value in
                store.editLog { $0.setNotes(value) }
            }
        )
    }

    private func finishEditing() {
        store.flush()
        editSnapshot = nil
        isEditingTemplate = false
    }

    // MARK: - Completing

    /// Finish the session, then offer to promote whatever the athlete changed back to the saved plan.
    /// The reconciliation is captured *before* completing so the summary describes the session that was
    /// actually performed, and so declining leaves the plan untouched with no further bookkeeping.
    private func finishWorkout() {
        // Read the monitor while it is still alive: completing flips `mode` to `.completed`, which
        // tears it down along with every zone-second it accumulated.
        let heartRate = hrMonitor.flatMap {
            WorkoutHeartRateCapture(recorder: hrRecorder, monitor: $0)
        }
        finishing.finish(store, heartRate: heartRate)
    }

    // MARK: - Templates

    private func beginSaveTemplate() {
        templateName = store.current?.title ?? "New template"
        showSaveTemplate = true
    }

    private func saveTemplate() {
        let name = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let workout = store.current else { return }
        if let existing = plan.template(named: name) {
            templateConflict = existing
        } else {
            plan.saveAsTemplate(name: name, from: workout)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.largeTitle)
                .foregroundStyle(BaselineColor.textFaint)
            Text("No workout yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(BaselineColor.textHi)
            Text("Create one by hand or import a workout to turn it into a loggable template.")
                .font(.body)
                .foregroundStyle(BaselineColor.textMid)
                .multilineTextAlignment(.center)
            Button("New Workout") { store.create(title: "Today's workout", goal: nil) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button {
                showChat = true
            } label: {
                Label("Talk to Baseline", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(BaselineColor.accent)
            Spacer()
            Spacer()
        }
        .padding(24)
    }

    private struct AddExerciseRequest: Identifiable {
        let id: UUID
    }
}

#Preview {
    let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
    let container = try! ModelContainer(
        for: Schema(models),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return WorkoutView()
        .environment(WorkoutStore(units: AppSettings(), defaults: UserDefaults(suiteName: "preview")!))
        .environment(PlanStore(context: container.mainContext))
        .environment(BluetoothManager())
        .environment(OnboardingStore())
        .environment(HeartRateZoneSettingsStore(defaults: .previewEmpty, ageYears: { 28 }))
}
