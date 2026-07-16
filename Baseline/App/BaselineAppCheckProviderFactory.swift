import FirebaseAppCheck
import FirebaseCore

/// Debug builds use an explicitly registered Firebase debug token. Distribution builds use App Attest.
/// The factory is installed before `FirebaseApp.configure()` so every Firebase product can attach a token.
final class BaselineAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
#if DEBUG
        AppCheckDebugProvider(app: app)
#else
        AppAttestProvider(app: app)
#endif
    }
}
