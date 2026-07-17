import Foundation

/// One contiguous sleep session — the overnight block, or a nap/split segment. A night holds one
/// or more episodes; only the primary one feeds duration metrics so naps never inflate them.
struct SleepEpisode: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var start: Date
    var end: Date
    var intervals: [SleepStageInterval]
    /// The main overnight sleep for the night; everything else is a nap/split segment.
    var isPrimary: Bool
    /// Untracked spans inside the episode window (device off wrist, tracking dropout).
    var gaps: [DateInterval]
}
