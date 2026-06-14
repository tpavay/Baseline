import SwiftUI

/// Spike screen to validate the strap → R-R → RMSSD path on a real device.
/// (CoreBluetooth does not run in the Simulator — run on iPhone with a chest strap.)
struct ReadingSpikeView: View {
    @State private var monitor = HeartRateMonitor()

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            VStack(spacing: 32) {
                header
                metrics
                detail
                Spacer()
                startButton
            }
            .padding(24)
            .padding(.top, 24)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("HRV reading — spike")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(BaselineColor.textHi)
            Text(monitor.status.rawValue + (monitor.deviceName.map { " · \($0)" } ?? ""))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(BaselineColor.textMid)
        }
    }

    private var metrics: some View {
        HStack(spacing: 48) {
            metric(value: "\(monitor.currentHR)", label: "HR")
            metric(value: monitor.rmssd.map { String(format: "%.0f", $0) } ?? "—", label: "RMSSD")
        }
    }

    private var detail: some View {
        VStack(spacing: 4) {
            Text("\(monitor.rrIntervals.count) R-R intervals")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(BaselineColor.textFaint)
            if let ln = monitor.lnRmssd {
                Text(String(format: "ln(RMSSD)  %.2f", ln))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BaselineColor.textFaint)
            }
        }
    }

    private var startButton: some View {
        Button {
            monitor.isRunning ? monitor.stop() : monitor.start()
        } label: {
            Text(monitor.isRunning ? "Stop" : "Start reading")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(BaselineColor.base)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(BaselineColor.accent, in: .rect(cornerRadius: 16))
        }
    }

    private func metric(value: String, label: String) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 52, weight: .bold))
                .foregroundStyle(BaselineColor.textHi)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BaselineColor.textFaint)
        }
    }
}

#Preview {
    ReadingSpikeView()
}
