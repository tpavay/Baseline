import SwiftUI
import SwiftData

/// The signed-in app shell: Today / History / Profile. The morning loop lives on Today; History
/// is the reading archive; Profile holds the athlete's setup, devices, and integrations.
struct MainTabView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "square.grid.2x2") }

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
        .modelContainer(for: [Reading.self, ReadinessEntry.self], inMemory: true)
}
