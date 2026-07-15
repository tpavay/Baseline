import SwiftUI
import SwiftData

/// The athlete's home base: identity + streak, the Baseline protocol (readiness setup, zones,
/// devices), integrations, reading cues, and sign-out. Devices → Measurements is the live path;
/// rows without a backing surface yet are shown as "Soon" so nothing is a dead tap.
struct ProfileView: View {
    @Environment(OnboardingStore.self) private var profile
    @Environment(AuthViewModel.self) private var authVM
    @Environment(AppSettings.self) private var settings
    @Environment(BluetoothManager.self) private var bluetooth
    @Query(sort: \Reading.date, order: .reverse) private var readings: [Reading]

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            ZStack {
                BaselineColor.base.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        headerCard

                        group("Baseline protocol") {
                            row(icon: "circle.hexagongrid.fill", title: "Readiness Setup",
                                subtitle: "Which inputs build your score", destination: .soon)
                            NavigationLink {
                                HeartRateZoneSettingsView(store: HeartRateZoneSettingsStore(ageYears: { [profile] in profile.draft.ageYears }))
                            } label: {
                                rowBody(icon: "waveform.path.ecg.rectangle.fill", title: "Heart Rate Zones",
                                        subtitle: "Karvonen / LTHR zones", trailing: .chevron)
                            }
                            .buttonStyle(.plain)
                            NavigationLink { MeasurementsView() } label: {
                                rowBody(icon: "dot.radiowaves.left.and.right", title: "Devices",
                                        subtitle: deviceSubtitle, trailing: .chevron)
                            }
                            .buttonStyle(.plain)
                        }

                        group("Integrations") {
                            row(icon: "heart.text.square.fill", title: "Apple Health",
                                subtitle: "Sleep, resting HR, history", destination: .soon)
                            row(icon: "bell.fill", title: "Notifications",
                                subtitle: "Morning reading reminder", destination: .soon)
                            row(icon: "paintbrush.fill", title: "Appearance",
                                subtitle: "Dark", destination: .soon)
                        }

                        group("Reading") {
                            cardToggle("Live preview", isOn: $settings.livePreviewEnabled)
                        }

                        Button(role: .destructive) { authVM.signOut() } label: {
                            Text("Sign out")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(BaselineColor.zoneRed)
                                .frame(maxWidth: .infinity).frame(height: 52)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.surface))
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BaselineColor.base, for: .navigationBar)
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(spacing: 12) {
            Circle()
                .fill(BaselineColor.amethyst)
                .frame(width: 76, height: 76)
                .overlay(Circle().strokeBorder(BaselineColor.accent, lineWidth: 2))
                .overlay(Image(systemName: "person.fill").font(.system(size: 30)).foregroundStyle(BaselineColor.accent))
            Text(displayName.uppercased())
                .font(.system(size: 22, weight: .heavy)).italic()
                .foregroundStyle(BaselineColor.textHi)
            HStack(spacing: 8) {
                Text("\(readings.count) READINGS")
                Text("·")
                Text("\(streak)-DAY STREAK")
            }
            .font(.bMono(11, .medium)).tracking(1).foregroundStyle(BaselineColor.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - Rows

    private enum RowDestination { case soon }
    private enum Trailing { case chevron, soon }

    private func row(icon: String, title: String, subtitle: String, destination: RowDestination) -> some View {
        rowBody(icon: icon, title: title, subtitle: subtitle, trailing: .soon)
    }

    private func rowBody(icon: String, title: String, subtitle: String, trailing: Trailing) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(BaselineColor.amethyst)
                .frame(width: 38, height: 38)
                .overlay(Image(systemName: icon).font(.system(size: 15)).foregroundStyle(BaselineColor.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
                Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(BaselineColor.textFaint)
            }
            Spacer()
            switch trailing {
            case .chevron:
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(BaselineColor.textFaint)
            case .soon:
                Text("SOON").font(.bMono(10, .bold)).tracking(1).foregroundStyle(BaselineColor.textFaint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(BaselineColor.line))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.surface))
        .opacity(trailing == .soon ? 0.6 : 1)
    }

    private func cardToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(BaselineColor.textHi)
        }
        .tint(BaselineColor.accent)
        .padding(.horizontal, 16).frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BaselineColor.surface))
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            InstrumentLabel(title)
            content()
        }
    }

    // MARK: - Derived

    private var displayName: String {
        let n = profile.draft.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Athlete" : n
    }

    private var deviceSubtitle: String {
        switch profile.draft.config.heartSource {
        case .strap:
            if bluetooth.connectedDeviceID != nil { return "\(bluetooth.connectedDeviceName ?? "Strap") connected" }
            return bluetooth.savedDeviceName.map { "\($0) · not connected" } ?? "Chest strap"
        case .camera: return "Phone camera"
        case .none: return "Not set"
        }
    }

    /// Consecutive days ending today (or yesterday) that have at least one reading.
    private var streak: Int {
        let cal = Calendar.current
        let days = Set(readings.map { cal.startOfDay(for: $0.date) })
        guard !days.isEmpty else { return 0 }
        var day = cal.startOfDay(for: .now)
        if !days.contains(day) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: day), days.contains(yesterday) else { return 0 }
            day = yesterday
        }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }
}

#Preview {
    ProfileView()
        .environment(OnboardingStore())
        .environment(AuthViewModel())
        .environment(AppSettings())
        .environment(BluetoothManager())
        .modelContainer(for: Reading.self, inMemory: true)
        .preferredColorScheme(.dark)
}
