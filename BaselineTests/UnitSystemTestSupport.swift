import Foundation
@testable import Baseline

/// A settable stand-in for `AppSettings` as the athlete's unit-system owner, so a test can flip the
/// system the way the Profile control does without reaching into `UserDefaults`.
@MainActor
final class StubUnitSystem: UnitSystemSource {
    var unitSystem: UnitSystem
    init(_ unitSystem: UnitSystem = .metric) { self.unitSystem = unitSystem }
}
