import SwiftUI
import SwiftData

/// The signed-in app shell. Target shape is **Today** (decision), **Plan** (the week-level surface),
/// **Profile** (setup) — History is a *capability* reached through these, not a primary destination.
/// During Slice 1 the standalone **Workout** tab stays reachable while the Plan card → WorkoutView
/// execution reuse lands; the next slice retires it, leaving Today / Plan / Profile.
struct MainTabView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "square.grid.2x2") }

            PlanView()
                .tabItem { Label("Plan", systemImage: "calendar") }

            WorkoutView()
                .tabItem { Label("Workout", systemImage: "figure.strengthtraining.traditional") }

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person") }
        }
        .tint(BaselineColor.accent)
    }
}

#Preview {
    let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
    let container = try! ModelContainer(for: Schema(models),
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    return MainTabView()
        .environment(AuthViewModel())
        .environment(AppSettings())
        .environment(BluetoothManager())
        .environment(HealthService())
        .environment(OnboardingStore())
        .environment(WorkoutStore())
        .environment(PlanStore(context: container.mainContext))
        .modelContainer(container)
}
