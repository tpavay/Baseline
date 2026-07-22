import SwiftData
import SwiftUI

/// The signed-in app shell from the approved taxonomy prototype.
struct MainTabView: View {
    @State private var selection: MainTab

    init(initialSelection: MainTab = .today) {
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        ZStack {
            page(.today) { TodayView() }
            page(.plan) { PlanView() }
            page(.train) { WorkoutView(showsFloatingTabBarClearance: true) }
            page(.profile) { ProfileView() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BaselineFloatingTabBar(selection: $selection)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    @ViewBuilder
    private func page(_ tab: MainTab, @ViewBuilder content: () -> some View) -> some View {
        content()
            .opacity(selection == tab ? 1 : 0)
            .allowsHitTesting(selection == tab)
            .accessibilityHidden(selection != tab)
    }
}

/// Bottom clearance for content shown behind the floating tab bar. A `safeAreaInset` applied
/// outside a `NavigationStack` never crosses its UIKit hosting boundary, so every screen that
/// lives inside the shell applies this within its own stack.
extension View {
    func floatingTabBarClearance(_ enabled: Bool = true) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if enabled {
                Color.clear.frame(height: BaselineSize.floatingTabClearance)
            }
        }
    }
}

struct BaselineFloatingTabBar: View {
    @Binding var selection: MainTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: BaselineSpacing.xxxSmall) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: BaselineSize.iconGlyph, weight: .semibold))
                        Text(tab.title)
                            .font(.caption2)
                    }
                    .foregroundStyle(selection == tab ? BaselineColor.accent : BaselineColor.textMid)
                    .frame(maxWidth: .infinity)
                    .frame(height: BaselineSize.floatingTabSelectionHeight)
                    .background {
                        if selection == tab {
                            Capsule()
                                .fill(BaselineColor.accent.opacity(0.12))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(BaselineSpacing.compact)
        .frame(height: BaselineSize.floatingTabBarHeight)
        .background {
            Capsule()
                .fill(BaselineColor.surface.opacity(0.97))
                .overlay {
                    Capsule()
                        .stroke(BaselineColor.textFaint.opacity(0.26), lineWidth: BaselineSize.hairline)
                }
        }
        .padding(.horizontal, BaselineSize.floatingTabBarHorizontal)
        .padding(.bottom, BaselineSize.floatingTabBarBottom)
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    let models: [any PersistentModel.Type] = [Reading.self, ReadinessEntry.self] + PlanSchema.models + SleepSchema.models
    let container = try! ModelContainer(for: Schema(models),
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    return MainTabView()
        .environment(AuthViewModel())
        .environment(AppSettings())
        .environment(BluetoothManager())
        .environment(HealthService())
        .environment(TrainingContextStore())
        .environment(OnboardingStore())
        .environment(WorkoutStore(units: AppSettings()))
        .environment(PlanStore(context: container.mainContext))
        .modelContainer(container)
}
