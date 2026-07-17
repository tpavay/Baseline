import SwiftUI
import SwiftData

/// "Ask Baseline" — the Context Engine's surface. Presents the conversation once today's base
/// evidence is assembled, so the agent reasons about the athlete's real state. The tool loop and
/// state live on-device (AgentTools); this view only shows the exchange.
enum AskBaselineContext: Equatable {
    case general
    case workoutImport
}

struct AskBaselineSheet: View {
    @Environment(TrainingContextStore.self) private var context
    @Environment(HealthService.self) private var health
    @Environment(OnboardingStore.self) private var profile
    @Environment(WorkoutStore.self) private var workouts
    @Environment(PlanStore.self) private var plan
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Reading.date, order: .reverse) private var readings: [Reading]
    @Query(sort: \ReadinessEntry.date, order: .reverse) private var entries: [ReadinessEntry]

    @State private var service: ConversationService?
    @State private var showInspector = false
    let mode: AskBaselineContext

    init(mode: AskBaselineContext = .general) {
        self.mode = mode
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                if let service {
                    ConversationView(service: service, mode: mode)
                } else {
                    ProgressView().tint(BaselineColor.accent)
                }
            }
            .navigationTitle("Baseline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showInspector = true } label: {
                        Image(systemName: "sparkles.rectangle.stack")
                    }
                    .foregroundStyle(BaselineColor.accent)
                    .disabled(service == nil)
                    .accessibilityLabel(mode == .workoutImport ? "Inspect imported workout context" : "Inspect Baseline context")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(BaselineColor.accent)
                        .disabled(service?.isThinking == true)
                }
            }
        }
        .task { await setUp() }
        .sheet(isPresented: $showInspector) {
            if let service { StateInspectorView(service: service, context: context, workouts: workouts) }
        }
        // A partial bottom sheet, not a takeover — drag down to peek at the workout behind and keep
        // talking mid-session. Chat never navigates away.
        .presentationDetents([.large, .medium])
        .presentationBackgroundInteraction(
            mode == .workoutImport ? .disabled : .enabled(upThrough: .medium)
        )
        .interactiveDismissDisabled(service?.isThinking == true)
    }

    private func setUp() async {
        guard service == nil else { return }
        if mode == .general {
            workouts.reloadFromPlan()   // freshen the bound today-workout in case the Plan tab changed it
        }
        let today = entries.first { Calendar.current.isDateInToday($0.date) }
        let base = await TodayEvidence.baseInputs(readings: readings, todayEntry: today, health: health)
        let tools = AgentTools(store: context, base: base,
                               health: health, hrvConfigured: profile.draft.config.heartSource != nil,
                               readings: readings, workouts: workouts, plan: mode == .general ? plan : nil)
        service = ConversationService(
            tools: tools,
            scope: mode == .workoutImport ? .workoutImport : .general
        )
    }
}

private struct ConversationView: View {
    let service: ConversationService
    let mode: AskBaselineContext
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if service.log.isEmpty { greeting }
                        ForEach(service.log) { bubble($0) }
                        if service.isThinking { typing }
                    }
                    .padding(16)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .scrollDismissesKeyboard(.interactively)   // swipe down on the chat to hide the keyboard
                .onChange(of: service.log.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: service.isThinking) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            // Openers, offered while the greeting is, so the two retire together the moment the
            // athlete says anything.
            if showsSuggestions {
                ConversationSuggestionChips(suggestions: ConversationSuggestion.all(for: mode)) {
                    draft = $0.prompt
                    inputFocused = true
                }
                .transition(.opacity)
            }
            composer
        }
        .animation(.easeInOut(duration: 0.2), value: service.log.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: showsSuggestions)
    }

    /// A chip fills the composer, so the row has to leave once the box holds words of the athlete's
    /// own: tapping one would silently throw them away, and a binding written in code is nothing the
    /// undo manager can give back. Untouched chip text stays replaceable, which is what lets a second
    /// chip swap out the first.
    private var showsSuggestions: Bool {
        service.log.isEmpty && ConversationSuggestion.isUnedited(draft: draft, for: mode)
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode == .workoutImport ? "Fix this workout" : "Ask Baseline")
                .font(.title3.bold())
                .foregroundStyle(BaselineColor.textHi)
            Text(greetingCopy)
                .font(.callout).foregroundStyle(BaselineColor.textMid).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }

    /// Deliberately short: the suggestion chips above the composer now carry the concrete examples
    /// this copy used to spell out, and tappably. Saying both would say it twice.
    private var greetingCopy: String {
        switch mode {
        case .general:
            "Tell me what changed and I'll adjust today's plan, or ask why."
        case .workoutImport:
            "Tell me what the photos meant and I'll fix the draft."
        }
    }

    private func bubble(_ m: ConversationService.Message) -> some View {
        HStack {
            if m.role == .you { Spacer(minLength: 40) }
            Text(m.text)
                .font(.body).lineSpacing(2)
                .foregroundStyle(m.role == .you ? Color(hex: 0x120B21) : BaselineColor.textHi)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(m.role == .you ? BaselineColor.accent : BaselineColor.surface))
                .overlay(m.role == .you ? nil : RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(BaselineColor.line, lineWidth: 1))
            if m.role == .baseline { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: m.role == .you ? .trailing : .leading)
    }

    private var typing: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { _ in Circle().fill(BaselineColor.textFaint).frame(width: 7, height: 7) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BaselineColor.surface))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("", text: $draft, prompt: Text("Message Baseline\u{2026}").foregroundStyle(BaselineColor.textFaint), axis: .vertical)
                .font(.body).foregroundStyle(BaselineColor.textHi)
                .lineLimit(1...4).focused($inputFocused)
                .padding(.horizontal, 15).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(BaselineColor.surface).overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(BaselineColor.line, lineWidth: 1)))
            Button { send() } label: {
                Image(systemName: "arrow.up")
                    .font(.headline.weight(.bold)).foregroundStyle(Color(hex: 0x120B21))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(canSend ? BaselineColor.accent : BaselineColor.line))
            }
            .disabled(!canSend)
            .accessibilityLabel("Send message")
            .accessibilityHint("Sends your workout correction to Baseline")
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
        .background(BaselineColor.base)
        .overlay(Rectangle().fill(BaselineColor.line).frame(height: 1), alignment: .top)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !service.isThinking }

    private func send() {
        let text = draft
        draft = ""
        service.send(text)
    }
}

/// "What Baseline knows" — the honest window into the structured state the conversation is building.
/// Structured state is the source of truth; this makes it visible so the athlete can see what was
/// logged, the plan it produces, and every behind-the-scenes tool the model invoked.
private struct StateInspectorView: View {
    let service: ConversationService
    let context: TrainingContextStore
    let workouts: WorkoutStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        planSection
                        workoutSection
                        knownSection
                        constraintsSection
                        activitySection
                    }
                    .padding(16)
                }
            }
            .navigationTitle("What Baseline knows")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(BaselineColor.accent)
                }
            }
        }
    }

    @ViewBuilder private var planSection: some View {
        card("TODAY'S PLAN") {
            if let d = service.latestDecision, let p = service.latestPlan {
                Text(p.summary).font(.body.weight(.semibold)).foregroundStyle(BaselineColor.textHi)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(BaselineColor.line)
                row("Readiness", "\(d.score)")
                row("Band", d.band.rawValue)
                row("Certainty", d.calibrating ? "calibrating" : d.certainty.rawValue)
                row("Evidence", d.evidenceTier.rawValue)
                row("Limiter", d.primaryLimiter?.title.lowercased() ?? "none")
            } else {
                empty("No plan yet — say hello to Baseline.")
            }
        }
    }

    private var workoutTitle: String {
        guard let d = workouts.current?.scheduledDate, !Calendar.current.isDateInToday(d) else { return "TODAY'S WORKOUT" }
        return "WORKOUT · " + d.formatted(.dateTime.month().day())
    }

    @ViewBuilder private var workoutSection: some View {
        card(workoutTitle) {
            if let w = workouts.current {
                Text(w.title).font(.body.weight(.semibold)).foregroundStyle(BaselineColor.textHi)
                if let g = w.goal { row("Goal", g) }
                ForEach(w.blocks) { block in
                    Text(block.name.uppercased() + (block.intent.map { " · \($0)" } ?? ""))
                        .font(.caption2.weight(.semibold)).tracking(0.4).foregroundStyle(BaselineColor.textFaint)
                        .padding(.top, 2)
                    if block.exercises.isEmpty {
                        empty("(empty)")
                    } else {
                        ForEach(block.exercises) { ex in
                            row(ex.exerciseName, setsLabel(ex.prescription))
                        }
                    }
                }
            } else {
                empty("No workout yet — ask Baseline to build one.")
            }
        }
    }

    private func setsLabel(_ p: Prescription) -> String {
        guard !p.sets.isEmpty else { return "no sets" }
        let s = p.sets.first!
        let scheme = [s.reps.map { "\($0)" }, s.load.map { "@\(Int($0))" }].compactMap { $0 }.joined(separator: " ")
        return "\(p.sets.count)×\(scheme.isEmpty ? "set" : scheme)"
    }

    @ViewBuilder private var knownSection: some View {
        card("CONTEXT TODAY") {
            let rows = knownRows
            if rows.isEmpty {
                empty("Nothing logged for today yet.")
            } else {
                ForEach(rows, id: \.0) { row($0.0, $0.1) }
            }
        }
    }

    @ViewBuilder private var constraintsSection: some View {
        let constraints = context.activeConstraints
        card("CONSTRAINTS") {
            if constraints.isEmpty {
                empty("No active injuries or pain.")
            } else {
                ForEach(Array(constraints.enumerated()), id: \.offset) { _, c in
                    row("\(c.location) · \(c.kind.rawValue)",
                        "sev \(c.severity)\(c.affectsTraining ? "" : " · not limiting")")
                }
            }
        }
    }

    @ViewBuilder private var activitySection: some View {
        card("ACTIVITY THIS CHAT") {
            if service.toolActivity.isEmpty {
                empty("No changes yet — Baseline hasn't logged anything.")
            } else {
                ForEach(service.toolActivity.reversed()) { event in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(BaselineColor.accent).padding(.top, 3)
                        Text(event.label).font(.subheadline).foregroundStyle(BaselineColor.textMid)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var knownRows: [(String, String)] {
        let d = context.daily
        var out: [(String, String)] = []
        if let s = d.sleepHours { out.append(("Sleep", "\(fmt(s)) h")) }
        if let e = d.energy { out.append(("Energy", "\(Int(e))/5")) }
        if let m = d.mood { out.append(("Mood", "\(Int(m))/5")) }
        if let s = d.stress { out.append(("Stress", "\(Int(s))/5")) }
        if let so = d.soreness { out.append(("Soreness", "\(Int(so))/5")) }
        if let t = d.timeAvailableMinutes { out.append(("Time available", "\(t) min")) }
        if let eq = d.equipment, !eq.isEmpty { out.append(("Equipment", eq.joined(separator: ", "))) }
        if let tr = d.traveling { out.append(("Traveling", tr ? "Yes" : "No")) }
        if let ill = d.illness { out.append(("Illness", ill ? "Yes" : "No")) }
        if let n = d.note, !n.isEmpty { out.append(("Note", n)) }
        return out
    }

    private func fmt(_ v: Double) -> String { String(format: "%g", v) }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.subheadline).foregroundStyle(BaselineColor.textFaint)
            Spacer(minLength: 12)
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(BaselineColor.textHi)
                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(BaselineColor.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(BaselineColor.accent)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BaselineColor.surface))
    }
}
