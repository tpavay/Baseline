import SwiftUI

/// Root gate: signed-out → `AuthView`; signed-in → the app (the HRV reading spike for now,
/// becoming the Today / Train / Trends shell as features land).
struct RootView: View {
    @Environment(AuthViewModel.self) private var authVM

    var body: some View {
        Group {
            if authVM.state == .authenticated {
                signedInContent
            } else {
                AuthView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: authVM.state)
    }

    @ViewBuilder
    private var signedInContent: some View {
        #if DEBUG
        // Temporary affordance so the auth loop is testable before Profile/Settings exists.
        ReadingSpikeView()
            .overlay(alignment: .topTrailing) {
                Button("Sign out") { authVM.signOut() }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BaselineColor.textHi)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .padding(.trailing, 12)
            }
        #else
        ReadingSpikeView()
        #endif
    }
}

#Preview {
    RootView()
        .environment(AuthViewModel())
}
