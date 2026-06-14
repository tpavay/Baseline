import SwiftUI

/// Root. For now it launches the HRV reading spike so we can validate the strap → RMSSD path
/// on device. Becomes the tabbed app shell (Today / Train / Trends / Profile) as features land.
struct RootView: View {
    var body: some View {
        ReadingSpikeView()
    }
}

#Preview {
    RootView()
}
