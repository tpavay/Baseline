import SwiftUI
import SwiftData

/// The signed-in app shell — three intents, three tabs: **Today** (decision), **Plan** (the week-level
/// surface that opens/starts/resumes any workout), **Profile** (setup). History and workout execution
/// are *capabilities* reached through Plan, not primary destinations.
struct MainTabView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "square.grid.2x2") }

            PlanView()
                .tabItem { Label("Plan", systemImage: "calendar") }

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
        .environment(WorkoutStore(units: AppSettings()))
        .environment(PlanStore(context: container.mainContext))
        .modelContainer(container)
}
