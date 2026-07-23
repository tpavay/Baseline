import SwiftUI

// Act 2 — your score: milestone intro → formula (config-first) → heart source → strap pairing
// → Apple Health. Enabling an input pulls in its setup steps; the flow reshapes live.

// MARK: - "Time to build your score." (violet milestone)

struct BuildScoreIntroStepView: View {
    let store: OnboardingStore

    var body: some View {
        ZStack {
            Rectangle().fill(OnboardingStyle.violetMilestone).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if store.canGoBack {
                        Button {
                            Haptics.tap()
                            store.back()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(.white.opacity(0.14)))
                        }
                    }
                    Spacer()
                }
                .padding(.top, 6)

                Spacer()
                OnboardingHeadline("TIME TO BUILD\nYOUR SCORE.", size: 40, color: .white)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                Text("Readiness means something different for everyone. We've set up our recommendation — you decide what counts. Turn anything on or off, now or anytime.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(4)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()

                // White CTA is sanctioned here: on a full-bleed color milestone, white is the
                // only readable primary (amended button rule).
                Button {
                    Haptics.milestone()
                    store.advance()
                } label: {
                    Text("SHOW ME MY FORMULA")
                }
                .buttonStyle(InstrumentButtonStyle(tint: .white, textColor: BaselineColor.base))
                .padding(.bottom, 18)
            }
            .padding(.horizontal, 26)
        }
    }
}

// MARK: - Your Readiness Formula (metrics only — never hardware)

struct FormulaStepView: View {
    @Bindable var store: OnboardingStore

    var body: some View {
        OnboardingStepScaffold(
            store: store,
            ctaTitle: "LOCK IN MY FORMULA",
            ctaEnabled: store.canAdvance,
            onCTA: {
                Haptics.milestone()
                store.advance()
            }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    OnboardingHeadline("YOUR READINESS\nFORMULA", size: 28)
                    Text("We've pre-selected what feeds your score — change anything, now or anytime.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(BaselineColor.textMid)
                        .lineSpacing(3)
                        .padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 12) {
                        ConfigToggleRow(
                            icon: "heart.fill",
                            title: "Morning Heart Reading",
                            subtitle: "HRV + resting heart rate · 2:30 guided reading",
                            isOn: $store.draft.config.heartReadingEnabled
                        )
                        ConfigToggleRow(
                            icon: "moon.fill",
                            title: "Sleep",
                            subtitle: "Apple Health",
                            isOn: $store.draft.config.sleepEnabled
                        )
                        ConfigToggleRow(
                            icon: "checklist",
                            title: "Daily Check-in",
                            subtitle: "How you feel each morning",
                            isOn: $store.draft.config.checkInEnabled
                        )
                    }
                    .padding(.top, 20)

                    if store.draft.config.checkInEnabled {
                        InstrumentLabel("CHECK-IN COMPONENTS", tracking: 2)
                            .padding(.top, 20)
                        VStack(spacing: 0) {
                            componentRow(.soreness, icon: "figure.strengthtraining.traditional")
                            Hairline()
                            componentRow(.mood, icon: "face.smiling")
                            Hairline()
                            componentRow(.energy, icon: "bolt.fill")
                            Hairline()
                            componentRow(.stress, icon: "brain.head.profile")
                            Hairline()
                            componentRow(.sleepQuality, icon: "moon.zzz",
                                         subtitle: store.draft.config.sleepEnabled ? "Covered by Apple Health" : nil)
                        }
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.surface.opacity(0.6)))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.top, 10)
                    }

                    if !store.draft.config.heartReadingEnabled {
                        Text("Heart reading off — your score builds from sleep and check-in alone. Turn it on anytime in Readiness Setup.")
                            .font(.system(size: 12))
                            .foregroundStyle(BaselineColor.textFaint)
                            .padding(.top, 14)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(OnboardingCopy.formulaFootnote)
                        .font(.system(size: 11.5))
                        .italic()
                        .foregroundStyle(BaselineColor.textFaint)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 18)
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func componentRow(_ component: CheckInComponent, icon: String, subtitle: String? = nil) -> some View {
        let isOn = Binding(
            get: { store.draft.config.checkInComponents.contains(component) },
            set: { on in
                if on {
                    store.draft.config.checkInComponents.insert(component)
                } else {
                    store.draft.config.checkInComponents.remove(component)
                }
            }
        )
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BaselineColor.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(component.title.uppercased())
                    .font(.bMono(12, .bold)).tracking(1)
                    .foregroundStyle(BaselineColor.textHi)
                if let subtitle {
                    Text(subtitle)
                        .font(.bMono(9)).tracking(0.5)
                        .foregroundStyle(BaselineColor.textFaint)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(BaselineColor.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Heart-reading source (strap vs camera — only when the metric is on)

struct HeartSourceStepView: View {
    @Bindable var store: OnboardingStore

    var body: some View {
        OnboardingStepScaffold(store: store, ctaEnabled: store.canAdvance) {
            VStack(alignment: .leading, spacing: 0) {
                InstrumentLabel("CHOOSE YOUR", tracking: 2)
                OnboardingHeadline("HRV DATA SOURCE", size: 26)
                    .padding(.top, 4)

                VStack(spacing: 14) {
                    SelectableCard(
                        title: "Chest Strap",
                        subtitle: "Works with any Bluetooth strap — Polar, Garmin, Morpheus, Wahoo, whatever's in your gym bag. ECG-grade beat detection — the most accurate reading, plus live heart-rate zones in workouts.",
                        isSelected: store.draft.config.heartSource == .strap,
                        badge: "RECOMMENDED",
                        action: { store.draft.config.heartSource = .strap }
                    ) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(BaselineColor.accent)
                            .frame(width: 34)
                    }

                    SelectableCard(
                        title: "Smartphone Camera",
                        subtitle: "The same 2:30 guided reading — fingertip over the camera and flash. No hardware needed. Optical measurement (PPG), accurate at rest.",
                        isSelected: store.draft.config.heartSource == .camera,
                        action: { store.draft.config.heartSource = .camera }
                    ) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(BaselineColor.textMid)
                            .frame(width: 34)
                    }
                }
                .padding(.top, 22)

                Text(OnboardingCopy.sourceFootnote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(BaselineColor.textFaint)
                    .lineSpacing(2)
                    .padding(.top, 16)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Strap pairing (any BLE HR strap — the anti-lock-in moment)

struct StrapPairingStepView: View {
    let store: OnboardingStore
    @Environment(BluetoothManager.self) private var bluetooth

    private var isConnected: Bool { bluetooth.connectedDeviceID != nil }

    var body: some View {
        OnboardingStepScaffold(
            store: store,
            ctaTitle: isConnected ? "CONTINUE" : "SCANNING…",
            ctaEnabled: isConnected,
            onCTA: {
                bluetooth.stopScanning()
                store.advance()
            }
        ) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline(isConnected ? "DEVICE SYNCED" : "FIND YOUR STRAP", size: 26)
                Text(isConnected
                     ? "Locked in. This strap is now your reading source."
                     : "Put your strap on — a damp contact patch helps — and it'll appear below.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(BaselineColor.textMid)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)

                if let name = bluetooth.connectedDeviceName {
                    connectedCard(name: name)
                        .padding(.top, 22)
                }

                let others = bluetooth.discovered.filter { $0.id != bluetooth.connectedDeviceID }
                if !others.isEmpty {
                    InstrumentLabel(isConnected ? "OTHER DEVICES NEARBY" : "AVAILABLE NEARBY", tracking: 1.5)
                        .padding(.top, 24)
                    VStack(spacing: 10) {
                        ForEach(others) { device in
                            deviceRow(device)
                        }
                    }
                    .padding(.top, 10)
                }

                if !isConnected && bluetooth.discovered.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().tint(BaselineColor.accent)
                        Text(bluetooth.status.rawValue)
                            .font(.bMono(12)).foregroundStyle(BaselineColor.textFaint)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }

                Spacer(minLength: 12)

                Text("Baseline works with any Bluetooth strap that transmits beat-to-beat (R-R) data — no proprietary hardware required.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(BaselineColor.textFaint)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { bluetooth.startScanning() }
        .onDisappear { bluetooth.stopScanning() }
        .onChange(of: bluetooth.connectedDeviceID) { old, new in
            if old == nil, new != nil { Haptics.success() }
        }
    }

    private func connectedCard(name: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(BaselineColor.zoneGreen)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 16, weight: .bold)).foregroundStyle(BaselineColor.textHi)
                Text("CONNECTED\(bluetooth.batteryLevel.map { " · \($0)% BATTERY" } ?? "")")
                    .font(.bMono(10, .medium)).tracking(1)
                    .foregroundStyle(BaselineColor.textMid)
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(BaselineColor.surface)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(BaselineColor.accent.opacity(0.6), lineWidth: 1))
        )
    }

    private func deviceRow(_ device: DiscoveredDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BaselineColor.textMid)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                Text(device.rssi > -70 ? "STRONG SIGNAL" : "GOOD SIGNAL")
                    .font(.bMono(9)).tracking(1).foregroundStyle(BaselineColor.textFaint)
            }
            Spacer()
            Button {
                Haptics.select()
                bluetooth.select(device)
            } label: {
                Text("CONNECT")
                    .font(.bMono(11, .bold)).tracking(1)
                    .foregroundStyle(BaselineColor.accent)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().stroke(BaselineColor.accent.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BaselineColor.surface.opacity(0.6)))
    }
}

// MARK: - Apple Health

struct AppleHealthStepView: View {
    @Bindable var store: OnboardingStore
    @Environment(HealthService.self) private var health
    @State private var requesting = false

    var body: some View {
        OnboardingStepScaffold(
            store: store,
            ctaTitle: "CONNECT APPLE HEALTH",
            ctaEnabled: !requesting,
            onCTA: {
                requesting = true
                Task {
                    await health.requestReadAccess()
                    store.draft.healthConnectRequested = true
                    requesting = false
                    Haptics.success()
                    store.advance()
                }
            },
            skipTitle: "Skip for now",
            onSkip: { store.advance() }
        ) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 30)

                Image("AppleHealthIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: .infinity)

                OnboardingHeadline("Connect Apple Health", size: 26)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
                Text("Your sleep, activity, and heart history give your score real context — and pre-load your baseline so you start ahead, not from zero. You'll choose exactly what to share on the next screen.")
                    .font(.system(size: 14))
                    .foregroundStyle(BaselineColor.textMid)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Read-only. Baseline writes nothing to Apple Health unless you later log a weight and allow it.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(BaselineColor.textFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)

                Spacer()
            }
        }
    }
}
