import SwiftUI

// Act 3 — value first: first reading → check-in → provisional score, THEN the account
// (framed as saving what they just made), outlook, commitment, reminder.

// MARK: - "Ready for your first reading." (pre-dawn milestone)

struct FirstReadingIntroStepView: View {
    let store: OnboardingStore

    /// A heart reading runs whenever a heart source is configured — strap *or* camera. (Only the
    /// subjective-only athlete, with no heart source, skips straight to the check-in.)
    private var hasReading: Bool {
        store.draft.config.heartReadingEnabled && store.draft.config.heartSource != nil
    }

    var body: some View {
        ZStack {
            Rectangle().fill(OnboardingStyle.preDawnMilestone).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button {
                        Haptics.tap()
                        store.back()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(.white.opacity(0.12)))
                    }
                    Spacer()
                }
                .padding(.top, 6)

                Spacer()
                OnboardingHeadline(hasReading ? "YOUR FIRST\nREADING" : "YOUR FIRST\nCHECK-IN", size: 32, color: .white)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                Text(hasReading
                     ? "Two and a half minutes, still and quiet. Your heart rate variability is the clearest read on how recovered you are — this sets the baseline every future score builds on."
                     : "A few honest taps on how you slept, feel, and move today — this sets the baseline every future score builds on.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()

                Button {
                    Haptics.milestone()
                    store.advance()
                } label: {
                    Text(hasReading ? "TAKE MY FIRST READING" : "DO MY FIRST CHECK-IN")
                }
                .buttonStyle(InstrumentButtonStyle(tint: .white, textColor: BaselineColor.base))
                .padding(.bottom, 18)
            }
            .padding(.horizontal, 26)
        }
    }

}

// MARK: - First reading (reuses the full ReadingView flow)

struct FirstReadingStepView: View {
    let store: OnboardingStore
    @Environment(BluetoothManager.self) private var bluetooth

    var body: some View {
        Group {
            if store.draft.config.heartSource == .camera {
                // Onboarding already showed its own first-reading intro — skip the camera one.
                CameraReadingView(type: .morning, showIntro: false, onFinish: finish)
            } else {
                ReadingView(type: .morning, usesLivePreview: true, bluetooth: bluetooth, onFinish: finish)
            }
        }
    }

    private func finish(_ result: ReadingResult?) {
        if let result {
            store.draft.firstReadingRMSSD = result.rmssd
            store.draft.firstReadingLnRMSSD = result.lnRMSSD
            store.draft.firstReadingDone = true
            store.advance()
        } else {
            store.back()
        }
    }
}

// MARK: - Daily check-in (also the daily-loop questionnaire, born here)

struct CheckInStepView: View {
    @Bindable var store: OnboardingStore
    @FocusState private var notesFocused: Bool

    var body: some View {
        OnboardingStepScaffold(store: store, onCTA: {
            Haptics.tap()
            store.advance()
        }) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    OnboardingHeadline("Tell us how you feel", size: 26)
                    Text("Honest beats optimistic — the score is for you.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(BaselineColor.textMid)
                        .padding(.top, 6)

                    VStack(spacing: 22) {
                        ForEach(store.draft.config.visibleCheckInComponents) { component in
                            CheckInScaleView(scale: component.scale, value: checkInBinding(component))
                        }
                    }
                    .padding(.top, 24)

                    InstrumentLabel("NOTES · OPTIONAL", tracking: 1.5)
                        .padding(.top, 26)
                    TextField(
                        "",
                        text: Binding(
                            get: { store.draft.checkIn?.notes ?? "" },
                            set: { update { $0.notes = $1 } ($0) }
                        ),
                        prompt: Text("Anything worth remembering?").foregroundStyle(BaselineColor.textFaint),
                        axis: .vertical
                    )
                    .font(.system(size: 14))
                    .foregroundStyle(BaselineColor.textHi)
                    .lineLimit(2...4)
                    .focused($notesFocused)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(BaselineColor.surface)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BaselineColor.line, lineWidth: 1))
                    )
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            if store.draft.checkIn == nil { store.draft.checkIn = CheckInAnswers() }
        }
    }

    private func checkInBinding(_ c: CheckInComponent) -> Binding<Double?> {
        Binding(
            get: { store.draft.checkIn?[keyPath: c.answerKeyPath] },
            set: { newValue in
                var answers = store.draft.checkIn ?? CheckInAnswers()
                answers[keyPath: c.answerKeyPath] = newValue
                store.draft.checkIn = answers
            }
        )
    }

    private func update(_ mutate: @escaping (inout CheckInAnswers, String) -> Void) -> (String) -> Void {
        { value in
            var answers = store.draft.checkIn ?? CheckInAnswers()
            mutate(&answers, value)
            store.draft.checkIn = answers
        }
    }
}

// MARK: - Day-one score reveal (provisional, violet, honest)

struct ScoreRevealStepView: View {
    @Bindable var store: OnboardingStore
    @Environment(HealthService.self) private var health
    @State private var celebrated = false
    @State private var score = 50
    @State private var computing = true

    /// Compute the config-aware first score: HRV (if a reading happened) + sleep (from HealthKit,
    /// if enabled + granted) + subjective check-in — re-normalizing over whatever is present. This
    /// is the cold-start / "calibrating" path (no personal baseline yet, so absolute frames).
    private func computeScore() async {
        // Pull last night's sleep only if the athlete put sleep in their formula.
        if store.draft.config.sleepEnabled, store.draft.sleepHours == nil {
            if let sleep = await health.lastNightSleep() {
                store.draft.sleepHours = sleep.hours
                store.draft.sleepEfficiency = sleep.efficiency
            }
        }

        let components = store.draft.config.checkInComponents
        let answers = store.draft.checkIn
        var inputs = ReadinessScore.Inputs(
            checkIn: store.draft.config.checkInEnabled ? (answers?.orientedValues(for: components) ?? []) : [],
            soreness: answers?.soreness,
            stress: answers?.stress
        )
        if store.draft.config.heartReadingEnabled {
            inputs.lnRMSSD = store.draft.firstReadingLnRMSSD
        }
        if store.draft.config.sleepEnabled {
            inputs.sleepScore = ReadinessScore.sleepScore(hours: store.draft.sleepHours, efficiency: store.draft.sleepEfficiency)
        }

        let result = ReadinessScore.compute(inputs)
        store.draft.provisionalScore = result.score
        score = result.score
        computing = false
    }

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            RadialGradient(
                colors: [BaselineColor.accent.opacity(0.16), .clear],
                center: .bottom, startRadius: 60, endRadius: 480
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                ReadinessGauge(score: computing ? nil : score, fill: BaselineColor.accent, label: "", size: 230, animated: true)

                OnboardingHeadline("Your first score.", size: 26)
                    .padding(.top, 30)
                Text("Built from \(sourcesLine). It's an estimate for now — every morning you read, it gets sharper. Consistency is the whole trick.")
                    .font(.system(size: 14))
                    .foregroundStyle(BaselineColor.textMid)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 10)
                    .padding(.horizontal, 8)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(BaselineColor.line).frame(height: 4)
                            Capsule().fill(BaselineColor.accent).frame(width: geo.size.width / CGFloat(ReadinessScore.calibrationThreshold), height: 4)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: 10)
                    InstrumentLabel("DAY 1 OF \(ReadinessScore.calibrationThreshold)", tracking: 2)
                }
                .padding(.top, 26)
                .padding(.horizontal, 40)

                Spacer()

                Button {
                    Haptics.tap()
                    store.advance()
                } label: {
                    Text("CONTINUE")
                }
                .buttonStyle(InstrumentButtonStyle())
                .padding(.bottom, 18)
            }
            .padding(.horizontal, 26)
        }
        .task {
            await computeScore()
            if !celebrated {
                celebrated = true
                await Haptics.celebrate()
            }
        }
    }

    private var sourcesLine: String {
        var parts: [String] = []
        if store.draft.firstReadingRMSSD != nil { parts.append("this morning's reading") }
        if store.draft.config.sleepEnabled { parts.append("your sleep") }
        if store.draft.checkIn != nil { parts.append("your check-in") }
        if parts.isEmpty { return "your setup" }
        if parts.count == 1 { return parts[0] }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }
}

// MARK: - Auth ("save your baseline")

struct AuthStepView: View {
    let store: OnboardingStore
    @Environment(AuthViewModel.self) private var authVM

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    if !store.isExistingUserSignIn {
                        Button {
                            Haptics.tap()
                            store.back()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(BaselineColor.textMid)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(BaselineColor.surface))
                        }
                    }
                    Spacer()
                    if store.isExistingUserSignIn {
                        QuietLinkButton(title: "Back to setup") { store.back() }
                    }
                }
                .padding(.top, 6)

                Spacer()
                Image("BaselineIconNoBackground")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                OnboardingHeadline("WELCOME TO\nBASELINE", size: 32)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
                Spacer()

                if let errorMessage = authVM.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BaselineColor.zoneRed)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 12)
                }

                VStack(spacing: 14) {
                    ProviderButton(
                        title: "Continue with Apple",
                        icon: .sfSymbol("apple.logo"),
                        foreground: .black,
                        background: .white,
                        isLoading: authVM.state == .authenticatingApple,
                        isDisabled: authVM.state.isBusy
                    ) {
                        Task { await authVM.signInWithApple() }
                    }
                    ProviderButton(
                        title: "Continue with Google",
                        icon: .googleG,
                        foreground: BaselineColor.textHi,
                        background: BaselineColor.surface,
                        border: BaselineColor.line,
                        isLoading: authVM.state == .authenticatingGoogle,
                        isDisabled: authVM.state.isBusy
                    ) {
                        Task { await authVM.signInWithGoogle() }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: authVM.state)

                Text(OnboardingCopy.tosFootnote)
                    .font(.system(size: 11))
                    .foregroundStyle(BaselineColor.textFaint)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
                    .padding(.bottom, 18)
            }
            .padding(.horizontal, 26)
        }
        .onChange(of: authVM.state) { _, state in
            if state == .authenticated {
                Haptics.success()
                store.authSucceeded()
            }
        }
        .onAppear {
            // Already signed in from a previous partial run — don't ask again.
            if authVM.state == .authenticated { store.authSucceeded() }
        }
    }
}

// MARK: - 30-day outlook (illustrative projection)

struct OutlookStepView: View {
    let store: OnboardingStore
    @State private var draw: CGFloat = 0

    private var objective: TrainingObjective { store.draft.objective ?? .optimizeLoad }

    var body: some View {
        OnboardingStepScaffold(store: store) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline(OnboardingCopy.outlookHeadline(for: objective), size: 28)
                Text(OnboardingCopy.outlookBody(for: objective))
                    .font(.system(size: 14))
                    .foregroundStyle(BaselineColor.textMid)
                    .lineSpacing(3)
                    .padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)

                OutlookChart(draw: draw)
                    .frame(height: 220)
                    .padding(.top, 28)

                Spacer(minLength: 10)
            }
        }
        .onAppear {
            draw = 0
            withAnimation(.easeInOut(duration: 1.6).delay(0.25)) { draw = 1 }
        }
    }
}

/// Two labeled trend lines — "With Baseline" climbing, "Guessing" sawtoothing sideways — that
/// draw on when the screen appears (Liftoff-style). Clear axis labels and endpoint tags anchor
/// the story; the shape mirrors the real finding (bigger gains, fewer hard days).
private struct OutlookChart: View {
    var draw: CGFloat

    private let managed: [Double] = [0.30, 0.34, 0.32, 0.41, 0.45, 0.43, 0.53, 0.58, 0.57, 0.68, 0.76, 0.84]
    private let guessing: [Double] = [0.30, 0.37, 0.27, 0.35, 0.26, 0.34, 0.25, 0.33, 0.24, 0.32, 0.27, 0.31]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let plotH = geo.size.height - 22   // leave room for the week axis
            let h = plotH

            ZStack(alignment: .topLeading) {
                // Gridlines
                ForEach(0..<4) { i in
                    Rectangle().fill(BaselineColor.line.opacity(0.5))
                        .frame(height: 1)
                        .offset(y: h * CGFloat(i) / 3)
                }

                // "Guessing" — dashed, faint
                trend(width: w, height: h, points: guessing)
                    .trimmedPath(from: 0, to: draw)
                    .stroke(BaselineColor.textFaint.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))

                // "With Baseline" — accent, glowing
                trend(width: w, height: h, points: managed)
                    .trimmedPath(from: 0, to: draw)
                    .stroke(BaselineColor.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .shadow(color: BaselineColor.accent.opacity(0.5), radius: 8)

                // Endpoint tags (fade in as the draw completes)
                endpointTag("WITH BASELINE", color: BaselineColor.accent,
                            at: point(managed, w: w, h: h, i: managed.count - 1))
                endpointTag("GUESSING", color: BaselineColor.textFaint,
                            at: point(guessing, w: w, h: h, i: guessing.count - 1))
                    .opacity(0.85)

                // Y-axis anchor labels
                VStack {
                    Text("FITTER").font(.bMono(8)).tracking(1).foregroundStyle(BaselineColor.textFaint)
                    Spacer()
                    Text("START").font(.bMono(8)).tracking(1).foregroundStyle(BaselineColor.textFaint)
                }
                .frame(height: h)

                // X-axis (weeks)
                HStack {
                    ForEach(["WK 1", "WK 2", "WK 3", "WK 4"], id: \.self) { label in
                        Text(label).font(.bMono(8)).tracking(1).foregroundStyle(BaselineColor.textFaint)
                        if label != "WK 4" { Spacer() }
                    }
                }
                .offset(y: h + 8)
            }
        }
    }

    private func point(_ points: [Double], w: CGFloat, h: CGFloat, i: Int) -> CGPoint {
        let step = w / CGFloat(points.count - 1)
        return CGPoint(x: CGFloat(i) * step, y: h * (1 - points[i]))
    }

    private func endpointTag(_ text: String, color: Color, at p: CGPoint) -> some View {
        Text(text)
            .font(.bMono(9, .bold)).tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(BaselineColor.base.opacity(0.85)))
            .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
            .fixedSize()
            .position(x: p.x - 34, y: p.y - 14)
            .opacity(Double((draw - 0.75) / 0.25).clamped01)
    }

    private func trend(width: CGFloat, height: CGFloat, points: [Double]) -> Path {
        var path = Path()
        for i in points.indices {
            let pt = point(points, w: width, h: height, i: i)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }
}

private extension Double {
    var clamped01: Double { Swift.min(Swift.max(self, 0), 1) }
}

// MARK: - Commitment (hold-to-commit: effort is the point)

struct CommitmentStepView: View {
    @Bindable var store: OnboardingStore
    @State private var progress: Double = 0
    @State private var completed = false
    @State private var holdTask: Task<Void, Never>?

    private var objective: TrainingObjective { store.draft.objective ?? .optimizeLoad }

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            Rectangle().fill(OnboardingStyle.warmGlow).ignoresSafeArea()

            // The commitment fill — grows from behind the hold target to swallow the screen.
            Circle()
                .fill(BaselineColor.accent)
                .frame(width: 130, height: 130)
                .scaleEffect(0.01 + progress * 16)
                .opacity(progress > 0 ? 1 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack {
                    Button {
                        Haptics.tap()
                        store.back()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(BaselineColor.textMid)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(BaselineColor.surface))
                    }
                    .opacity(progress > 0 ? 0 : 1)
                    Spacer()
                }
                .padding(.top, 6)

                Spacer()

                Group {
                    OnboardingHeadline("I will use Baseline to…", size: 24)
                        .multilineTextAlignment(.center)
                    (Text("assess my daily readiness to improve ")
                     + Text(objective.commitmentPhrase).bold().foregroundStyle(
                        progress > 0 ? BaselineColor.base : BaselineColor.accent))
                        .font(.system(size: 15))
                        .foregroundStyle(progress > 0 ? BaselineColor.base : BaselineColor.textMid)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .padding(.top, 10)
                        .padding(.horizontal, 12)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(progress > 0.65 ? 0 : 1)
                .animation(.easeOut(duration: 0.2), value: progress > 0.65)

                holdTarget
                    .padding(.top, 44)

                Text(statusLine)
                    .font(.bMono(11, .medium))
                    .tracking(1.5)
                    .foregroundStyle(progress > 0 ? BaselineColor.base : BaselineColor.textFaint)
                    .textCase(.uppercase)
                    .padding(.top, 22)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: statusLine)

                Spacer()

                Text(OnboardingCopy.tosFootnote)
                    .font(.system(size: 11))
                    .foregroundStyle(progress > 0 ? BaselineColor.base.opacity(0.7) : BaselineColor.textFaint)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 18)
            }
            .padding(.horizontal, 26)
        }
    }

    private var statusLine: String {
        if completed { return "Committed." }
        if progress > 0.7 { return "Almost there…" }
        if progress > 0 { return "Keep holding…" }
        return store.draft.config.heartReadingEnabled
            ? "Press and hold to commit to your morning reading"
            : "Press and hold to commit to your morning check-in"
    }

    private var holdTarget: some View {
        ZStack {
            Circle()
                .stroke(progress > 0 ? BaselineColor.base.opacity(0.5) : BaselineColor.line, lineWidth: 2)
                .frame(width: 130, height: 130)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(progress > 0 ? BaselineColor.base : BaselineColor.accent,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 130, height: 130)
            Image("BaselineIconNoBackground")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
        }
        .contentShape(Circle())
        .scaleEffect(progress > 0 ? 1.06 : 1)
        .animation(.easeOut(duration: 0.25), value: progress > 0)
        .onLongPressGesture(minimumDuration: 60, maximumDistance: 80) {
            // Completion is driven by the staged hold task, never the gesture timer.
        } onPressingChanged: { pressing in
            if pressing { startHold() } else if !completed { cancelHold() }
        }
        .accessibilityLabel("Press and hold to commit")
    }

    /// The staged commitment: the fill breathes outward in beats — grow, hold, grow, hold —
    /// so the hold feels deliberate rather than a countdown. Haptic lands only at the end.
    private func startHold() {
        Haptics.tap()
        holdTask?.cancel()
        holdTask = Task {
            let stages: [(target: Double, growth: Double, pause: Double)] = [
                (0.28, 0.45, 0.75),
                (0.55, 0.45, 0.75),
                (0.82, 0.45, 1.0),
                (1.0, 0.5, 0),
            ]
            for stage in stages {
                withAnimation(.easeInOut(duration: stage.growth)) { progress = stage.target }
                try? await Task.sleep(for: .milliseconds(Int((stage.growth + stage.pause) * 1000)))
                if Task.isCancelled { return }
            }
            complete()
        }
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
        withAnimation(.spring(duration: 0.45)) { progress = 0 }
    }

    private func complete() {
        holdTask?.cancel()
        completed = true
        withAnimation(.easeIn(duration: 0.25)) { progress = 1 }
        store.draft.committed = true
        Haptics.success()
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            store.advance()
        }
    }
}

// MARK: - Reminder ("same time every morning") — the flow's final step

struct ReminderStepView: View {
    @Bindable var store: OnboardingStore
    @State private var time = Calendar.current.date(from: DateComponents(hour: 6, minute: 30)) ?? .now
    @State private var scheduling = false

    private let weekdaySymbols = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        OnboardingStepScaffold(
            store: store,
            ctaTitle: scheduling ? "SETTING…" : "SET REMINDER",
            ctaEnabled: !scheduling && !store.draft.reminderWeekdays.isEmpty,
            onCTA: schedule,
            skipTitle: "Skip for now",
            onSkip: { store.advance() }   // final step — advancing past it completes onboarding
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(BaselineColor.accent)
                    .frame(width: 64, height: 64)
                    .background(RoundedRectangle(cornerRadius: 16).fill(BaselineColor.surface))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                OnboardingHeadline("SAME TIME\nEVERY MORNING", size: 28)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
                Text("Consistency is the primary driver of an accurate baseline. We'll remind you to measure upon waking.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(BaselineColor.textMid)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)

                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .colorScheme(.dark)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipped()
                    .padding(.top, 10)

                HStack(spacing: 10) {
                    ForEach(1...7, id: \.self) { weekday in
                        let on = store.draft.reminderWeekdays.contains(weekday)
                        Button {
                            Haptics.select()
                            if on {
                                store.draft.reminderWeekdays.remove(weekday)
                            } else {
                                store.draft.reminderWeekdays.insert(weekday)
                            }
                        } label: {
                            Text(weekdaySymbols[weekday - 1])
                                .font(.bMono(13, .bold))
                                .foregroundStyle(on ? BaselineColor.base : BaselineColor.textFaint)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(on ? BaselineColor.accent : BaselineColor.surface))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                Spacer(minLength: 12)
            }
        }
        .onAppear {
            time = Calendar.current.date(
                from: DateComponents(hour: store.draft.reminderHour, minute: store.draft.reminderMinute)
            ) ?? time
        }
    }

    private func schedule() {
        scheduling = true
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        store.draft.reminderHour = components.hour ?? 6
        store.draft.reminderMinute = components.minute ?? 30
        Task {
            let allowed = await NotificationService.requestAuthorization()
            if allowed {
                await NotificationService.scheduleMorningReminder(
                    hour: store.draft.reminderHour,
                    minute: store.draft.reminderMinute,
                    weekdays: store.draft.reminderWeekdays
                )
                store.draft.reminderScheduled = true
            }
            scheduling = false
            Haptics.success()
            store.advance()
        }
    }
}
