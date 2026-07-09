import AVFoundation
import SwiftUI
import SwiftData
import UIKit

/// Live camera feed so the user can see exactly what the lens sees — confirming their fingertip
/// fully covers it — without flipping the phone around (the HRV4Training affordance).
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// Fingertip camera reading (Welltory-style): cover the rear lens + flash, hold still, and the
/// pulse builds a live waveform while the 2:30 timer runs. Reuses `ReadingSession` with a
/// `CameraPPGManager` source, so the reading math and result are identical to the strap path.
/// No talking-head video — just a calm, clear capture surface.
struct CameraReadingView: View {
    let type: ReadingType
    private let onFinish: ((ReadingResult?) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    @State private var camera = CameraPPGManager()
    @State private var session: ReadingSession
    @State private var savedReading: Reading?
    @State private var exportURL: URL?
    @State private var handedOff = false

    /// Whether to show the "put your finger over the camera" intro before capture (daily). Skipped
    /// in onboarding, which already has its own first-reading intro.
    private let showIntro: Bool

    init(type: ReadingType, duration: TimeInterval? = nil, showIntro: Bool = true,
         onFinish: ((ReadingResult?) -> Void)? = nil) {
        self.type = type
        self.showIntro = showIntro
        self.onFinish = onFinish
        let cam = CameraPPGManager()
        _camera = State(initialValue: cam)
        _session = State(initialValue: ReadingSession(type: type, duration: duration, usesLivePreview: true, source: cam))
    }

    var body: some View {
        ZStack {
            BaselineColor.base.ignoresSafeArea()
            switch session.phase {
            case .intro, .connecting, .preview, .countdown, .reading:
                // One persistent full-screen surface (camera feed at its root), so the preview —
                // and therefore the torch — is never torn down and rebuilt mid-flow.
                camera.permissionDenied ? AnyView(deniedPrompt) : AnyView(surface)
            case .complete:
                // Honesty gate: a trustworthy pulse hands off to the parent; otherwise we stay and
                // tell the truth. The parent (daily flow / onboarding) owns the result screen.
                if camera.peakConfidence >= CameraPPGManager.confidenceThreshold {
                    Color.clear
                } else {
                    lowConfidenceFailed
                }
            case .failed: failed
            }
        }
        .onChange(of: session.phase) { _, phase in
            // Confirming buzz the instant the finger locks on and the countdown begins.
            if phase == .countdown { Haptics.heavyStart() }
            guard phase == .complete else { return }
            ReadingChime.ring()                    // heavy haptic + bell, the read's close
            exportURL = camera.exportCSV()
            // Low-confidence reads are neither saved (they'd poison the baseline) nor handed off.
            guard camera.peakConfidence >= CameraPPGManager.confidenceThreshold,
                  let result = session.result else { return }
            if savedReading == nil {
                let reading = Reading(result: result, position: settings.readingPosition,
                                      source: .camera, deviceName: "iPhone camera")
                modelContext.insert(reading)
                if let csv = camera.rawCSV() { reading.saveRawSignal(csv) }   // raw signal for diagnostics
                savedReading = reading
            }
            if !handedOff {
                handedOff = true
                if let onFinish { onFinish(result) } else { dismiss() }
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            session.start(showIntro: showIntro)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            session.stop()
        }
    }

    /// The shared reading surface with the full-screen camera feed as its background. The feed
    /// naturally reddens as the fingertip covers the lens + flash — it IS the coverage indicator.
    private var surface: some View {
        ReadingSurfaceView(
            session: session,
            style: .camera,
            coaching: coachingText,
            coachingColor: coverageColor,
            background: { cameraFeed },
            onGotIt: { session.dismissIntro() },
            onStop: { close() }
        )
    }

    @ViewBuilder private var cameraFeed: some View {
        if camera.isRunning {
            CameraPreview(session: camera.session)
        } else {
            Color.black
        }
    }

    // MARK: - Coverage-driven coaching

    private var coverageColor: Color {
        switch camera.coverage {
        case .absent: return BaselineColor.textFaint
        case .adjust: return BaselineColor.zoneAmber
        case .good:   return BaselineColor.zoneGreen
        }
    }

    private var coachingText: String {
        switch camera.coverage {
        case .absent: return "Cover the lens by the flash with your fingertip"
        case .adjust: return "Slightly adjust your finger — cover the lens completely"
        case .good:   return session.phase == .reading
            ? "Reading — hold your finger still and limit movement"
            : "Signal looks good — starting your reading"
        }
    }

    private var deniedPrompt: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "camera.fill").font(.system(size: 38)).foregroundStyle(BaselineColor.textMid)
            Text("CAMERA ACCESS NEEDED").font(.bMono(15, .bold)).tracking(1).foregroundStyle(BaselineColor.textHi)
            Text("To read your pulse from your fingertip, Baseline needs camera access. Enable it in Settings — or switch to a chest strap anytime.")
                .font(.system(size: 14)).foregroundStyle(BaselineColor.textMid)
                .multilineTextAlignment(.center).lineSpacing(3).padding(.horizontal, 40)
            Spacer()
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: { Text("OPEN SETTINGS") }
                .buttonStyle(InstrumentButtonStyle()).padding(.horizontal, 24)
            Button { close() } label: {
                Text("USE A STRAP INSTEAD").font(.bMono(11)).tracking(1).foregroundStyle(BaselineColor.textFaint)
            }
            .padding(.top, 8).padding(.bottom, 22)
        }
        .padding(.horizontal, 24)
    }

    /// Shown when the reading finished but no trustworthy pulse was found — honest, with a path
    /// to retry or switch to the more reliable chest strap.
    private var lowConfidenceFailed: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                if let url = exportURL {
                    ShareLink(item: url) { Text("EXPORT DATA").font(.bMono(11, .medium)).tracking(0.5).foregroundStyle(BaselineColor.accent) }
                }
            }
            .padding(.top, 8)
            Spacer()
            Image(systemName: "waveform.path.ecg.rectangle").font(.system(size: 38)).foregroundStyle(BaselineColor.textMid)
            Text("COULDN'T GET A CLEAN PULSE").font(.bMono(15, .bold)).tracking(1).foregroundStyle(BaselineColor.textHi)
            Text("The camera couldn't read a steady heartbeat from your fingertip. Cover the lens by the flash with your fingertip, hold still, and breathe naturally — or use a chest strap for the most reliable reading.")
                .font(.system(size: 14)).foregroundStyle(BaselineColor.textMid)
                .multilineTextAlignment(.center).lineSpacing(3).padding(.horizontal, 34)
            Spacer()
            Button { session.start() } label: { Text("TRY AGAIN") }.buttonStyle(InstrumentButtonStyle()).padding(.horizontal, 24)
            Button { close() } label: {
                Text("USE A STRAP INSTEAD").font(.bMono(11)).tracking(1).foregroundStyle(BaselineColor.textFaint)
            }
            .padding(.top, 8).padding(.bottom, 22)
        }
        .padding(.horizontal, 24)
    }

    private var failed: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "camera.metering.unknown").font(.system(size: 38)).foregroundStyle(BaselineColor.textMid)
            Text("COULDN'T FIND YOUR PULSE").font(.bMono(15, .bold)).tracking(1).foregroundStyle(BaselineColor.textHi)
            Text("Cover both the lens closest to the flash and the flash with the pad of your finger, and keep still.")
                .font(.system(size: 14)).foregroundStyle(BaselineColor.textMid)
                .multilineTextAlignment(.center).padding(.horizontal, 44)
            Spacer()
            Button { session.start() } label: { Text("TRY AGAIN") }.buttonStyle(InstrumentButtonStyle())
                .padding(.horizontal, 24)
            Button { close() } label: { Text("CLOSE").font(.bMono(11)).tracking(1).foregroundStyle(BaselineColor.textFaint) }
                .padding(.top, 8).padding(.bottom, 22)
        }
    }

    private func close() {
        session.stop()
        if let onFinish {
            onFinish(session.phase == .complete ? session.result : nil)
        } else {
            dismiss()
        }
    }
}
