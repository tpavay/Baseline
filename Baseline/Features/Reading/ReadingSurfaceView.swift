import SwiftUI

/// Copy/appearance differences between the camera and strap reading surfaces. Data-only.
struct ReadingSurfaceStyle: Sendable {
    /// Countdown greeting ("Happy to see you back" / "Signal locked").
    var greeting: String
    /// Encouragement shown during the read.
    var encouragement: String
    /// Whether to lay a legibility scrim over the background (camera feed needs it).
    var scrim: Bool

    static let camera = ReadingSurfaceStyle(
        greeting: "Get ready", encouragement: "You're doing great", scrim: true
    )
    static let strap = ReadingSurfaceStyle(
        greeting: "Get ready", encouragement: "You're doing great", scrim: false
    )
}

/// The shared full-screen reading surface used by both the camera and strap wrappers, across the
/// intro → connecting → countdown → reading phases. The `background` closure is rendered once at
/// the ZStack root so it (e.g. the live `CameraPreview`) keeps a stable identity across phase
/// changes — critical for the camera, whose torch drops if the preview view is ever rebuilt.
struct ReadingSurfaceView<Background: View>: View {
    var session: ReadingSession
    let style: ReadingSurfaceStyle
    /// Optional coaching line during connecting (camera coverage guidance).
    var coaching: String? = nil
    var coachingColor: Color = BaselineColor.textMid
    @ViewBuilder let background: Background
    let onGotIt: () -> Void
    let onStop: () -> Void

    private var percent: Int { Int((session.elapsed / max(session.duration, 1) * 100).rounded()) }
    private var hrString: String { session.currentHR > 0 ? "\(session.currentHR)" : "—" }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            if style.scrim {
                LinearGradient(
                    colors: [.black.opacity(0.55), .black.opacity(0.1), .black.opacity(0.65)],
                    startPoint: .top, endPoint: .bottom
                ).ignoresSafeArea()
            }

            switch session.phase {
            case .intro:                       introOverlay
            case .connecting, .preview:        connectingOverlay
            case .countdown:                   countdownOverlay
            case .reading:                     readingOverlay
            case .complete, .failed:           EmptyView()
            }
        }
    }

    // MARK: - Overlays

    private var introOverlay: some View {
        VStack(spacing: 0) {
            Spacer()
            Image("CameraHRVGuidance")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 220, maxHeight: 220)
            Text("Put your finger over the camera to measure your heart rate variability")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(BaselineColor.textHi)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 34).padding(.horizontal, 28)
            Text("Make sure your finger covers both the camera and the flash.")
                .font(.system(size: 13)).foregroundStyle(BaselineColor.textMid)
                .multilineTextAlignment(.center)
                .padding(.top, 12).padding(.horizontal, 34)
            Spacer()
            Button(action: onGotIt) { Text("GOT IT") }
                .buttonStyle(InstrumentButtonStyle())
                .padding(.bottom, 26)
        }
        .padding(.horizontal, 24)
    }

    private var connectingOverlay: some View {
        VStack(spacing: 0) {
            Spacer()
            ProgressView().tint(BaselineColor.accent).scaleEffect(1.3)
            Text(coaching ?? session.captureStatus)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(coaching == nil ? BaselineColor.textMid : coachingColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 40)
                .padding(.top, 22).padding(.horizontal, 30)
            Spacer()
            stopButton
        }
        .padding(.horizontal, 24)
    }

    private var countdownOverlay: some View {
        VStack(spacing: 0) {
            Spacer()
            Text(style.greeting)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            ZStack {
                Circle().stroke(.white.opacity(0.4), lineWidth: 3)
                    .frame(width: 190, height: 190)
                Text("\(session.countdownRemaining)")
                    .font(.system(size: 84, weight: .heavy)).italic()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            .padding(.top, 40)
            // While counting down we're also acquiring the signal — coach the finger placement.
            Text(coaching ?? "Get ready…")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(coaching == nil ? .white.opacity(0.8) : coachingColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 40)
                .padding(.top, 24).padding(.horizontal, 30)
            Spacer()
            stopButton
        }
        .padding(.horizontal, 24)
    }

    private var readingOverlay: some View {
        VStack(spacing: 0) {
            // Heart rate — big and white, heart + number + bpm inline (Welltory-style).
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "heart.fill").font(.system(size: 28)).foregroundStyle(.white)
                Text(hrString)
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(.white).contentTransition(.numericText())
                Text("bpm")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)

            Spacer()

            // ECG-style sweep: a draw-head crosses left→right and wraps, overwriting the old trace
            // (à la Welltory). TimelineView drives the ~30fps sweep between the session's 100ms ticks.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                BeatWaveform(beats: session.beats, now: session.liveElapsed)
            }
            .frame(height: 150)

            Spacer()

            rotatingMessage
                .frame(height: 66)
                .padding(.horizontal, 16)

            // Progress ring — fills as the reading completes, percentage in the centre.
            progressRing.padding(.top, 4)
            stopButton
        }
        .padding(.horizontal, 24)
    }

    /// Big educational/encouragement copy that swaps every 5s with a cross-fade (Welltory-style).
    private var rotatingMessage: some View {
        let messages = [
            "You're doing great",
            "Hold still and breathe naturally",
            "Your heart's rhythm reveals how recovered you are",
            "A calm, steady breath gives the cleanest read",
            "Every beat is data — just let it flow",
        ]
        let idx = Int(session.elapsed / 5) % messages.count
        return ZStack {
            Text(messages[idx])
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .id(idx)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.6), value: idx)
    }

    private var progressRing: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 5)
            Circle()
                .trim(from: 0, to: CGFloat(session.liveElapsed / max(session.duration, 1)))
                .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(percent)%")
                .font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .frame(width: 70, height: 70)
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Text("STOP")
                .font(.bMono(13, .bold)).tracking(2)
                .foregroundStyle(BaselineColor.textHi)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(BaselineColor.surface.opacity(style.scrim ? 0.85 : 1))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BaselineColor.line, lineWidth: 1)))
        }
        .buttonStyle(.plain)
        .padding(.top, 12).padding(.bottom, 26)
    }
}

/// ECG monitor waveform (à la Welltory): a fixed set of evenly-spaced, identical QRS spikes — the
/// line always looks the same — with the real R-R interval shown as a number between peaks. A
/// draw-head advances one peak per beat at a *variable* speed (fast for short intervals, slow for
/// long), tracing the line via a blanking gap and wrapping left→right, overwriting the old numbers.
struct BeatWaveform: View {
    let beats: [BeatMark]
    let now: TimeInterval
    /// Peaks always visible on screen.
    var peaks: Int = 5

    var body: some View {
        GeometryReader { geo in
            trace(w: geo.size.width, h: geo.size.height)
        }
    }

    /// Head position in "peak units": integer at a beat, interpolating toward the next peak by how
    /// far through the current interval we are (so the head slows/speeds with the real R-R).
    private func headPhase() -> Double {
        guard let last = beats.last else { return 0 }
        let interval = max(Double(last.intervalMs) / 1000, 0.3)
        let frac = min(max((now - last.t) / interval, 0), 1)
        return Double(beats.count - 1) + frac
    }

    /// The interval (ms) currently sitting on peak `k` — the most recent beat whose index maps to
    /// that peak. nil until a beat has reached it.
    private func intervalOnPeak(_ k: Int) -> Int? {
        let count = beats.count
        guard count > 0 else { return nil }
        let last = count - 1
        let j = last - (((last % peaks) - k + peaks) % peaks)
        return j >= 0 ? beats[j].intervalMs : nil
    }

    private func trace(w: CGFloat, h: CGFloat) -> some View {
        let n = peaks
        let cell = w / CGFloat(n)
        let base = h * 0.56, r = h * 0.36, s = h * 0.22, q = h * 0.04
        let px: (Int) -> CGFloat = { (CGFloat($0) + 0.5) * cell }

        var headX = ((CGFloat(headPhase()) + 0.5) / CGFloat(n) * w).truncatingRemainder(dividingBy: w)
        if headX < 0 { headX += w }
        let trail = cell * 1.5   // length of the bright "pen" glow behind the head

        // The consistent template: baseline + n identical, evenly-spaced spikes.
        let template = Path { p in
            p.move(to: CGPoint(x: 0, y: base))
            for k in 0..<n {
                let x = px(k)
                p.addLine(to: CGPoint(x: x - 6, y: base))
                p.addLine(to: CGPoint(x: x - 3, y: base + q))   // Q
                p.addLine(to: CGPoint(x: x, y: base - r))       // R
                p.addLine(to: CGPoint(x: x + 3, y: base + s))   // S
                p.addLine(to: CGPoint(x: x + 6, y: base))
            }
            p.addLine(to: CGPoint(x: w, y: base))
        }

        return ZStack {
            // Persistent faint line — always the same 5 peaks, so the trace never blanks or flashes.
            template.stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            // Bright pen: a short glowing segment that follows the head, tracing each spike as it
            // sweeps past — the "drawing in". Masked to a trail-width gradient ending at the head.
            template
                .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .shadow(color: .white.opacity(0.6), radius: 4)
                .mask(
                    LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing)
                        .frame(width: trail, height: h)
                        .position(x: headX - trail / 2, y: h / 2)
                )

            // Leading-edge dot.
            Circle().fill(.white).frame(width: 7, height: 7)
                .shadow(color: .white.opacity(0.7), radius: 4)
                .position(x: headX, y: base)

            // Interval numbers between peaks (just the number).
            ForEach(0..<n, id: \.self) { k in
                if let ms = intervalOnPeak(k) {
                    Text("\(ms)")
                        .font(.bMono(11, .medium)).foregroundStyle(.white.opacity(0.85))
                        .position(x: max(12, px(k) - cell * 0.5), y: max(10, base - r - 14))
                }
            }
        }
    }
}
