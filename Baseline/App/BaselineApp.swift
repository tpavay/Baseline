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

    init() {
        FirebaseApp.configure()
        authVM = AuthViewModel()
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
        .modelContainer(for: [Reading.self, ReadinessEntry.self])
    }
}
