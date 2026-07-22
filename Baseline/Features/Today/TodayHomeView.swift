import SwiftUI

struct TodayHomeView: View {
    let model: TodayHomeModel
    let openSleep: () -> Void
    let openHRV: () -> Void
    let openPlan: () -> Void

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: BaselineSpacing.section) {
                    Text(model.greeting)
                        .baselineTypography(.screenTitle)
                        .foregroundStyle(BaselineColor.textHi)
                        .accessibilityAddTraits(.isHeader)

                    TodayVitalsView(
                        readings: model.readings,
                        openSleep: openSleep,
                        openHRV: openHRV
                    )

                    TodayPlanCardView(model: model.plan, action: openPlan)
                    TodayWeekCardView(summary: model.week)
                    TodayMovementBalanceCardView(movements: model.week.movements)
                    TodayHeartRateZonesCardView(summary: model.week, ranges: model.zoneRanges)

                    Color.clear.frame(height: BaselineSize.floatingTabContentInset)
                }
                .padding(.horizontal, BaselineSpacing.large)
                .padding(.top, BaselineSpacing.xxSmall)
            }
            .scrollIndicators(.hidden)
        }
    }
}
