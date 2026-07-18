import SwiftUI

/// Hosts the whole onboarding flow: switches on the store's current step with a directional
/// slide, and persists the profile to Firestore the moment onboarding completes (auth is a
/// mid-flow step, so a user always exists by then).
struct OnboardingContainerView: View {
    @Bindable var store: OnboardingStore
    @Environment(AuthViewModel.self) private var authVM
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()

            stepView
                .id(store.step)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
        }
        .animation(.easeInOut(duration: 0.32), value: store.step)
        .onChange(of: store.isComplete) { _, complete in
            if complete {
                // Promote the onboarding choice to the app-wide default so every metric field and
                // body input opens in the athlete's chosen system from the first launch.
                settings.unitSystem = store.draft.unitSystem
                saveProfile()
            }
        }
    }

    @ViewBuilder
    private var stepView: some View {
        switch store.step {
        case .welcome: WelcomeStepView(store: store)
        case .carousel: CarouselStepView(store: store)
        case .name: NameStepView(store: store)
        case .objective: ObjectiveStepView(store: store)
        case .rightPlace: RightPlaceStepView(store: store)
        case .attribution: AttributionStepView(store: store)
        case .buildScoreIntro: BuildScoreIntroStepView(store: store)
        case .formula: FormulaStepView(store: store)
        case .heartSource: HeartSourceStepView(store: store)
        case .strapPairing: StrapPairingStepView(store: store)
        case .appleHealth: AppleHealthStepView(store: store)
        case .firstReadingIntro: FirstReadingIntroStepView(store: store)
        case .firstReading: FirstReadingStepView(store: store)
        case .checkIn: CheckInStepView(store: store)
        case .scoreReveal: ScoreRevealStepView(store: store)
        case .auth: AuthStepView(store: store)
        case .trainingExperience: TrainingExperienceStepView(store: store)
        case .gender: GenderStepView(store: store)
        case .age: AgeStepView(store: store)
        case .units: UnitsStepView(store: store)
        case .height: HeightStepView(store: store)
        case .weight: WeightStepView(store: store)
        case .outlook: OutlookStepView(store: store)
        case .commitment: CommitmentStepView(store: store)
        case .reminder: ReminderStepView(store: store)
        }
    }

    private func saveProfile() {
        guard let uid = authVM.user?.uid else { return }
        let draft = store.draft
        Task {
            do {
                try await UserRepository().saveProfile(uid: uid, draft: draft, onboardingCompleted: true)
            } catch {
                // Non-fatal: local state is the source of truth for the session; the write
                // retries on next launch via RootView's reconcile hook.
                print("Profile save failed: \(error)")
            }
        }
    }
}
