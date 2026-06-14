@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import GoogleSignIn
import AuthenticationServices
import UIKit

enum AuthError: LocalizedError {
    case noClientID
    case noPresentingViewController
    case noIDToken
    case invalidAppleCredential
    case appleFailed(String)
    case signInFailed(String)
    case signOutFailed(String)

    /// User-facing copy (technical detail stays in the associated value for logging).
    var errorDescription: String? {
        switch self {
        case .noClientID, .noPresentingViewController, .noIDToken, .invalidAppleCredential:
            return "Something went wrong. Please try again."
        case .appleFailed, .signInFailed:
            return "Unable to sign in. Please check your connection and try again."
        case .signOutFailed:
            return "Unable to sign out. Please try again."
        }
    }
}

/// Owns the provider sign-in flows (Apple + Google) and exchanges their credentials for a
/// Firebase session. Pure nonce/hash live in `AppleNonce`; this type handles the UIKit +
/// Firebase side, so it is `@MainActor` (drives `ASAuthorizationController` and reads the
/// active window). User cancellation surfaces as `CancellationError` so callers can stay quiet.
@MainActor
final class AuthService: NSObject {

    private var currentNonce: String?
    private var appleContinuation: CheckedContinuation<User, Error>?

    // MARK: - Google

    @discardableResult
    func signInWithGoogle() async throws -> User {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw AuthError.noClientID
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

        guard let presenter = Self.topViewController() else {
            throw AuthError.noPresentingViewController
        }

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else {
                throw AuthError.noIDToken
            }
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
            return try await Auth.auth().signIn(with: credential).user
        } catch let error as GIDSignInError where error.code == .canceled {
            throw CancellationError()
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.signInFailed(error.localizedDescription)
        }
    }

    // MARK: - Apple

    @discardableResult
    func signInWithApple() async throws -> User {
        try await withCheckedThrowingContinuation { continuation in
            appleContinuation = continuation

            let nonce = AppleNonce.random()
            currentNonce = nonce

            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = AppleNonce.sha256(nonce)

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    // MARK: - Sign out

    func signOut() throws {
        do {
            GIDSignIn.sharedInstance.signOut()
            try Auth.auth().signOut()
        } catch {
            throw AuthError.signOutFailed(error.localizedDescription)
        }
    }

    // MARK: - Presentation helpers

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    private static func topViewController() -> UIViewController? {
        var top = keyWindow()?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - Apple authorization callbacks

extension AuthService: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        Self.keyWindow() ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController,
                                didCompleteWithAuthorization authorization: ASAuthorization) {
        let continuation = appleContinuation
        appleContinuation = nil

        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            continuation?.resume(throwing: AuthError.invalidAppleCredential)
            return
        }
        guard let nonce = currentNonce else {
            continuation?.resume(throwing: AuthError.appleFailed("Missing nonce — no request in flight."))
            return
        }
        guard let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            continuation?.resume(throwing: AuthError.appleFailed("Unable to read Apple identity token."))
            return
        }

        let firebaseCredential = OAuthProvider.credential(
            providerID: .apple,
            idToken: idToken,
            rawNonce: nonce
        )

        Task {
            do {
                let user = try await Auth.auth().signIn(with: firebaseCredential).user
                continuation?.resume(returning: user)
            } catch {
                continuation?.resume(throwing: AuthError.appleFailed(error.localizedDescription))
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                didCompleteWithError error: Error) {
        let continuation = appleContinuation
        appleContinuation = nil

        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            continuation?.resume(throwing: CancellationError())
        } else {
            continuation?.resume(throwing: AuthError.appleFailed(error.localizedDescription))
        }
    }
}
