import Foundation

/// Where a canonical sleep night (or a single stage interval) came from. Provenance is carried
/// per interval — not just per night — so a night can never silently blend devices (see the
/// never-merge rule in docs/implementation/sleep-engine.md §6).
enum SleepSource: Equatable, Hashable, Codable, Sendable {
    /// A HealthKit source, identified by its writing app's bundle identifier
    /// (e.g. the Apple Watch sleep source, Oura, AutoSleep).
    case healthKit(bundleID: String)
    /// User-entered sleep (Health-app manual entry or Baseline's own check-in fallback).
    case manual
    // Plan §3 also names a `none` case; the engine returns nil instead of an empty night, so
    // nothing can construct it yet — it arrives with Slice 2 persistence, where a decoded row
    // can actually carry it.
}
