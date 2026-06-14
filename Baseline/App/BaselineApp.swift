import FirebaseCore
import GoogleSignIn
import SwiftUI

@main
struct BaselineApp: App {
    @State private var authVM: AuthViewModel

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
    }
}
