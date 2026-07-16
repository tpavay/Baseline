import SwiftUI

/// Pick the primary way the morning reading is captured — phone camera or a BLE chest strap —
/// and manage the strap connection. This is the in-app equivalent of the onboarding source step,
/// editable any time. The choice writes through the shared profile store (local + Firestore) and
/// takes effect on the next reading. Baselines are kept per-source, so switching never corrupts
/// history (see DailyReadingFlowView).
struct MeasurementsView: View {
    @Environment(OnboardingStore.self) private var profile
    @Environment(BluetoothManager.self) private var bluetooth
    @Environment(AuthViewModel.self) private var authVM

    private var source: HeartSource? { profile.draft.config.heartSource }

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    section("HRV measurement method") {
                        methodCard(.camera)
                        methodCard(.strap)
                        Text("Your baseline calibrates separately for each method, so switching won't corrupt your history.")
                            .font(.system(size: 12)).foregroundStyle(BaselineColor.textFaint)
                            .padding(.top, 2)
                    }

                    if source == .strap {
                        section("Strap connection") { strapConnection }
                    }

                    section("Device support") { deviceSupport }
                }
                .padding(20)
            }
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BaselineColor.base, for: .navigationBar)
        .onAppear { if source == .strap { bluetooth.startScanning() } }
        .onDisappear { bluetooth.stopScanning() }
    }

    // MARK: - Primary method

    private func methodCard(_ method: HeartSource) -> some View {
        let selected = source == method
        return Button { select(method) } label: {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(BaselineColor.amethyst)
                        .frame(width: 46, height: 46)
                        .overlay(Image(systemName: method == .camera ? "camera.fill" : "heart.fill")
                            .font(.system(size: 18)).foregroundStyle(BaselineColor.accent))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(method == .camera ? "PHONE CAMERA" : "CHEST STRAP")
                            .font(.system(size: 17, weight: .heavy)).italic()
                            .foregroundStyle(BaselineColor.textHi)
                        Text(method == .camera ? "Back telephoto lens + LED flash" : "BLE Heart Rate Monitor")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(method == .strap ? BaselineColor.accent : BaselineColor.textFaint)
                    }
                    Spacer()
                    radio(selected)
                }
                .padding(16)

                // Connected-strap readout, inline on the selected strap card (mirrors the mockup).
                if method == .strap, selected, bluetooth.connectedDeviceID != nil {
                    Hairline().padding(.horizontal, 16)
                    HStack(spacing: 8) {
                        Text(bluetooth.connectedDeviceName ?? "Strap")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                        InstrumentLabel("Connected", color: BaselineColor.zoneGreen, tracking: 1)
                        Spacer()
                        if let battery = bluetooth.batteryLevel {
                            Image(systemName: "battery.75").font(.system(size: 12)).foregroundStyle(BaselineColor.zoneGreen)
                            Text("\(battery)%").font(.bMono(12, .medium)).foregroundStyle(BaselineColor.textMid)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BaselineColor.surface))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selected ? BaselineColor.accent : BaselineColor.line, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    private func radio(_ selected: Bool) -> some View {
        ZStack {
            Circle().strokeBorder(selected ? BaselineColor.accent : BaselineColor.textFaint, lineWidth: 2)
                .frame(width: 22, height: 22)
            if selected { Circle().fill(BaselineColor.accent).frame(width: 12, height: 12) }
        }
    }

    // MARK: - Strap connection (scan / pick / forget)

    @ViewBuilder private var strapConnection: some View {
        if bluetooth.savedDeviceID != nil {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bluetooth.savedDeviceName ?? "Saved strap")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                        Text(savedStatus)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(connectedToSaved ? BaselineColor.zoneGreen : BaselineColor.textFaint)
                    }
                    Spacer()
                    Button("Forget") { bluetooth.forgetDevice() }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(BaselineColor.zoneRed)
                }
                .padding(16)
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BaselineColor.surface))
        }

        VStack(alignment: .leading, spacing: 12) {
            if otherDevices.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(BaselineColor.accent)
                    Text("Scanning… wear your strap so it shows up here.")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(BaselineColor.textMid)
                }
            } else {
                ForEach(otherDevices) { device in
                    Button { bluetooth.select(device) } label: {
                        HStack {
                            Text(device.name).font(.system(size: 15, weight: .medium)).foregroundStyle(BaselineColor.textHi)
                            Spacer()
                            Image(systemName: "plus.circle").foregroundStyle(BaselineColor.accent)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BaselineColor.surface))
    }

    // MARK: - Device support (static)

    private var deviceSupport: some View {
        VStack(alignment: .leading, spacing: 16) {
            supportItem(icon: "xmark.circle", title: "Incompatible trackers",
                        body: "Mi Band, Withings, and Fitbit devices are currently incompatible as they do not provide raw heart rate variability data.")
            supportItem(icon: "arrow.down.circle", title: "Restricted ecosystems",
                        body: "Garmin and Oura hardware does not support live HRV transmission via Bluetooth. Data can only be imported from Apple Health.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BaselineColor.surface))
    }

    private func supportItem(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(BaselineColor.textMid).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).font(.system(size: 13, weight: .bold)).foregroundStyle(BaselineColor.textHi)
                Text(body).font(.system(size: 12, weight: .medium)).italic()
                    .foregroundStyle(BaselineColor.textFaint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Section wrapper

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            InstrumentLabel(title)
            content()
        }
    }

    // MARK: - Actions

    private func select(_ method: HeartSource) {
        guard profile.draft.config.heartSource != method else { return }
        profile.draft.config.heartSource = method   // struct mutation → persists locally via draft didSet
        persistRemote()
        if method == .strap { bluetooth.startScanning() } else { bluetooth.stopScanning() }
    }

    private func persistRemote() {
        guard let uid = authVM.user?.uid else { return }
        let draft = profile.draft
        Task { try? await UserRepository().saveProfile(uid: uid, draft: draft, onboardingCompleted: true) }
    }

    private var otherDevices: [DiscoveredDevice] {
        bluetooth.discovered.filter { $0.id != bluetooth.savedDeviceID }
    }
    private var connectedToSaved: Bool {
        bluetooth.connectedDeviceID != nil && bluetooth.connectedDeviceID == bluetooth.savedDeviceID
    }
    private var savedStatus: String {
        if connectedToSaved { return "Connected" }
        if bluetooth.status == .connecting { return "Connecting…" }
        return "Saved · not connected"
    }
}

#Preview {
    NavigationStack { MeasurementsView() }
        .environment(OnboardingStore())
        .environment(BluetoothManager())
        .environment(AuthViewModel())
        .preferredColorScheme(.dark)
}
