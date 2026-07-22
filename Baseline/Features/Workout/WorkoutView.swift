import SwiftData
import SwiftUI
import UIKit

/// The manual surface for a workout template and its performed log. The hierarchy stays visually
/// stable across reading, editing, and logging; only the controls inside each row change.
struct WorkoutView: View {
    /// When present, the workout is a scheduled plan session and the ••• menu offers a destructive
    /// "Remove Workout" that hands removal back to the presenter (Plan). Absent for standalone use.
    var onRequestDelete: (() -> Void)?

    /// True only when hosted as the Train tab inside the floating-tab-bar shell; sheet presentations
    /// from Plan leave it off so no phantom bottom inset appears there.
    var showsFloatingTabBarClearance = false

    @Environment(WorkoutStore.self) private var store
    @Environment(PlanStore.self) private var plan
    @Environment(BluetoothManager.self) private var bluetooth
    @Environment(OnboardingStore.self) private var profile
    @Environment(\.dismiss) private var dismiss

    @State private var isEditingTemplate = false
    @State private var editSnapshot: Workout?
    @State private var showChat = false
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
            .floatingTabBarClearance(showsFloatingTabBarClearance)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbar { workoutToolbar }
        }
        .tint(BaselineColor.accent)
        .sheet(isPresented: $showChat) { AskBaselineSheet(surface: .workout) }
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
        .alert("Discard this log?", isPresented: $showDiscardConfirmation) {
            Button("Discard Log", role: .destructive) { store.discardLog() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything you logged will be removed, along with any exercises you added, removed, replaced, or reordered during this workout. Your saved plan stays as it was.")
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
        }
        .onChange(of: mode) { _, _ in
            syncLiveMonitor()
            syncKeepAwake()
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
                            Label("Discard Log", systemImage: "trash")
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

                            if mode == .view {
                                startButton
                                    .padding(.bottom, 22)
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
        let settings = HeartRateZoneSettingsStore(ageYears: { [profile] in profile.draft.ageYears })
        let model = settings.model ?? HeartRateZoneModel(age: profile.draft.ageYears)
        let monitor = HeartRateMonitor(source: bluetooth, zoneModel: model)
        hrMonitor = monitor
        monitor.startMonitoring()
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

            if let goal = workout.goal, !goal.isEmpty {
                Text(goal)
                    .font(.body)
                    .foregroundStyle(BaselineColor.textMid)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let guidance = workout.guidance {
                WorkoutInstructionText(lines: [guidance.goal].compactMap { $0 } + guidance.formCues)
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
            if let guidance = block.guidance {
                WorkoutInstructionText(lines: [guidance.goal].compactMap { $0 } + guidance.formCues)
            }
        }
    }

    private func shouldShowHeader(for block: WorkoutBlock, blockCount: Int) -> Bool {
        blockCount > 1 || !block.isDefault || !block.name.isEmpty || !(block.intent?.isEmpty ?? true)
            || block.guidance != nil
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
        finishing.finish(store)
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
}
