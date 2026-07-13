import SwiftData
import SwiftUI

/// Root gate. Onboarding (which contains auth as a mid-flow step) runs until complete; after
/// that, signed-in users get the app and signed-out users get the standalone auth gate.
struct RootView: View {
    @Environment(AuthViewModel.self) private var authVM
    @Environment(PlanStore.self) private var plan
    @Environment(WorkoutStore.self) private var workouts
    @State private var onboarding = OnboardingStore()

    var body: some View {
        Group {
            // Onboarding temporarily bypassed — go straight from auth into the app so a fresh
            // install lands on the auth screen, then the tabs. Restore by re-adding the
            // `if !onboarding.isComplete { OnboardingContainerView(store: onboarding) } else if` gate.
            if authVM.state == .authenticated {
                MainTabView()
                    .environment(onboarding)
            } else {
                AuthView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: authVM.state)
        .animation(.easeInOut(duration: 0.3), value: onboarding.isComplete)
        .task { await reconcileProfile() }
        .task { bindWorkoutsToPlan() }
    }

    /// After migration, make the shared `WorkoutStore` (the agent's editing surface) a live view of
    /// today's scheduled workout, so the coach's create/edit/log/lifecycle flow into the Plan repository
    /// — one mutation path for manual and agent alike.
    private func bindWorkoutsToPlan() {
        PlanMigrator.migrateIfNeeded(into: plan, workouts: workouts)
        workouts.makeTodayScheduled = { [plan] w in plan.addTodayScheduled(workout: w) }
        if let today = plan.todayScheduled() {
            workouts.bind(plan.sink(forScheduled: today.id), coalesceContent: false)
        }
    }

    /// Idempotent retry of the profile write in case the completion-time save failed offline.
    private func reconcileProfile() async {
        guard onboarding.isComplete, let uid = authVM.user?.uid else { return }
        try? await UserRepository().saveProfile(uid: uid, draft: onboarding.draft, onboardingCompleted: true)
    }
}

#Preview {
    let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
    let container = try! ModelContainer(for: Schema(models),
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    return RootView()
        .environment(AuthViewModel())
        .environment(AppSettings())
        .environment(BluetoothManager())
        .environment(HealthService())
        .environment(WorkoutStore())
        .environment(PlanStore(context: container.mainContext))
        .modelContainer(container)
}
