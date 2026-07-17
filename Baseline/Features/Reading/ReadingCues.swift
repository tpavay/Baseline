import AVFoundation
import UIKit

/// The reading's **end cue** — a soft bell + success haptic when the read completes, so it lands
/// even eyes-closed. There are deliberately no paced-breathing cues: the reading is natural-breath,
/// and standardization comes from consistent time + posture + natural breath (decided 2026-07-07).
///
/// The bell plays a bundled recording if present (drop `reading-complete` into `Resources/Audio/`).
/// `@MainActor` — it drives UIKit haptics + audio.
@MainActor
final class ReadingCues {
    private let completePlayer: AVAudioPlayer?
    private let notify = UINotificationFeedbackGenerator()

    init() {
        completePlayer = Self.loadPlayer("reading-complete")
    }

    /// Warm up the audio session + haptic generator so the end cue isn't laggy.
    func prepare() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
        notify.prepare()
    }

    func complete() {
        notify.notificationOccurred(.success)
        if let completePlayer {
            completePlayer.currentTime = 0
            completePlayer.play()
        }
    }

    func stop() {
        completePlayer?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
