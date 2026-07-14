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
    /// No source could be decoded. The *engine* never produces this (it returns nil instead of
    /// an empty night); it is constructed on the repository decode path when a stored row's
    /// source blob is missing or unreadable, so persistence corruption degrades honestly
    /// instead of masquerading as a device source.
    case none
}
