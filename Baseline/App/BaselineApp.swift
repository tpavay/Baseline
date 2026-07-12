import FirebaseCore
import GoogleSignIn
import SwiftData
import SwiftUI

@main
struct BaselineApp: App {
    @State private var authVM: AuthViewModel
    @State private var settings = AppSettings()
    @State private var bluetooth = BluetoothManager()
    @State private var health = HealthService()
    @State private var context = TrainingContextStore()
    @State private var workouts = WorkoutStore()
    @State private var plan: PlanStore
    private let container: ModelContainer

    init() {
        FirebaseApp.configure()
        authVM = AuthViewModel()
        // One container for everything on-device; the Plan schema is registered from day one.
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models
        let c = try! ModelContainer(for: Schema(models))
        container = c
        _plan = State(initialValue: PlanStore(context: c.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // Let Google Sign-In consume its OAuth redirect.
                    _ = GIDSignIn.sharedInstance.handle(url)
                }
        }
        .environment(authVM)
        .environment(settings)
        .environment(bluetooth)
        .environment(health)
        .environment(context)
        .environment(workouts)
        .environment(plan)
        .modelContainer(container)
    }
}
