import AVFoundation
import UIKit

/// Breathing cues for the reading: a voice ("breathe in" / "breathe out"), distinct haptics for
/// inhale vs. exhale (so the read works eyes-closed), and a soft close at the end.
///
/// Voice plays a bundled recording if present (drop `breathe-in` / `breathe-out` /
/// `reading-complete` into `Resources/Audio/`); otherwise it falls back to on-device speech so
/// cues work before the recordings exist. `@MainActor` — it drives UIKit haptics + audio.
@MainActor
final class ReadingCues {
    var voiceEnabled: Bool
    var hapticsEnabled: Bool

    private let synthesizer = AVSpeechSynthesizer()
    private let inhalePlayer: AVAudioPlayer?
    private let exhalePlayer: AVAudioPlayer?
    private let completePlayer: AVAudioPlayer?

    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactSoft = UIImpactFeedbackGenerator(style: .soft)
    private let notify = UINotificationFeedbackGenerator()

    init(voiceEnabled: Bool, hapticsEnabled: Bool) {
        self.voiceEnabled = voiceEnabled
        self.hapticsEnabled = hapticsEnabled
        inhalePlayer = Self.loadPlayer("breathe-in")
        exhalePlayer = Self.loadPlayer("breathe-out")
        completePlayer = Self.loadPlayer("reading-complete")
    }

    /// Warm up the audio session + haptic generators so the first cue isn't laggy.
    func prepare() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
        impactLight.prepare()
        impactSoft.prepare()
        notify.prepare()
    }

    func cue(for phase: BreathPhase) {
        if hapticsEnabled { haptic(for: phase) }
        if voiceEnabled { speak(phase) }
    }

    func complete() {
        if hapticsEnabled { notify.notificationOccurred(.success) }
        if let completePlayer {
            completePlayer.currentTime = 0
            completePlayer.play()
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        inhalePlayer?.stop(); exhalePlayer?.stop(); completePlayer?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Private

    private func haptic(for phase: BreathPhase) {
        switch phase {
        case .inhale:
            // Rising double-pulse — "going up".
            impactLight.impactOccurred(intensity: 0.7)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                self.impactLight.impactOccurred(intensity: 1.0)
            }
        case .exhale:
            // Soft single — "settling down".
            impactSoft.impactOccurred(intensity: 0.6)
        }
    }

    private func speak(_ phase: BreathPhase) {
        if let player = phase == .inhale ? inhalePlayer : exhalePlayer {
            player.currentTime = 0
            player.play()
        } else {
            let utterance = AVSpeechUtterance(string: phase == .inhale ? "Breathe in" : "Breathe out")
            utterance.rate = 0.42
            utterance.pitchMultiplier = 0.95
            utterance.volume = 0.85
            synthesizer.speak(utterance)
        }
    }

    private static func loadPlayer(_ name: String) -> AVAudioPlayer? {
        for ext in ["mp3", "m4a", "wav", "caf"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext),
               let player = try? AVAudioPlayer(contentsOf: url) {
                player.prepareToPlay()
                return player
            }
        }
        return nil
    }
}
