import SwiftUI
import SwiftData

/// The signed-in app shell — three intents, three tabs: **Today** (decision), **Plan** (the week-level
/// surface that opens/starts/resumes any workout), **Profile** (setup). History and workout execution
/// are *capabilities* reached through Plan, not primary destinations.
struct MainTabView: View {
    @State private var selection: MainTab

    init(initialSelection: MainTab = .today) {
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                TodayView()
                    .tag(MainTab.today)

            PlanView()
                    .tag(MainTab.plan)

            ProfileView()
                    .tag(MainTab.profile)
            }
            .toolbar(.hidden, for: .tabBar)

            BaselineTabBar(selection: $selection)
        }
        .ignoresSafeArea(.keyboard)
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
