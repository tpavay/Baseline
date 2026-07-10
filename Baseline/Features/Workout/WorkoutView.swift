import SwiftUI

/// The manual workout screen — the **ground-truth UI** for the structured workout the agent edits.
/// Narrow on purpose: expandable blocks → exercises → prescriptions, structure edits (add / remove /
/// move / substitute), manual set logging, skip / complete, notes, and a persistent chat entry.
/// Everything here drives the same `WorkoutStore` the conversation does, so any mutation is
/// inspectable and correctable by hand. No charts / PRs / calendar / voice yet.
struct WorkoutView: View {
    @Environment(WorkoutStore.self) private var store
    @State private var expandedBlocks: Set<UUID> = []
    @State private var expandedExercises: Set<UUID> = []
    @State private var sheet: WorkoutSheet?
    @State private var showChat = false

    private var executing: Bool { store.currentLog != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                if let workout = store.current {
                    content(workout)
                } else {
                    emptyState
                }
                chatBar
            }
            .navigationTitle("Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbar { toolbar }
        }
        .sheet(item: $sheet) { sheetView($0) }
        .sheet(isPresented: $showChat) { AskBaselineSheet() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if store.current != nil {
                Menu {
                    Button { addBlock() } label: { Label("Add block", systemImage: "plus.rectangle.on.rectangle") }
                    if !executing {
                        Button { store.startWorkout() } label: { Label("Start workout", systemImage: "play.fill") }
                    } else if store.currentLog?.isComplete == false {
                        Button { store.completeWorkout() } label: { Label("Complete workout", systemImage: "checkmark.circle") }
                    }
                    Button(role: .destructive) { store.discardLog() } label: { Label("Discard log", systemImage: "trash") }
                        .disabled(!executing)
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(BaselineColor.accent) }
            }
        }
    }

    // MARK: - Content

    private func content(_ workout: Workout) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(workout)
                ForEach(workout.blocks) { block in blockCard(block) }
                Button { addBlock() } label: {
                    Label("Add block", systemImage: "plus").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(BaselineColor.accent).frame(maxWidth: .infinity).frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 14).strokeBorder(BaselineColor.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Color.clear.frame(height: 72)   // clear the chat bar
            }
            .padding(16)
        }
    }

    private func header(_ workout: Workout) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(workout.title).font(.system(size: 22, weight: .bold)).foregroundStyle(BaselineColor.textHi)
            if let goal = workout.goal {
                Text(goal).font(.system(size: 14)).foregroundStyle(BaselineColor.textMid)
            }
            HStack(spacing: 8) {
                if executing {
                    let done = store.currentLog?.isComplete == true
                    Text(done ? "COMPLETED" : "IN PROGRESS")
                        .font(.system(size: 11, weight: .bold)).tracking(0.6)
                        .foregroundStyle(done ? BaselineColor.zoneGreen : BaselineColor.accent)
                }
                if !store.currentIsForToday, let d = workout.scheduledDate {
                    Text("FROM \(d.formatted(.dateTime.month().day()).uppercased()) — NOT TODAY")
                        .font(.system(size: 11, weight: .bold)).tracking(0.4).foregroundStyle(BaselineColor.zoneAmber)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Block

    private func blockCard(_ block: WorkoutBlock) -> some View {
        let expanded = expandedBlocks.contains(block.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { toggle(&expandedBlocks, block.id) } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(BaselineColor.textFaint).frame(width: 18)
                }.buttonStyle(.plain)
                // Inline rename — no modal, autosaves.
                TextField("", text: blockNameBinding(block), prompt: Text("Block").foregroundStyle(BaselineColor.textFaint))
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(BaselineColor.textHi)
                Spacer()
                Menu {
                    Button { addExercise(to: block.id) } label: { Label("Add exercise", systemImage: "plus") }
                    Button(role: .destructive) { store.edit { $0.removeBlock(block.id) } } label: { Label("Delete block", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis").font(.system(size: 14)).foregroundStyle(BaselineColor.textFaint).padding(6) }
            }
            if expanded {
                if block.exercises.isEmpty {
                    Text("No exercises yet").font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint).padding(.top, 8)
                }
                ForEach(block.exercises) { ex in exerciseRow(ex, in: block) }
                Button { addExercise(to: block.id) } label: {
                    Label("Add exercise", systemImage: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(BaselineColor.accent)
                }
                .buttonStyle(.plain).padding(.top, 8)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(BaselineColor.surface))
    }

    // MARK: - Exercise

    private func exerciseRow(_ ex: PlannedExercise, in block: WorkoutBlock) -> some View {
        let expanded = expandedExercises.contains(ex.id)
        let performed = store.currentLog?.performed(forPlanned: ex.id)
        return VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(BaselineColor.line)
            HStack {
                Button { toggle(&expandedExercises, ex.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(ex.exerciseName).font(.system(size: 15, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                            statusChip(performed?.status)
                        }
                        Text(prescriptionLine(ex)).font(.system(size: 12)).foregroundStyle(BaselineColor.textMid)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                exerciseMenu(ex, in: block)
            }
            if expanded { exerciseDetail(ex, performed: performed) }
        }
    }

    @ViewBuilder private func exerciseDetail(_ ex: PlannedExercise, performed: PerformedExercise?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if executing {
                // Read-only plan while logging actuals.
                ForEach(Array(ex.prescription.sets.enumerated()), id: \.element.id) { i, s in
                    Text("Set \(i + 1): \(metricText(s.values, for: ex))").font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint)
                }
            } else {
                // Inline-editable sets — tap a value and type; autosaves.
                ForEach(Array(ex.prescription.sets.enumerated()), id: \.element.id) { i, s in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(BaselineColor.textFaint).frame(width: 14)
                        ForEach(ex.selectedMetrics, id: \.self) { metric in inlineField(ex, s.id, metric) }
                        Spacer()
                        if ex.prescription.sets.count > 1 {
                            Button { deleteSet(s.id, from: ex) } label: {
                                Image(systemName: "minus.circle").font(.system(size: 14)).foregroundStyle(BaselineColor.textFaint)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                HStack {
                    Button { addSet(to: ex) } label: {
                        Label("Add set", systemImage: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(BaselineColor.accent)
                    }.buttonStyle(.plain)
                    Spacer()
                    let unused = ex.supportedMetrics.filter { !ex.selectedMetrics.contains($0) }
                    if !unused.isEmpty {
                        Menu {
                            ForEach(unused, id: \.self) { m in Button(m.label) { addMetric(m, to: ex) } }
                        } label: { Text("Add metric").font(.system(size: 12, weight: .medium)).foregroundStyle(BaselineColor.textFaint) }
                    }
                }
            }
            if executing {
                // Logged sets
                if let logs = performed?.setLogs, !logs.isEmpty {
                    Text("LOGGED").font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(BaselineColor.zoneGreen)
                    ForEach(Array(logs.enumerated()), id: \.element.id) { i, s in
                        HStack {
                            Text("• \(metricText(s.values, for: ex))").font(.system(size: 13)).foregroundStyle(BaselineColor.textHi)
                            Spacer()
                            Button { store.editLog { $0.removeSetLog(s.id) } } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button { sheet = .logSet(exerciseID: ex.id, name: ex.exerciseName) } label: {
                        Label("Log set", systemImage: "plus.circle.fill").font(.system(size: 13, weight: .semibold))
                    }.buttonStyle(.plain).foregroundStyle(BaselineColor.accent)
                    Spacer()
                    Button { store.editLog { $0.setStatus(.completed, forPlanned: ex.id, name: ex.exerciseName) } } label: {
                        Text("Complete").font(.system(size: 12, weight: .semibold)).foregroundStyle(BaselineColor.zoneGreen)
                    }.buttonStyle(.plain)
                    Button { store.editLog { $0.setStatus(.skipped, forPlanned: ex.id, name: ex.exerciseName) } } label: {
                        Text("Skip").font(.system(size: 12, weight: .semibold)).foregroundStyle(BaselineColor.zoneAmber)
                    }.buttonStyle(.plain)
                }
                noteField(ex, performed: performed)
            }
        }
        .padding(.leading, 4).padding(.top, 2)
    }

    private func noteField(_ ex: PlannedExercise, performed: PerformedExercise?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(performed?.athleteNotes ?? [], id: \.self) { n in
                Text("“\(n)”").font(.system(size: 12)).italic().foregroundStyle(BaselineColor.textMid)
            }
            NoteEntry { note in store.editLog { $0.addNote(note, forPlanned: ex.id, name: ex.exerciseName) } }
        }
    }

    private func exerciseMenu(_ ex: PlannedExercise, in block: WorkoutBlock) -> some View {
        Menu {
            Button { sheet = .configure(exerciseID: ex.id, name: ex.exerciseName) } label: { Label("Configure metrics", systemImage: "slider.horizontal.3") }
            Button { sheet = .substitute(exerciseID: ex.id, current: ex.exerciseName) } label: { Label("Substitute", systemImage: "arrow.triangle.2.circlepath") }
            Menu {
                ForEach(otherBlocks(than: block.id)) { b in
                    Button(b.name) { store.edit { $0.moveExercise(ex.id, toBlock: b.id) } }
                }
            } label: { Label("Move to block", systemImage: "arrow.right") }
            Button { reorder(ex, in: block, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
            Button { reorder(ex, in: block, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
            Button(role: .destructive) { store.edit { $0.removeExercise(ex.id) } } label: { Label("Remove", systemImage: "trash") }
        } label: { Image(systemName: "ellipsis").font(.system(size: 14)).foregroundStyle(BaselineColor.textFaint).padding(6) }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "figure.strengthtraining.traditional").font(.system(size: 40)).foregroundStyle(BaselineColor.textFaint)
            Text("No workout yet").font(.system(size: 18, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
            Text("Build one by hand, or ask Baseline to make one.").font(.system(size: 14)).foregroundStyle(BaselineColor.textMid)
                .multilineTextAlignment(.center)
            Button { store.create(title: "Today's workout", goal: nil); addBlock() } label: {
                Text("New workout").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(hex: 0x120B21))
                    .frame(width: 200, height: 50).background(RoundedRectangle(cornerRadius: 14).fill(BaselineColor.accent))
            }.buttonStyle(.plain)
            Spacer(); Spacer()
        }
        .padding(24)
    }

    private var chatBar: some View {
        VStack {
            Spacer()
            Button { showChat = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.system(size: 15))
                    Text("Talk to Baseline").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Image(systemName: "mic.fill").font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint)
                }
                .foregroundStyle(BaselineColor.textHi)
                .padding(.horizontal, 16).frame(height: 50)
                .background(Capsule().fill(BaselineColor.surface).overlay(Capsule().strokeBorder(BaselineColor.accent.opacity(0.35), lineWidth: 1)))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    // MARK: - Sheets

    @ViewBuilder private func sheetView(_ sheet: WorkoutSheet) -> some View {
        switch sheet {
        case .addExercise(let blockID):
            if let target = blockID ?? store.current?.blocks.first?.id {
                AddExerciseFlow(blockID: target) { newID in     // catalog-first, direct insert
                    expandedBlocks.insert(target)
                    expandedExercises.insert(newID)
                }
            } else {
                Text("Add a block first.").font(.system(size: 15)).foregroundStyle(BaselineColor.textMid).padding(40)
            }
        case .substitute(let id, let current):
            SubstituteSheet(currentName: current) { name, prescription in
                store.edit { $0.substituteExercise(id, withName: name, prescription: prescription) }
            }
        case .logSet(let id, let name):
            let ex = store.current?.exercise(id)
            let fields = (ex?.selectedMetrics ?? [.reps, .load]).map { ($0, store.displayUnit($0, for: ex ?? .init(exerciseName: name))) }
            MetricLogSheet(title: "Log \(name)", fields: fields) { values in
                store.editLog { $0.logSet(SetLog(values: values), forPlanned: id, name: name) }
            }
        case .configure(let id, let name):
            if let ex = store.current?.exercise(id) {
                MetricConfigSheet(exercise: ex, unitFor: { store.displayUnit($0, for: ex) }) { enabled, units in
                    store.setLoggingConfig(exerciseNamed: name, enabled: enabled, units: units)
                }
            }
        }
    }

    // MARK: - Direct manipulation (no forms, no save — autosaves via the store)

    private func addBlock() {
        let n = (store.current?.blocks.count ?? 0) + 1
        store.edit { $0.addBlock(name: "Block \(n)") }
        if let id = store.current?.blocks.last?.id { expandedBlocks.insert(id) }
    }

    private func addExercise(to blockID: UUID) { sheet = .addExercise(blockID: blockID) }

    private func blockNameBinding(_ block: WorkoutBlock) -> Binding<String> {
        Binding(get: { store.current?.blocks.first { $0.id == block.id }?.name ?? block.name },
                set: { new in store.edit { $0.renameBlock(block.id, to: new) } })
    }

    /// "+ Set" copies the last set's structure + values (like duplicating a row) — only the values
    /// then need changing.
    private func addSet(to ex: PlannedExercise) {
        store.edit { w in
            w.updateExercise(ex.id) { e in
                var copy = e.prescription.sets.last ?? PlannedSet()
                copy.id = UUID()
                e.prescription.sets.append(copy)
            }
        }
    }

    private func deleteSet(_ setID: UUID, from ex: PlannedExercise) {
        store.edit { $0.updateExercise(ex.id) { $0.prescription.sets.removeAll { $0.id == setID } } }
    }

    /// Inline-editable value for one metric of one set, in the exercise's display unit — canonical on
    /// store. Duration reads/writes as m:ss.
    private func valueBinding(_ ex: PlannedExercise, _ setID: UUID, _ metric: MetricType) -> Binding<String> {
        let unit = store.displayUnit(metric, for: ex)
        return Binding(
            get: {
                guard let v = store.current?.exercise(ex.id)?.prescription.sets.first(where: { $0.id == setID })?.values[metric] else { return "" }
                if metric == .duration { return mmss(Int(v)) }
                let d = MetricConvert.fromCanonical(v, metric, to: unit)
                return d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
            },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                store.edit { w in
                    w.updateExercise(ex.id) { e in
                        guard let i = e.prescription.sets.firstIndex(where: { $0.id == setID }) else { return }
                        if trimmed.isEmpty { e.prescription.sets[i].values[metric] = nil }
                        else if metric == .duration { e.prescription.sets[i].values[.duration] = Double(parseMMSS(trimmed)) }
                        else if let d = Double(trimmed) { e.prescription.sets[i].values[metric] = max(0, MetricConvert.toCanonical(d, metric, from: unit)) }
                    }
                }
            }
        )
    }

    private func mmss(_ seconds: Int) -> String { seconds >= 60 ? "\(seconds / 60):\(String(format: "%02d", seconds % 60))" : "\(seconds)" }
    private func parseMMSS(_ s: String) -> Int {
        if s.contains(":") { let p = s.split(separator: ":").map { Int($0) ?? 0 }; return p.count == 2 ? p[0] * 60 + p[1] : (p.first ?? 0) }
        return Int(s) ?? 0
    }

    private func inlineField(_ ex: PlannedExercise, _ setID: UUID, _ metric: MetricType) -> some View {
        let unit = store.displayUnit(metric, for: ex)
        let unitLabel = metric == .duration ? "m:ss" : (unit.short.isEmpty ? metric.label.lowercased() : unit.short)
        return VStack(spacing: 1) {
            TextField("", text: valueBinding(ex, setID, metric))
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                .multilineTextAlignment(.center)
                .keyboardType(metric == .duration ? .numbersAndPunctuation : (metric.isInteger ? .numberPad : .decimalPad))
                .frame(width: 52).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(BaselineColor.base).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(BaselineColor.line, lineWidth: 1)))
            Text(unitLabel).font(.system(size: 9)).foregroundStyle(BaselineColor.textFaint)
        }
    }

    private func addMetric(_ metric: MetricType, to ex: PlannedExercise) {
        store.edit { $0.updateExercise(ex.id) { e in
            var s = Set(e.selectedMetrics); s.insert(metric)
            e.selectedMetrics = MetricType.allCases.filter { s.contains($0) }
        }}
    }

    // MARK: - Helpers

    private func toggle(_ set: inout Set<UUID>, _ id: UUID) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func otherBlocks(than id: UUID) -> [WorkoutBlock] {
        (store.current?.blocks ?? []).filter { $0.id != id }
    }

    private func reorder(_ ex: PlannedExercise, in block: WorkoutBlock, by delta: Int) {
        guard let idx = block.exercises.firstIndex(where: { $0.id == ex.id }) else { return }
        store.edit { $0.reorderExercise(ex.id, to: idx + delta) }
    }

    @ViewBuilder private func statusChip(_ status: PerformedStatus?) -> some View {
        if let status, status != .pending {
            let (label, color): (String, Color) = switch status {
            case .completed: ("done", BaselineColor.zoneGreen)
            case .skipped: ("skipped", BaselineColor.zoneAmber)
            case .substituted: ("subbed", BaselineColor.accent)
            case .modified: ("modified", BaselineColor.accent)
            case .pending: ("", BaselineColor.textFaint)
            }
            Text(label.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.4).foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.15)))
        }
    }

    private func prescriptionLine(_ ex: PlannedExercise) -> String {
        guard let first = ex.prescription.sets.first else { return "no sets" }
        let body = metricText(first.values, for: ex)
        return "\(ex.prescription.sets.count)× " + (body == "—" ? ex.selectedMetrics.map(\.label).joined(separator: " · ").lowercased() : body)
    }

    /// Render a set's values in each metric's display unit (per this exercise's prefs). Only metrics
    /// that actually have a value show — no blank fields.
    private func metricText(_ values: MetricValues, for ex: PlannedExercise) -> String {
        let parts = values.present.map { metric -> String in
            let unit = store.displayUnit(metric, for: ex)
            return format(MetricConvert.fromCanonical(values[metric]!, metric, to: unit), metric, unit)
        }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }

    private func format(_ value: Double, _ metric: MetricType, _ unit: MetricUnit) -> String {
        let num = (metric.isInteger || value == value.rounded()) ? String(Int(value.rounded())) : String(format: "%.1f", value)
        return unit.short.isEmpty ? "\(num) \(metric.label.lowercased())" : "\(num) \(unit.short)"
    }
}

private enum WorkoutSheet: Identifiable {
    case addExercise(blockID: UUID?)
    case substitute(exerciseID: UUID, current: String)
    case logSet(exerciseID: UUID, name: String)
    case configure(exerciseID: UUID, name: String)

    var id: String {
        switch self {
        case .configure(let id, _): "config-\(id)"
        case .addExercise(let b): "addExercise-\(b?.uuidString ?? "none")"
        case .substitute(let id, _): "sub-\(id)"
        case .logSet(let id, _): "log-\(id)"
        }
    }
}

/// Inline note entry — submit to append an athlete note.
private struct NoteEntry: View {
    let onSubmit: (String) -> Void
    @State private var text = ""
    var body: some View {
        HStack {
            TextField("", text: $text, prompt: Text("Add a note…").foregroundStyle(BaselineColor.textFaint))
                .font(.system(size: 13)).foregroundStyle(BaselineColor.textHi)
                .onSubmit(submit)
            if !text.isEmpty { Button("Add", action: submit).font(.system(size: 12, weight: .semibold)).foregroundStyle(BaselineColor.accent) }
        }
    }
    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onSubmit(t); text = ""
    }
}

#Preview {
    WorkoutView().environment(WorkoutStore(defaults: UserDefaults(suiteName: "preview")!))
}
