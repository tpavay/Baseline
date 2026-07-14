import SwiftUI
import SwiftData

/// The reading loop, presented full-screen from the home. The **morning** reading produces the
/// daily readiness score: reading → averages → check-in → readiness (saves a `ReadinessEntry`). A
/// **snapshot** is a spot-check: reading → check-in → summary → done — no score, no entry. The
/// reading surface is the shared one (camera or strap); this coordinator owns only the post-read
/// sequence.
struct DailyReadingFlowView: View {
    let type: ReadingType
    let config: ReadinessConfig
    let duration: TimeInterval

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(BluetoothManager.self) private var bluetooth
    @Environment(TrainingContextStore.self) private var context
    @Query(sort: \Reading.date, order: .reverse) private var readings: [Reading]

    private enum Step { case reading, averages, checkIn, readiness, summary }
    @State private var step: Step = .reading

    /// Only the morning reading produces a readiness score. A snapshot is a spot-check:
    /// reading → check-in → summary → done, and never feeds the daily readiness.
    private var isSnapshot: Bool { type == .snapshot }

    /// The check-in step only exists when it's enabled *and* has at least one visible row.
    private var showsCheckIn: Bool {
        config.checkInEnabled && !config.visibleCheckInComponents.isEmpty
    }
    @State private var result: ReadingResult?
    @State private var answers = CheckInAnswers()

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            switch step {
            case .reading:
                readingView
            case .averages:
                if let result {
                    ReadingAveragesView(
                        result: result,
                        continueTitle: showsCheckIn ? "CONTINUE TO CHECK-IN" : "SEE READINESS"
                    ) { step = showsCheckIn ? .checkIn : .readiness }
                }
            case .checkIn:
                DailyCheckInView(
                    config: config,
                    answers: $answers,
                    onContinue: { step = isSnapshot ? .summary : .readiness },
                    onSkip: { answers = CheckInAnswers(); step = isSnapshot ? .summary : .readiness }
                )
            case .readiness:
                if let result {
                    MorningReadinessScoreView(
                        result: result,
                        answers: config.checkInEnabled ? answers : nil,
                        config: config,
                        hrvBaseline: hrvBaseline,
                        rhrBaseline: rhrBaseline,
                        constraints: context.activeConstraints,
                        dailyContext: context.daily,
                        onDone: finish
                    )
                }
            case .summary:
                if let result {
                    // Snapshot's final screen: the same averages readout, but it just closes —
                    // no score, no saved readiness entry (the Reading itself is already persisted).
                    ReadingAveragesView(result: result, continueTitle: "DONE") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder private var readingView: some View {
        if config.heartSource == .camera {
            CameraReadingView(type: type, duration: duration, showIntro: true, onFinish: handleReading)
        } else {
            ReadingView(type: type, duration: duration, usesLivePreview: true, bluetooth: bluetooth, onFinish: handleReading)
        }
    }

    private func handleReading(_ finished: ReadingResult?) {
        guard let finished else { dismiss(); return }
        result = finished
        // Morning: averages → check-in → readiness. Snapshot: check-in → summary (no readiness).
        if isSnapshot {
            step = showsCheckIn ? .checkIn : .summary
        } else {
            step = .averages
        }
    }

    private func finish(_ decision: DecisionEngine.Result, _ plan: PlanningEngine.Plan, _ sleep: ReadinessSleepSnapshot?) {
        modelContext.insert(ReadinessEntry(decision: decision, plan: plan,
                                           answers: config.checkInEnabled ? answers : nil, sleep: sleep))
        dismiss()
    }

    // Baselines are single-source (mixing camera + strap corrupts them), so score today only
    // against prior mornings taken with the *current* method. Switching methods silently
    // re-calibrates from that source's history.
    private var currentSource: ReadingSource? {
        switch config.heartSource {
        case .camera: .camera
        case .strap: .chestStrap
        case .none: nil
        }
    }
    private var priorMornings: [Reading] {
        readings.filter {
            $0.kind == .morning
                && !Calendar.current.isDateInToday($0.date)
                && (currentSource == nil || $0.source == currentSource)
        }
    }
    private var hrvBaseline: ReadinessScore.Baseline? {
        ReadinessScore.baseline(from: priorMornings.map(\.lnRMSSD))
    }
    private var rhrBaseline: ReadinessScore.Baseline? {
        ReadinessScore.baseline(from: priorMornings.map(\.meanHR))
    }
}

// MARK: - Averages ("YOUR AVERAGES")

/// Post-reading summary: a vertical HRV → resting-HR readout with signal quality. The CTA label is
/// caller-supplied so the flow decides whether the next step is the check-in or the score.
struct ReadingAveragesView: View {
    let result: ReadingResult
    var continueTitle: String = "CONTINUE TO CHECK-IN"
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                InstrumentLabel("READING COMPLETE", color: BaselineColor.zoneGreen)
                Spacer()
                Circle().fill(BaselineColor.zoneGreen).frame(width: 7, height: 7)
                Text("SAVED").font(.bMono(11, .medium)).tracking(1).foregroundStyle(BaselineColor.zoneGreen)
            }
            .padding(.top, 12)

            Text("Your averages")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(BaselineColor.textHi)
                .padding(.top, 24)

            Spacer(minLength: 24)
            VStack(spacing: 22) {
                bigStat(label: "Heart rate variability", value: "\(Int(result.rmssd.rounded()))", unit: "MS")
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(BaselineColor.amethyst)
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(BaselineColor.accent))
                bigStat(label: "Resting HR", value: "\(Int(result.meanHR.rounded()))", unit: "BPM")
            }
            .frame(maxWidth: .infinity)

            signalQuality
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            Spacer(minLength: 32)

            Button(action: onContinue) { Text(continueTitle) }
                .buttonStyle(InstrumentButtonStyle())
                .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
    }

    private func bigStat(label: String, value: String, unit: String) -> some View {
        VStack(spacing: 6) {
            InstrumentLabel(label, tracking: 1.5)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.bMono(52, .bold)).foregroundStyle(BaselineColor.textHi)
                Text(unit).font(.bMono(14)).foregroundStyle(BaselineColor.textFaint)
            }
        }
    }

    @ViewBuilder private var signalQuality: some View {
        let (color, word): (Color, String) = {
            switch result.signalQuality {
            case .good: (BaselineColor.zoneGreen, "Good")
            case .fair: (BaselineColor.zoneAmber, "Fair")
            case .poor: (BaselineColor.zoneRed, "Poor")
            }
        }()
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text("Signal quality: \(word)")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
            }
            if result.artifacts > 0 {
                Text("\(result.artifacts) beat\(result.artifacts == 1 ? "" : "s") corrected")
                    .font(.system(size: 13)).foregroundStyle(BaselineColor.textFaint)
            }
            if result.signalQuality != .good {
                Text("A lot of noise was corrected — this reading is usable but less precise. You can retake it anytime.")
                    .font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24).padding(.top, 2)
            }
        }
    }
}

// MARK: - Daily check-in ("Tell us how you feel")

/// The daily wellness questionnaire — each item defaults to NOT SELECTED, a SKIP escape hatch
/// top-right, optional notes. Rows are data-driven off `config.checkInComponents` via `CheckInScale`.
struct DailyCheckInView: View {
    let config: ReadinessConfig
    @Binding var answers: CheckInAnswers
    let onContinue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                OnboardingHeadline("Tell us\nhow you feel", size: 26)
                Spacer()
                Button(action: onSkip) {
                    Text("SKIP").font(.bMono(12, .bold)).tracking(1).foregroundStyle(BaselineColor.textFaint)
                }
            }
            .padding(.top, 12)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    ForEach(config.visibleCheckInComponents) { component in
                        CheckInScaleView(scale: component.scale, value: binding(component))
                    }
                    if config.sleepEnabled {
                        SleepCheckInCard(answers: $answers)
                    }
                }
                .padding(.top, 24)

                InstrumentLabel("NOTES · OPTIONAL", tracking: 1.5).padding(.top, 26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextField("", text: $answers.notes,
                          prompt: Text("Anything worth remembering?").foregroundStyle(BaselineColor.textFaint),
                          axis: .vertical)
                    .font(.system(size: 14)).foregroundStyle(BaselineColor.textHi)
                    .lineLimit(2...4).padding(14)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(BaselineColor.surface)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BaselineColor.line, lineWidth: 1)))
                    .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)

            Button(action: onContinue) { Text("CONTINUE") }
                .buttonStyle(InstrumentButtonStyle())
                .padding(.top, 8).padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
    }

    private func binding(_ c: CheckInComponent) -> Binding<Double?> {
        Binding(get: { answers[keyPath: c.answerKeyPath] },
                set: { answers[keyPath: c.answerKeyPath] = $0 })
    }
}

// MARK: - Morning readiness score ("MORNING READINESS")

/// The daily reveal: **today's plan is the hero** (from the Decision + Planning engines), then the
/// evidence that supports it — readiness, limiter, certainty, why, and what to skip.
struct MorningReadinessScoreView: View {
    let result: ReadingResult
    let answers: CheckInAnswers?
    let config: ReadinessConfig
    let hrvBaseline: ReadinessScore.Baseline?
    let rhrBaseline: ReadinessScore.Baseline?
    var constraints: [DecisionEngine.Constraint] = []
    var dailyContext: TrainingContextStore.DailyContext = .init()
    /// The Sleep Engine seam (Slice 4), defaulted nil so the app builds this view on the legacy path
    /// and readiness stays byte-identical to pre-slice (AC-5). `referenceDate` is the recovery day the
    /// provider is queried for.
    var sleepProvider: SleepEvidenceProvider? = nil
    var referenceDate: Date = .now
    let onDone: (DecisionEngine.Result, PlanningEngine.Plan, ReadinessSleepSnapshot?) -> Void

    @Environment(HealthService.self) private var health
    @State private var computing = true
    @State private var decision: DecisionEngine.Result?
    @State private var plan: PlanningEngine.Plan?
    @State private var sleepSnapshot: ReadinessSleepSnapshot?

    var body: some View {
        VStack(spacing: 0) {
            if computing {
                Spacer()
                ProgressView().tint(BaselineColor.accent).scaleEffect(1.2)
                Text("Finding your plan…")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(BaselineColor.textMid).padding(.top, 16)
                Spacer()
            } else if let plan, let decision {
                content(plan: plan, decision: decision)
            }
        }
        .padding(.horizontal, 24)
        .task { await compute() }
    }

    @ViewBuilder private func content(plan: PlanningEngine.Plan, decision: DecisionEngine.Result) -> some View {
        HStack {
            InstrumentLabel("TODAY'S PLAN", tracking: 2)
            Spacer()
            certaintyPill(decision.certainty)
        }
        .padding(.top, 14)

        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                // Hero — the plan
                VStack(alignment: .leading, spacing: 9) {
                    Text(planHeadline(plan.type)).font(.bMono(11, .bold)).tracking(2).foregroundStyle(BaselineColor.accent)
                    Text(plan.summary)
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(BaselineColor.textHi)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [BaselineColor.amethyst, Color(hex: 0x1D1329)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(hex: 0x3A2A49), lineWidth: 1))

                // Readiness + limiter
                HStack(spacing: 10) {
                    statBox("READINESS", "\(decision.score)", dot: bandColor(decision.band))
                    statBox("MAIN LIMITER", limiterLabel(decision.primaryLimiter), dot: nil)
                }

                if !plan.why.isEmpty {
                    section("WHY") {
                        ForEach(plan.why, id: \.self) { line in
                            HStack(alignment: .top, spacing: 9) {
                                Circle().fill(BaselineColor.accent).frame(width: 6, height: 6).padding(.top, 7)
                                Text(line).font(.system(size: 13.5)).foregroundStyle(BaselineColor.textHi)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                if !plan.avoid.isEmpty {
                    section("SKIP TODAY") {
                        FlowChips(items: plan.avoid)
                    }
                }
            }
            .padding(.top, 18).padding(.bottom, 14)
        }

        Button { onDone(decision, plan, sleepSnapshot) } label: { Text("SEE YOUR DAY") }
            .buttonStyle(InstrumentButtonStyle())
            .padding(.bottom, 24)
    }

    // MARK: - Pieces

    private func certaintyPill(_ c: DecisionEngine.Certainty) -> some View {
        let (color, word): (Color, String) = {
            switch c {
            case .high: (BaselineColor.zoneGreen, "High")
            case .medium: (BaselineColor.zoneAmber, "Medium")
            case .low: (BaselineColor.textFaint, "Low")
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("Certainty · \(word)").font(.bMono(10, .bold)).tracking(0.5).foregroundStyle(BaselineColor.textMid)
        }
    }

    private func statBox(_ label: String, _ value: String, dot: Color?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            InstrumentLabel(label, tracking: 1)
            HStack(spacing: 7) {
                if let dot { Circle().fill(dot).frame(width: 9, height: 9) }
                Text(value).font(.system(size: 17, weight: .bold)).foregroundStyle(BaselineColor.textHi)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BaselineColor.surface))
    }

    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            InstrumentLabel(title, tracking: 1.5)
            content()
        }
    }

    private func bandColor(_ band: DecisionEngine.Band) -> Color {
        switch band {
        case .green: BaselineColor.zoneGreen
        case .amber: BaselineColor.zoneAmber
        case .red:   BaselineColor.zoneRed
        }
    }
    private func limiterLabel(_ d: DecisionEngine.Domain?) -> String { d?.title ?? "None today" }
    private func planHeadline(_ t: PlanningEngine.PlanType) -> String {
        switch t {
        case .hardIntensity: "INTENSITY"
        case .threshold: "THRESHOLD"
        case .aerobicBase: "AEROBIC BASE"
        case .easyAerobic: "EASY"
        case .lowImpact: "LOW-IMPACT"
        case .activeRecovery: "ACTIVE RECOVERY"
        }
    }

    private func compute() async {
        var inputs = DecisionEngine.Inputs()
        if config.heartReadingEnabled {
            inputs.lnRMSSD = result.lnRMSSD
            inputs.hrvBaseline = hrvBaseline
            inputs.restingHR = result.meanHR
            inputs.rhrBaseline = rhrBaseline
        }
        if config.sleepEnabled {
            // Sleep seam. Provider nil (every app call site today) → the exact pre-slice ladder
            // (Health → manual hours → thumb) via `SleepDecisionSeam.resolve(.legacy:)`; provider
            // present → engine-sourced inputs with the same manual fallback (AC-4/AC-5). The snapshot
            // is captured only when the seam published a score and is frozen onto the entry (AC-7).
            let manual = SleepDecisionSeam.ManualSleep(hours: answers?.sleepHoursManual, thumbsUp: answers?.sleepThumbsUp)
            let result: SleepDecisionSeam.Result
            if let sleepProvider {
                result = SleepDecisionSeam.resolve(.engine(sleepProvider.sleepInputs(on: referenceDate)), manual: manual)
            } else {
                let health = await health.lastNightSleep().map {
                    SleepDecisionSeam.HealthSleep(hours: $0.hours, efficiency: $0.efficiency)
                }
                result = SleepDecisionSeam.resolve(.legacy(health), manual: manual)
            }
            inputs.applySleep(result)
            sleepSnapshot = result.readinessSnapshot
        }
        if config.checkInEnabled {
            inputs.energy = answers?.energy
            inputs.mood = answers?.mood
            inputs.stress = answers?.stress
            inputs.soreness = answers?.soreness
        }
        let (d, p) = PlanAssembler.assemble(base: inputs, dailyContext: dailyContext, constraints: constraints)
        decision = d
        plan = p
        computing = false
        await Haptics.celebrate()
    }
}

/// Wrapping chip row for the avoid list.
private struct FlowChips: View {
    let items: [String]
    var body: some View {
        FlowLayout(spacing: 7, lineSpacing: 7) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color(hex: 0xFFB1A6))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(BaselineColor.zoneRed.opacity(0.09))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(BaselineColor.zoneRed.opacity(0.28), lineWidth: 1)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Minimal wrapping layout (iOS 16+).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 7
    var lineSpacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
        return CGSize(width: maxW.isFinite ? maxW : x, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += lineH + lineSpacing; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}
