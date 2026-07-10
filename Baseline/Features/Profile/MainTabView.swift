import SwiftUI
import SwiftData

/// The signed-in app shell: Today / Workout / History / Profile. The morning loop lives on Today;
/// Workout is the manual execution surface; History is the reading archive; Profile holds setup.
struct MainTabView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "square.grid.2x2") }

            WorkoutView()
                .tabItem { Label("Workout", systemImage: "figure.strengthtraining.traditional") }

            NavigationStack { ReadingHistoryView() }
                .tabItem { Label("History", systemImage: "chart.bar") }

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
