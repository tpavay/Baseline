import SwiftUI

/// Signed-out landing: the Apple + Google sign-in gate. Dark "calm precision" — the brand
/// accent stays *off* the provider buttons (it's reserved for recovery/feature surfaces).
struct AuthView: View {
    @Environment(AuthViewModel.self) private var authVM

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                header
                Spacer()
                buttons
                legal
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Text("Baseline")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(BaselineColor.textHi)
            Text("One reading. One decision.\nTrain the right dose today.")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(BaselineColor.textMid)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
    }

    private var buttons: some View {
        VStack(spacing: 14) {
            if let errorMessage = authVM.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BaselineColor.zoneRed)
                    .multilineTextAlignment(.center)
            }

            ProviderButton(
                title: "Continue with Apple",
                icon: .sfSymbol("apple.logo"),
                foreground: .black,
                background: .white,
                isLoading: authVM.state == .authenticatingApple,
                isDisabled: authVM.state.isBusy
            ) {
                Task { await authVM.signInWithApple() }
            }

            ProviderButton(
                title: "Continue with Google",
                icon: .googleG,
                foreground: BaselineColor.textHi,
                background: BaselineColor.surface,
                border: BaselineColor.line,
                isLoading: authVM.state == .authenticatingGoogle,
                isDisabled: authVM.state.isBusy
            ) {
                Task { await authVM.signInWithGoogle() }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: authVM.state)
        .animation(.easeInOut(duration: 0.2), value: authVM.errorMessage)
    }

    private var legal: some View {
        Text("By continuing you agree to our Terms and Privacy Policy.")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(BaselineColor.textFaint)
            .multilineTextAlignment(.center)
            .padding(.top, 18)
    }
}

#Preview {
    AuthView()
        .environment(AuthViewModel())
}
