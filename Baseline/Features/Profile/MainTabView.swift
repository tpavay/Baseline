import SwiftUI
import SwiftData

/// The signed-in app shell — four intents, four tabs: **Today** (decision), **Plan** (planning —
/// future), **Workout** (execution), **Profile** (setup). History is a *capability* reached through
/// these surfaces (reading history hangs off Today), not a primary destination. The Plan tab lands
/// with the Plan Engine; until then the shell is Today / Workout / Profile.
struct MainTabView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "square.grid.2x2") }

            WorkoutView()
                .tabItem { Label("Workout", systemImage: "figure.strengthtraining.traditional") }

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person") }
        }
        .tint(BaselineColor.accent)
    }
}

#Preview {
    MainTabView()
        .environment(AuthViewModel())
        .environment(AppSettings())
        .environment(BluetoothManager())
        .environment(HealthService())
        .environment(OnboardingStore())
        .environment(WorkoutStore())
        .modelContainer(for: [Reading.self, ReadinessEntry.self], inMemory: true)
}
