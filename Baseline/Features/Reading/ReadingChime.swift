import AVFoundation

/// The end-of-reading bell. A single bundled chime (`reading-complete.wav`), played once the timed
/// read finishes, paired with a heavy haptic (see `Haptics.readingComplete()`). Mixes with other
/// audio and ducks nothing important — it's a soft, calm close, not an alarm.
@MainActor
enum ReadingChime {
    private static let player: AVAudioPlayer? = {
        for ext in ["wav", "mp3", "m4a", "caf"] {
            if let url = Bundle.main.url(forResource: "reading-complete", withExtension: ext),
               let player = try? AVAudioPlayer(contentsOf: url) {
                player.prepareToPlay()
                return player
            }
        }
        return nil
    }()

    /// Ring the bell and fire the completion haptic together.
    static func ring() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
        player?.currentTime = 0
        player?.play()
        Haptics.readingComplete()
    }
}
