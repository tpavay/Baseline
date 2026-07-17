import SwiftUI

// Act 0–1: welcome → value carousel → name → objective → affirmation → attribution.

// MARK: - Welcome (splash)

struct WelcomeStepView: View {
    let store: OnboardingStore

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            RadialGradient(
                colors: [BaselineColor.accent.opacity(0.22), .clear],
                center: .center, startRadius: 30, endRadius: 300
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                Text("BASELINE")
                    .font(.system(size: 40, weight: .heavy))
                    .italic()
                    .foregroundStyle(BaselineColor.textHi)
                    .tracking(2)
                Image("BaselineIconNoBackground")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 150, height: 150)
                    .padding(.top, 36)
                Text("DEFINE YOUR TRUE READINESS")
                    .font(.bMono(14, .medium))
                    .tracking(3)
                    .foregroundStyle(BaselineColor.textMid)
                    .padding(.top, 36)
                Spacer()

                Button {
                    Haptics.tap()
                    store.advance()
                } label: {
                    Text("GET STARTED")
                }
                .buttonStyle(InstrumentButtonStyle())

                QuietLinkButton(title: "I already have an account") {
                    store.skipToSignIn()
                }
                .padding(.top, 16)
                .padding(.bottom, 18)
            }
            .padding(.horizontal, 26)
        }
    }
}

// MARK: - Value carousel (4 slides, universal values only)

struct CarouselStepView: View {
    let store: OnboardingStore
    @State private var slide = 0

    private var slides: [OnboardingCopy.CarouselSlide] { OnboardingCopy.carousel }
    private var isLast: Bool { slide == slides.count - 1 }

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $slide) {
                    ForEach(slides) { s in
                        CarouselSlideView(slide: s)
                            .tag(s.id)
                            .padding(.horizontal, 26)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .onChange(of: slide) { _, _ in Haptics.select() }

                PageDots(count: slides.count, index: slide)
                    .padding(.bottom, 22)

                Button {
                    Haptics.tap()
                    if isLast {
                        store.advance()
                    } else {
                        withAnimation(.easeInOut(duration: 0.3)) { slide += 1 }
                    }
                } label: {
                    Text("CONTINUE")
                }
                .buttonStyle(InstrumentButtonStyle())
                .padding(.horizontal, 26)
                .padding(.bottom, 18)
            }
        }
    }
}

private struct CarouselSlideView: View {
    let slide: OnboardingCopy.CarouselSlide

    private var bandColor: Color {
        switch slide.band {
        case "RECOVERED": BaselineColor.zoneGreen
        case "MODERATE": BaselineColor.zoneAmber
        case "STRAINED": BaselineColor.zoneRed
        default: BaselineColor.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            // App-snapshot card — a real piece of the product, not an illustration.
            Group {
                if let score = slide.score {
                    VStack(spacing: 20) {
                        ReadinessGauge(score: score, fill: bandColor, label: slide.band, size: 190)
                        GuidanceChip(
                            icon: slide.score == 54 ? "leaf.fill" : "bolt.fill",
                            iconColor: bandColor,
                            title: slide.chipTitle,
                            subtitle: slide.chipSubtitle.isEmpty ? nil : slide.chipSubtitle
                        )
                    }
                } else {
                    formulaSnapshot
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(BaselineColor.surface.opacity(0.55))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(BaselineColor.line, lineWidth: 1))
            )

            OnboardingHeadline(slide.headline.uppercased(), size: 30)
                .padding(.top, 24)
            Text(slide.support)
                .font(.system(size: 14.5))
                .foregroundStyle(BaselineColor.textMid)
                .lineSpacing(3)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 16)
        }
    }

    /// Slide 4's visual: the formula toggles, foreshadowing the real config screen.
    private var formulaSnapshot: some View {
        VStack(alignment: .leading, spacing: 12) {
            InstrumentLabel("READINESS FORMULA", tracking: 2)
            row(icon: "moon.fill", title: "Sleep Analysis", on: true)
            row(icon: "checklist", title: "Daily Check-in", on: true)
            row(icon: "heart.fill", title: "Heart Rate Data", on: true)
            HStack(spacing: 12) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BaselineColor.textFaint)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(BaselineColor.surface))
                Text("More metrics coming")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BaselineColor.textFaint)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
    }

    private func row(icon: String, title: String, on: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? BaselineColor.accent : BaselineColor.textFaint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(BaselineColor.surface))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? BaselineColor.textHi : BaselineColor.textFaint)
            Spacer()
            Capsule()
                .fill(on ? BaselineColor.accent : BaselineColor.line)
                .frame(width: 40, height: 24)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 20, height: 20).padding(2)
                }
        }
    }
}

// MARK: - Name

struct NameStepView: View {
    @Bindable var store: OnboardingStore
    @FocusState private var focused: Bool

    var body: some View {
        OnboardingStepScaffold(store: store, ctaEnabled: store.canAdvance) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 30)
                OnboardingHeadline("What's your name?")

                HStack(spacing: 12) {
                    Image(systemName: "person")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(BaselineColor.accent)
                    TextField("", text: $store.draft.name, prompt: Text("Enter your name").foregroundStyle(BaselineColor.textFaint))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(BaselineColor.textHi)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.continue)
                        .focused($focused)
                        .onSubmit { if store.canAdvance { store.advance() } }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(BaselineColor.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(focused ? BaselineColor.accent : BaselineColor.line, lineWidth: 1)
                        )
                )
                .padding(.top, 28)

                Text("You can change this anytime in settings.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(BaselineColor.textFaint)
                    .padding(.top, 12)
                Spacer()
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Primary objective

struct ObjectiveStepView: View {
    @Bindable var store: OnboardingStore

    private let icons: [TrainingObjective: String] = [
        .optimizeLoad: "gauge.with.needle",
        .preventInjury: "shield.lefthalf.filled",
        .competitive: "trophy",
        .longevity: "infinity",
    ]

    var body: some View {
        OnboardingStepScaffold(store: store, ctaEnabled: store.canAdvance) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline("What's your\nprimary objective?", size: 28)

                VStack(spacing: 12) {
                    ForEach(TrainingObjective.allCases) { objective in
                        SelectableCard(
                            title: objective.title,
                            isSelected: store.draft.objective == objective,
                            action: { store.draft.objective = objective }
                        ) {
                            Image(systemName: icons[objective] ?? "circle")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(BaselineColor.accent)
                                .frame(width: 34)
                        }
                    }
                }
                .padding(.top, 22)
            }
        }
    }
}

// MARK: - "You're in the right place." (objective-mirrored)

struct RightPlaceStepView: View {
    let store: OnboardingStore

    private var objective: TrainingObjective { store.draft.objective ?? .optimizeLoad }

    var body: some View {
        OnboardingStepScaffold(store: store) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline("You're in the\nright place.")
                (Text("Baseline was made for people like you — ready to ")
                    .foregroundStyle(BaselineColor.textMid)
                 + Text(OnboardingCopy.goalPhrase(for: objective))
                    .foregroundStyle(BaselineColor.accent)
                    .bold())
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 14) {
                    Text("“\(OnboardingCopy.founderQuote(for: objective))”")
                        .font(.system(size: 14.5, weight: .medium))
                        .italic()
                        .foregroundStyle(BaselineColor.textHi)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Circle().fill(BaselineColor.accent).frame(width: 6, height: 6)
                        InstrumentLabel("TYLER · FOUNDER", tracking: 1.5)
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(BaselineColor.surface)
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(BaselineColor.line, lineWidth: 1))
                )
                .padding(.top, 32)

                Spacer()
            }
        }
    }
}

// MARK: - Attribution (asked after value, never before)

struct AttributionStepView: View {
    @Bindable var store: OnboardingStore

    var body: some View {
        OnboardingStepScaffold(store: store, ctaEnabled: store.canAdvance) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline("How did you\nhear about us?", size: 28)

                VStack(spacing: 10) {
                    ForEach(AcquisitionSource.allCases) { source in
                        SelectableCard(
                            title: source.title,
                            isSelected: store.draft.acquisition == source,
                            action: { store.draft.acquisition = source }
                        ) { EmptyView() }
                    }
                }
                .padding(.top, 22)
            }
        }
    }
}
