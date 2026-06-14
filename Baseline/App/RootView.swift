import SwiftUI

/// Placeholder root. Replaced by the tabbed app shell (Today / Train / Trends / Profile)
/// as features land — see CLAUDE.md and docs/.
struct RootView: View {
    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            VStack(spacing: 10) {
                Text("Baseline")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(BaselineColor.textHi)
                Text("Recovery-aware HYROX coach")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(BaselineColor.textMid)
            }
        }
    }
}

#Preview {
    RootView()
}
