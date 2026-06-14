@preconcurrency import FirebaseAuth
import FirebaseCore
import Foundation
import Observation

/// What the sign-in gate is currently doing. The per-provider busy cases drive the button
/// spinners; `isBusy` disables the other provider while one is in flight.
enum AuthFlowState: Equatable {
    case unauthenticated
    case authenticatingApple
    case authenticatingGoogle
    case authenticated

    var isBusy: Bool { self == .authenticatingApple || self == .authenticatingGoogle }
}

/// Observable auth state for the UI: the current Firebase user, the in-flight provider, and
/// any user-facing error. Wraps `AuthService` and listens to Firebase auth changes so the
/// root gate reacts to sign-in/out automatically. Imports no SwiftUI (per project rules).
@MainActor
@Observable
final class AuthViewModel {
    private(set) var user: User?
    private(set) var state: AuthFlowState = .unauthenticated
    var errorMessage: String?

    private let service = AuthService()
    private var authStateHandle: AuthStateDidChangeListenerHandle?

    init() {
        // Guard so SwiftUI previews / unit hosts without `FirebaseApp.configure()` don't trap.
        guard FirebaseApp.app() != nil else { return }

        user = Auth.auth().currentUser
        state = user == nil ? .unauthenticated : .authenticated

        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self else { return }
            self.user = user
            if user != nil {
                self.state = .authenticated
            } else if !self.state.isBusy {
                // Only resolve to signed-out when not mid interactive flow (whose busy state
                // the buttons are showing); a cancelled flow resets itself.
                self.state = .unauthenticated
            }
        }
    }

    func signInWithApple() async {
        await run(.authenticatingApple) { try await $0.signInWithApple() }
    }

    func signInWithGoogle() async {
        await run(.authenticatingGoogle) { try await $0.signInWithGoogle() }
    }

    func signOut() {
        do {
            try service.signOut()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Shared sign-in scaffolding: flip to the busy state, run the provider flow, and let the
    /// auth-state listener promote us to `.authenticated`. Cancellation stays silent.
    private func run(_ busy: AuthFlowState,
                     _ action: (AuthService) async throws -> User) async {
        state = busy
        errorMessage = nil
        do {
            _ = try await action(service)
        } catch is CancellationError {
            state = .unauthenticated
        } catch {
            errorMessage = error.localizedDescription
            state = .unauthenticated
        }
    }
}
