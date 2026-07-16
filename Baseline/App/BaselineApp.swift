import FirebaseAppCheck
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
    private let workoutImportCoordinator: WorkoutImportCoordinator

    init() {
        AppCheck.setAppCheckProviderFactory(BaselineAppCheckProviderFactory())
        FirebaseApp.configure()
        workoutImportCoordinator = WorkoutImportCoordinator()
        authVM = AuthViewModel()
        // One container for everything on-device; the Plan schema is registered from day one.
        let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models + SleepSchema.models
        let c = try! ModelContainer(for: Schema(models))
        container = c
        _plan = State(initialValue: PlanStore(context: c.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            appContent
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // Let Google Sign-In consume its OAuth redirect.
                    _ = GIDSignIn.sharedInstance.handle(url)
                }
                .task {
                    await workoutImportCoordinator.cleanup()
                }
                .task {
                    // Sleep Engine go-live: hydrate the canonical night store from HealthKit once at
                    // launch. Safe pre-authorization — HealthService.sleepSamples returns empty without
                    // auth, so no nights are written and the decision seam falls back honestly.
                    let sleepRepo = SwiftDataSleepRepository(context: container.mainContext)
                    let orchestrator = SleepBackfillOrchestrator(
                        provider: health, nightStore: sleepRepo, cursorStore: sleepRepo)
                    await orchestrator.importRecentNights()
                    await orchestrator.continueBackfill()
                    await orchestrator.syncDelta()
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

    @ViewBuilder private var appContent: some View {
#if DEBUG
        if WorkoutImportDebugFixtures.isEnabled {
            WorkoutImportView(
                debugSession: WorkoutImportDebugFixtures.session,
                debugJob: WorkoutImportDebugFixtures.job
            )
        } else {
            RootView()
        }
#else
        RootView()
#endif
    }
}
