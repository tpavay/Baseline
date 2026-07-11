import SwiftUI

/// The manual workout screen — the **ground-truth UI** for the structured workout the agent edits.
/// Narrow on purpose: expandable blocks → exercises → prescriptions, structure edits (add / remove /
/// move / substitute), manual set logging, skip / complete, notes, and a persistent chat entry.
/// Everything here drives the same `WorkoutStore` the conversation does, so any mutation is
/// inspectable and correctable by hand. No charts / PRs / calendar / voice yet.
struct WorkoutView: View {
    @Environment(WorkoutStore.self) private var store
    @State private var collapsedBlocks: Set<UUID> = []       // blocks expanded by default
    @State private var expandedExercises: Set<UUID> = []     // exercises collapsed by default
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
            LazyVStack(alignment: .leading, spacing: 0) {
                header(workout).padding(.bottom, 6)
                if isFlat(workout), let def = workout.blocks.first {
                    // Flat, Hevy-style: exercises are light rows separated by whitespace — no cards.
                    ForEach(def.exercises) { ex in exerciseRow(ex, in: def) }
                    if def.exercises.isEmpty {
                        Text("No exercises yet — add one to get started.").font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint).padding(.vertical, 12)
                    }
                    addRowButton("Add exercise") { addExercise(to: def.id) }
                    addRowButton("Add block") { addBlock() }
                } else {
                    ForEach(workout.blocks) { block in blockSection(block) }
                    addRowButton("Add block") { addBlock() }
                }
                Color.clear.frame(height: 80)   // clear the chat bar
            }
            .padding(.horizontal, 16)
        }
    }

    /// A workout reads flat while it has only the default block with no name or goal.
    private func isFlat(_ w: Workout) -> Bool {
        guard w.blocks.count == 1, let b = w.blocks.first, b.isDefault else { return false }
        return b.name.trimmingCharacters(in: .whitespaces).isEmpty
            && (b.intent?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
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

    // MARK: - Block (lightweight section header, Apple-Notes style — not a card)

    private func blockSection(_ block: WorkoutBlock) -> some View {
        let expanded = !collapsedBlocks.contains(block.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { toggle(&collapsedBlocks, block.id) } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(BaselineColor.textFaint).frame(width: 14)
                }.buttonStyle(.plain)
                TextField("", text: blockNameBinding(block), prompt: Text(block.isDefault ? "Main" : "Block").foregroundStyle(BaselineColor.textFaint))
                    .font(.system(size: 12, weight: .bold)).tracking(0.6).foregroundStyle(BaselineColor.textMid)
                if let g = block.intent, !g.isEmpty { Text(g).font(.system(size: 11)).foregroundStyle(BaselineColor.textFaint) }
                Spacer()
                Menu {
                    TextField("Goal", text: blockGoalBinding(block))
                    Button { addExercise(to: block.id) } label: { Label("Add exercise", systemImage: "plus") }
                    Button { store.edit { $0.duplicateBlock(block.id) } } label: { Label("Duplicate block", systemImage: "plus.square.on.square") }
                    Button(role: .destructive) {
                        store.edit { w in
                            w.removeBlock(block.id)
                            if w.blocks.isEmpty { w.blocks.append(WorkoutBlock(name: "", isDefault: true)) }  // always ≥1 block
                        }
                    } label: { Label("Delete block", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis").font(.system(size: 15)).foregroundStyle(BaselineColor.textFaint).padding(6) }
            }
            .padding(.top, 16).padding(.bottom, 6)
            Rectangle().fill(BaselineColor.line).frame(height: 1)
            if expanded {
                ForEach(block.exercises) { ex in exerciseRow(ex, in: block) }
                addRowButton("Add exercise") { addExercise(to: block.id) }
            }
        }
    }

    // MARK: - Exercise (light row → expands to a logging table)

    private func exerciseRow(_ ex: PlannedExercise, in block: WorkoutBlock) -> some View {
        let expanded = expandedExercises.contains(ex.id)
        let performed = store.currentLog?.performed(forPlanned: ex.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { toggle(&expandedExercises, ex.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(BaselineColor.textFaint).frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(ex.exerciseName).font(.system(size: 15, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                                statusChip(performed?.status)
                            }
                            if !expanded { Text(prescriptionLine(ex)).font(.system(size: 12)).foregroundStyle(BaselineColor.textMid) }
                        }
                    }
                }.buttonStyle(.plain)
                Spacer()
                exerciseMenu(ex, in: block)
            }
            .padding(.vertical, 11)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    setTable(ex, performed: performed)
                    Button { addSet(to: ex) } label: {
                        Label("Add set", systemImage: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(BaselineColor.accent)
                            .frame(maxWidth: .infinity).frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 9).fill(BaselineColor.surface))
                    }.buttonStyle(.plain)
                    if !executing {
                        let unused = ex.supportedMetrics.filter { !ex.selectedMetrics.contains($0) }
                        if !unused.isEmpty {
                            Menu { ForEach(unused, id: \.self) { m in Button(m.label) { addMetric(m, to: ex) } } }
                            label: { Label("Add metric", systemImage: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(BaselineColor.textFaint) }
                        }
                    }
                    if executing { noteField(ex, performed: performed) }
                }
                .padding(.leading, 22).padding(.bottom, 10)
            }
            Rectangle().fill(BaselineColor.line).frame(height: 1)   // whitespace-thin separator between rows
        }
    }

    /// Sets as a dense table — metric headers once, values in aligned columns. Two reads of the same
    /// table: **planning** edits the prescription; **training** edits the actual into pre-filled cells
    /// (the plan value is the placeholder) and checks each row off. No planned-vs-actual columns —
    /// they're separated by mode, not by column.
    @ViewBuilder private func setTable(_ ex: PlannedExercise, performed: PerformedExercise?) -> some View {
        let metrics = ex.selectedMetrics
        let activeIdx = executing ? ex.prescription.sets.firstIndex(where: { !setComplete(performed, $0.id) }) : nil
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("#").font(.system(size: 10, weight: .bold)).foregroundStyle(BaselineColor.textFaint).gridColumnAlignment(.center)
                ForEach(metrics, id: \.self) { m in
                    Text(columnHeader(m, for: ex)).font(.system(size: 10, weight: .bold)).tracking(0.3).foregroundStyle(BaselineColor.textFaint)
                }
                if executing {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(BaselineColor.textFaint).gridColumnAlignment(.center)
                } else {
                    Color.clear.frame(width: 16)
                }
            }
            ForEach(Array(ex.prescription.sets.enumerated()), id: \.element.id) { i, s in
                let done = executing && setComplete(performed, s.id)
                let active = executing && i == activeIdx
                GridRow {
                    Text("\(i + 1)").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(done ? BaselineColor.textFaint : (active ? BaselineColor.accent : BaselineColor.textMid))
                        .gridColumnAlignment(.center)
                    ForEach(metrics, id: \.self) { m in
                        if executing {
                            TextField(cellText(s.values, m, for: ex), text: logValueBinding(ex, s, m))
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(done ? BaselineColor.textFaint : BaselineColor.textHi)
                                .keyboardType(m == .duration ? .numbersAndPunctuation : (m.isInteger ? .numberPad : .decimalPad))
                                .frame(width: 52)
                        } else {
                            TextField("—", text: valueBinding(ex, s.id, m))
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                                .keyboardType(m == .duration ? .numbersAndPunctuation : (m.isInteger ? .numberPad : .decimalPad))
                                .frame(width: 52)
                        }
                    }
                    if executing {
                        Button { toggleComplete(ex, s) } label: {
                            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18)).foregroundStyle(done ? BaselineColor.zoneGreen : BaselineColor.textFaint)
                        }.buttonStyle(.plain).gridColumnAlignment(.center)
                    } else {
                        Menu {
                            Button { duplicateSet(s.id, in: ex) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                            Button(role: .destructive) { deleteSet(s.id, from: ex) } label: { Label("Delete", systemImage: "trash") }
                        } label: { Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint) }
                    }
                }
            }
        }
    }

    private func setComplete(_ performed: PerformedExercise?, _ setID: UUID) -> Bool {
        performed?.setLogs.first { $0.plannedSetID == setID }?.completed ?? false
    }

    private func columnHeader(_ m: MetricType, for ex: PlannedExercise) -> String {
        let u = store.displayUnit(m, for: ex)
        switch m {
        case .duration: return "TIME"
        case .distance, .load: return u.short.uppercased()
        default: return m.label.uppercased()
        }
    }

    private func cellText(_ values: MetricValues, _ m: MetricType, for ex: PlannedExercise) -> String {
        guard let v = values[m] else { return "—" }
        if m == .duration { return mmss(Int(v)) }
        let d = MetricConvert.fromCanonical(v, m, to: store.displayUnit(m, for: ex))
        return d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
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
            Button { sheet = .configure(exerciseID: ex.id, name: ex.exerciseName, focus: .metrics) } label: { Label("Metrics", systemImage: "slider.horizontal.3") }
            Button { sheet = .configure(exerciseID: ex.id, name: ex.exerciseName, focus: .units) } label: { Label("Units", systemImage: "ruler") }
            Button { sheet = .substitute(exerciseID: ex.id, current: ex.exerciseName) } label: { Label("Replace", systemImage: "arrow.triangle.2.circlepath") }
            Menu {
                ForEach(otherBlocks(than: block.id)) { b in
                    Button(b.name.isEmpty ? "Main" : b.name) { store.edit { $0.moveExercise(ex.id, toBlock: b.id) } }
                }
                Button { reorder(ex, in: block, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
                Button { reorder(ex, in: block, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
            } label: { Label("Move", systemImage: "arrow.up.arrow.down") }
            Button { duplicateExercise(ex, in: block) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            if executing {
                Button { store.editLog { $0.setStatus(.skipped, forPlanned: ex.id, name: ex.exerciseName) } } label: { Label("Skip exercise", systemImage: "forward.end") }
            }
            Button(role: .destructive) { store.edit { $0.removeExercise(ex.id) } } label: { Label("Delete", systemImage: "trash") }
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
            Button { store.create(title: "Today's workout", goal: nil) } label: {
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
                AddExerciseFlow(blockID: target) { newIDs in    // catalog-first, multi-select insert
                    if newIDs.count == 1, let only = newIDs.first { expandedExercises.insert(only) }
                }
            } else {
                Text("Add a block first.").font(.system(size: 15)).foregroundStyle(BaselineColor.textMid).padding(40)
            }
        case .substitute(let id, let current):
            SubstituteSheet(currentName: current) { name, prescription in
                store.edit { $0.substituteExercise(id, withName: name, prescription: prescription) }
            }
        case .configure(let id, let name, let focus):
            if let ex = store.current?.exercise(id) {
                MetricConfigSheet(exercise: ex, focus: focus, unitFor: { store.displayUnit($0, for: ex) }) { enabled, units in
                    store.setLoggingConfig(exerciseNamed: name, enabled: enabled, units: units)
                }
            }
        }
    }

    // MARK: - Direct manipulation (no forms, no save — autosaves via the store)

    private func addBlock() {
        // Empty-named, inline-renamable — revealing structure turns the default into "Main" and this
        // new block prompts for a name. Blocks are expanded by default.
        store.edit { $0.addBlock(name: "") }
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

    /// Training-mode cell: reads/writes the *actual* for one metric of one set (canonical on the log,
    /// shown in the exercise's display unit). Empty until edited — the plan value is the placeholder.
    private func logValueBinding(_ ex: PlannedExercise, _ set: PlannedSet, _ metric: MetricType) -> Binding<String> {
        let unit = store.displayUnit(metric, for: ex)
        return Binding(
            get: {
                guard let v = store.currentLog?.setLog(forPlanned: ex.id, plannedSetID: set.id)?.values[metric] else { return "" }
                if metric == .duration { return mmss(Int(v)) }
                let d = MetricConvert.fromCanonical(v, metric, to: unit)
                return d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
            },
            set: { text in
                let t = text.trimmingCharacters(in: .whitespaces)
                store.editLog { log in
                    log.upsertSetLog(forPlanned: ex.id, name: ex.exerciseName, plannedSetID: set.id) { s in
                        if t.isEmpty { s.values[metric] = nil }
                        else if metric == .duration { s.values[.duration] = Double(parseMMSS(t)) }
                        else if let d = Double(t) { s.values[metric] = max(0, MetricConvert.toCanonical(d, metric, from: unit)) }
                    }
                }
            }
        )
    }

    /// Check / uncheck a set. First check seeds any untouched metric from the plan (logged as
    /// prescribed); when every planned set is checked the exercise auto-completes.
    private func toggleComplete(_ ex: PlannedExercise, _ set: PlannedSet) {
        store.editLog { log in
            let wasDone = log.setLog(forPlanned: ex.id, plannedSetID: set.id)?.completed ?? false
            log.upsertSetLog(forPlanned: ex.id, name: ex.exerciseName, plannedSetID: set.id) { s in
                if !wasDone { for m in ex.selectedMetrics where s.values[m] == nil { s.values[m] = set.values[m] } }
                s.completed = !wasDone
            }
            let ids = ex.prescription.sets.map(\.id)
            let allDone = !ids.isEmpty && ids.allSatisfy { log.setLog(forPlanned: ex.id, plannedSetID: $0)?.completed == true }
            log.setStatus(allDone ? .completed : .pending, forPlanned: ex.id, name: ex.exerciseName)
        }
    }

    private func mmss(_ seconds: Int) -> String { seconds >= 60 ? "\(seconds / 60):\(String(format: "%02d", seconds % 60))" : "\(seconds)" }
    private func parseMMSS(_ s: String) -> Int {
        if s.contains(":") { let p = s.split(separator: ":").map { Int($0) ?? 0 }; return p.count == 2 ? p[0] * 60 + p[1] : (p.first ?? 0) }
        return Int(s) ?? 0
    }

    private func addMetric(_ metric: MetricType, to ex: PlannedExercise) {
        store.edit { $0.updateExercise(ex.id) { e in
            var s = Set(e.selectedMetrics); s.insert(metric)
            e.selectedMetrics = MetricType.allCases.filter { s.contains($0) }
        }}
    }

    private func blockGoalBinding(_ block: WorkoutBlock) -> Binding<String> {
        Binding(get: { store.current?.blocks.first { $0.id == block.id }?.intent ?? "" },
                set: { new in store.edit { $0.setBlockIntent(block.id, new.trimmingCharacters(in: .whitespaces).isEmpty ? nil : new) } })
    }

    private func duplicateSet(_ setID: UUID, in ex: PlannedExercise) {
        store.edit { $0.updateExercise(ex.id) { e in
            guard let i = e.prescription.sets.firstIndex(where: { $0.id == setID }) else { return }
            var copy = e.prescription.sets[i]; copy.id = UUID()
            e.prescription.sets.insert(copy, at: i + 1)
        }}
    }

    private func duplicateExercise(_ ex: PlannedExercise, in block: WorkoutBlock) {
        store.edit { w in
            guard let bi = w.blocks.firstIndex(where: { $0.id == block.id }),
                  let ei = w.blocks[bi].exercises.firstIndex(where: { $0.id == ex.id }) else { return }
            var copy = w.blocks[bi].exercises[ei]
            copy.id = UUID()
            copy.prescription.sets = copy.prescription.sets.map { var s = $0; s.id = UUID(); return s }
            w.blocks[bi].exercises.insert(copy, at: ei + 1)
        }
    }

    /// The shared full-width, lightweight "Add …" row — Add Block and Add Exercise use the same one.
    private func addRowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(BaselineColor.accent).frame(maxWidth: .infinity).frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 10).fill(BaselineColor.surface.opacity(0.5)))
        }.buttonStyle(.plain).padding(.top, 8)
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
    case configure(exerciseID: UUID, name: String, focus: MetricConfigFocus)

    var id: String {
        switch self {
        case .configure(let id, _, let f): "config-\(f)-\(id)"
        case .addExercise(let b): "addExercise-\(b?.uuidString ?? "none")"
        case .substitute(let id, _): "sub-\(id)"
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
