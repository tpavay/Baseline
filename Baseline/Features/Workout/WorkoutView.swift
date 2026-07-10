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
                    Button { sheet = .addBlock } label: { Label("Add block", systemImage: "plus.rectangle.on.rectangle") }
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
                Button { sheet = .addBlock } label: {
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
            if executing {
                let done = store.currentLog?.isComplete == true
                Text(done ? "COMPLETED" : "IN PROGRESS")
                    .font(.system(size: 11, weight: .bold)).tracking(0.6)
                    .foregroundStyle(done ? BaselineColor.zoneGreen : BaselineColor.accent)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Block

    private func blockCard(_ block: WorkoutBlock) -> some View {
        let expanded = expandedBlocks.contains(block.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { toggle(&expandedBlocks, block.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(BaselineColor.textFaint)
                        Text(block.name.uppercased()).font(.system(size: 13, weight: .bold)).tracking(0.5).foregroundStyle(BaselineColor.textHi)
                        if let intent = block.intent {
                            Text(intent).font(.system(size: 11)).foregroundStyle(BaselineColor.textFaint)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Menu {
                    Button { sheet = .addExercise(blockID: block.id) } label: { Label("Add exercise", systemImage: "plus") }
                    Button(role: .destructive) { store.edit { $0.removeBlock(block.id) } } label: { Label("Delete block", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis").font(.system(size: 14)).foregroundStyle(BaselineColor.textFaint).padding(6) }
            }
            if expanded {
                if block.exercises.isEmpty {
                    Text("No exercises yet").font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint).padding(.top, 8)
                }
                ForEach(block.exercises) { ex in exerciseRow(ex, in: block) }
                Button { sheet = .addExercise(blockID: block.id) } label: {
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
                        Text(prescriptionSummary(ex.prescription)).font(.system(size: 12)).foregroundStyle(BaselineColor.textMid)
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
            // Planned sets
            ForEach(Array(ex.prescription.sets.enumerated()), id: \.element.id) { i, s in
                Text("Set \(i + 1): \(setText(s))").font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint)
            }
            if executing {
                // Logged sets
                if let logs = performed?.setLogs, !logs.isEmpty {
                    Text("LOGGED").font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(BaselineColor.zoneGreen)
                    ForEach(Array(logs.enumerated()), id: \.element.id) { i, s in
                        HStack {
                            Text("• \(loggedText(s))").font(.system(size: 13)).foregroundStyle(BaselineColor.textHi)
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
            Button { store.create(title: "Today's workout", goal: nil); sheet = .addBlock } label: {
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
        case .addBlock:
            AddBlockSheet { name, intent in store.edit { $0.addBlock(name: name, intent: intent) } }
        case .addExercise(let blockID):
            AddExerciseSheet(blocks: store.current?.blocks ?? [], preferredBlock: blockID) { blockID, ex in
                store.edit { $0.addExercise(ex, toBlock: blockID) }
            }
        case .substitute(let id, let current):
            SubstituteSheet(currentName: current) { name, prescription in
                store.edit { $0.substituteExercise(id, withName: name, prescription: prescription) }
            }
        case .logSet(let id, let name):
            LogSetSheet { set in store.editLog { $0.logSet(set, forPlanned: id, name: name) } }
        }
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

    private func prescriptionSummary(_ p: Prescription) -> String {
        guard !p.sets.isEmpty else { return "no sets" }
        let s = p.sets.first!
        let scheme = [s.reps.map { "\($0)" }, s.load.map { "@\(Int($0))" }].compactMap { $0 }.joined(separator: " ")
        return "\(p.sets.count)×\(scheme.isEmpty ? "" : scheme)".trimmingCharacters(in: .whitespaces)
    }

    private func setText(_ s: PlannedSet) -> String {
        var b: [String] = []
        if let r = s.reps { b.append("\(r) reps") }
        if let l = s.load { b.append("\(Int(l)) load") }
        if let d = s.duration { b.append("\(d)s") }
        if let dist = s.distance { b.append("\(Int(dist))m") }
        return b.isEmpty ? "—" : b.joined(separator: ", ")
    }

    private func loggedText(_ s: SetLog) -> String {
        var b: [String] = []
        if let r = s.reps { b.append("\(r) reps") }
        if let l = s.load { b.append("\(Int(l)) load") }
        if let d = s.duration { b.append("\(d)s") }
        if let dist = s.distance { b.append("\(Int(dist))m") }
        if let rpe = s.rpe { b.append("RPE \(Int(rpe))") }
        return b.isEmpty ? "logged" : b.joined(separator: ", ")
    }
}

private enum WorkoutSheet: Identifiable {
    case addBlock
    case addExercise(blockID: UUID?)
    case substitute(exerciseID: UUID, current: String)
    case logSet(exerciseID: UUID, name: String)

    var id: String {
        switch self {
        case .addBlock: "addBlock"
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
