import SwiftUI

struct TodayVitalsView: View {
    let readings: [TodayReadingCard]
    let openSleep: () -> Void
    let openHRV: () -> Void

    var body: some View {
        if !readings.isEmpty {
            HStack(spacing: BaselineSpacing.tile) {
                ForEach(readings) { reading in
                    switch reading {
                    case .sleep(let model):
                        Button(action: openSleep) {
                            TodaySleepCardView(model: model, isSolo: readings.count == 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens sleep details")
                    case .hrv(let model):
                        Button(action: openHRV) {
                            TodayHRVCardView(model: model, isSolo: readings.count == 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens reading history")
                    }
                }
            }
        }
    }
}
