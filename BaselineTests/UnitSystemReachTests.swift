import Foundation
import Testing
@testable import Baseline

/// Guards the claim that the athlete's unit system reaches **everything**, rather than the surfaces
/// that happened to be wired up on the day.
///
/// Two kinds of guard, because a behavioural test can only cover screens that already exist:
/// - `newDisplayCodeCannotHardCodeAUnit` reads the shipping source and fails when *any* file outside
///   a short, justified allowlist writes a unit literal, a conversion constant, or reaches for
///   `canonicalUnit`. A screen added next year is covered by it the day it is written.
/// - The behavioural tests below pin the resolution rule itself and the surfaces that had drifted.
@MainActor
struct UnitSystemReachTests {

    // MARK: - The source guard

    /// Display code must resolve units through `UnitSystem.displayUnit(for:)` (directly or via
    /// `WorkoutStore.displayUnit`). Anything that spells a unit out itself has, by construction,
    /// stopped following the setting.
    ///
    /// The allowlist is deliberately tiny and each entry is input-side or definitional — parsing an
    /// athlete's "5 km" or an agent's `"lb"` argument is the one place unit *tokens* belong.
    @Test func newDisplayCodeCannotHardCodeAUnit() throws {
        let allowed: Set<String> = [
            "Metrics.swift",                 // defines the units, the systems, and the conversions
            "WorkoutImportBuilder.swift",    // parse-side: source text → MetricUnit
            "WorkoutImportFallbackBuilder.swift", // parse-side: regex unit tokens
            "ToolCallMapper.swift",          // parse-side: agent unit argument → MetricUnit
            "OnboardingActFour.swift",       // body height/weight steps own explicit ft-in / lb toggles
        ]
        // Unit spellings, conversion constants, and the storage-unit escape hatch.
        let banned = try [
            #"\"(kg|lb|lbs|mi|km|KG|LB|MI|KM|kilograms?|pounds?|miles?|kilometers?|kilometres?)\""#,
            #"1609\.344|0\.45359237|2\.2046|(?<![\d.])2\.54(?![\d])"#,
            #"\bcanonicalUnit\b"#,
        ].map { try NSRegularExpression(pattern: $0) }

        var offences: [String] = []
        for file in try Self.appSources() {
            let name = file.lastPathComponent
            guard !allowed.contains(name) else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            // A line-level opt-out for the rare parse-side line inside an otherwise display-facing
            // file. Deliberately noisy to write and trivial to grep for at review time.
            let exempt = Set(source.components(separatedBy: .newlines).enumerated()
                .filter { $0.element.contains("units:storage") }
                .map { $0.offset + 1 })
            for (number, line) in Self.codeLines(of: source) where !exempt.contains(number) {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard banned.contains(where: { $0.firstMatch(in: line, range: range) != nil }) else { continue }
                offences.append("\(name):\(number)  \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offences.isEmpty, """
            These lines spell a unit out instead of asking the athlete's unit system for one, so they \
            will keep showing metric (or keep showing imperial) whatever the setting says. Resolve \
            through UnitSystem.displayUnit(for:) — or WorkoutStore.displayUnit(_:for:) when there is a \
            PlannedExercise — and render with MetricFormat. Only add to the allowlist for parse-side \
            code that turns text into a MetricUnit.
            \(offences.joined(separator: "\n"))
            """)
    }

    /// `WorkoutStore` must not be able to hold a unit system of its own again: the mirrored `var` is
    /// exactly what let the Plan tab's execution store render metric to an imperial athlete.
    @Test func theStoreHasNoUnitSystemOfItsOwnToGoStale() throws {
        let source = try String(contentsOf: Self.repositoryRoot
            .appendingPathComponent("Baseline/Shared/Settings/WorkoutStore.swift"), encoding: .utf8)
        let assignments = Self.codeLines(of: source).filter {
            $0.line.contains("unitSystem") && $0.line.contains("=") && !$0.line.contains("==")
        }
        #expect(assignments.isEmpty, """
            WorkoutStore assigns unitSystem — it must read through its injected UnitSystemSource so \
            there is only ever one copy of the athlete's choice.
            \(assignments.map { "\($0.number)  \($0.line.trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n"))
            """)
    }

    // MARK: - The resolution rule

    @Test(arguments: [
        (UnitSystem.imperial, MetricUnit.pounds, MetricUnit.miles),
        (UnitSystem.metric, MetricUnit.kilograms, MetricUnit.kilometers),
    ])
    func everyExerciselessSurfaceResolvesThroughTheSystem(system: UnitSystem, load: MetricUnit, distance: MetricUnit) {
        #expect(system.displayUnit(for: .load) == load)
        #expect(system.displayUnit(for: .distance) == distance)
        // Metrics with a single display unit are unaffected, never left nil or guessed at.
        #expect(system.displayUnit(for: .reps) == .count)
        #expect(system.displayUnit(for: .duration) == .seconds)
        #expect(system.displayUnit(for: .heartRate) == .bpm)
    }

    /// The reported bug in one assertion: the store must follow a live change of the setting, not a
    /// value copied into it at some earlier moment.
    @Test func theStoreFollowsTheSettingWhenItChanges() {
        let units = StubUnitSystem(.metric)
        let store = WorkoutStore(units: units, defaults: UserDefaults(suiteName: "reach-\(UUID().uuidString)")!)
        let ex = PlannedExercise(exerciseName: "Sled Push", definitionId: "sled_push",
                                 selectedMetrics: [.distance, .load])

        #expect(store.displayUnit(.distance, for: ex) == .kilometers)
        units.unitSystem = .imperial
        #expect(store.displayUnit(.distance, for: ex) == .miles)
        #expect(store.displayUnit(.load, for: ex) == .pounds)
        #expect(store.displayUnit(.distance) == .miles)   // and with no exercise to hang it on
    }

    /// Storage stays canonical whatever the athlete is shown — the invariant `WorkoutStoreTests`
    /// asserts, restated here because this suite is what a future unit change gets read against.
    @Test func switchingSystemsNeverTouchesTheStoredValue() {
        let units = StubUnitSystem(.metric)
        let store = WorkoutStore(units: units, defaults: UserDefaults(suiteName: "reach-\(UUID().uuidString)")!)
        store.create(title: "Conditioning", goal: nil)
        store.addExercise(name: "Sled Push", toBlockNamed: "", sets: 1, reps: nil, load: nil,
                          durationSeconds: nil, distanceMeters: 121)

        func stored() -> Double? { store.current?.allExercises.first?.prescription.sets.first?.values[.distance] }
        let before = stored()
        units.unitSystem = .imperial
        #expect(stored() == before)
        #expect(abs((before ?? 0) - 121) < 0.001)
    }

    // MARK: - Surfaces that had drifted

    @Test(arguments: [(UnitSystem.imperial, "MI"), (UnitSystem.metric, "KM")])
    func theWeeklyDistanceAggregateFollowsTheSystem(system: UnitSystem, unit: String) {
        let aggregate = Aggregate(key: .distance, total: 8_046.72)   // 5 miles
        #expect(PlanFormat.aggregateUnit(.distance, in: system) == unit)
        let expected = system == .imperial ? "5.0" : "8.0"
        #expect(PlanFormat.aggregateValue(aggregate, in: system) == expected)
    }

    /// The agent narrates from this text. Group totals and adjustments used to be handed to it in raw
    /// canonical units, so it told an imperial athlete their AMRAP target was "2000 m".
    @Test func theAgentSummaryStatesTheSystemAndSpeaksInIt() throws {
        let units = StubUnitSystem(.imperial)
        let store = WorkoutStore(units: units, defaults: UserDefaults(suiteName: "reach-\(UUID().uuidString)")!)
        store.create(title: "Engine", goal: nil)
        store.addExercise(name: "Run", toBlockNamed: "", sets: 1, reps: nil, load: nil,
                          durationSeconds: nil, distanceMeters: 1609.344)

        let tools = AgentTools(store: TrainingContextStore(defaults: UserDefaults(suiteName: "reach-ctx-\(UUID().uuidString)")!),
                               base: DecisionEngine.Inputs(), workouts: store)
        let context = tools.contextSummary()
        #expect(context.contains("imperial"))
        #expect(context.contains("lb"))
        #expect(context.contains("mi"))

        let summary = store.summary(.plan)
        #expect(summary.contains("1 mi"))
        #expect(!summary.contains("1609"))
    }

    /// A progression is stored canonically, so the display value must be converted exactly once.
    /// Converting before handing it to `MetricFormat` (which converts again) rendered "+0 mi".
    @Test func aProgressionDeltaIsConvertedExactlyOnce() {
        #expect(MetricFormat.value(402.336, .distance, unit: .miles) == "0.25 mi")
    }

    /// Yesterday's Apple exercise minutes are a duration, and used to render as one bold "121m"
    /// string — the shape the report described as "121 M", i.e. 121 metres.
    @Test func theActivityTileNeverReadsAsADistance() {
        let long = TodayView.activityReadout(DayActivity(kcal: 900, minutes: 121))
        #expect(long.value == "121")
        #expect(long.unit == "MIN")

        let quiet = TodayView.activityReadout(DayActivity(kcal: 340, minutes: 0))
        #expect(quiet.value == "340")
        #expect(quiet.unit == "CAL")
    }

    // MARK: - Source access

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BaselineTests
            .deletingLastPathComponent()  // repository root
    }

    private static func appSources() throws -> [URL] {
        let root = repositoryRoot.appendingPathComponent("Baseline")
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Lines with comments and doc comments stripped, so prose *about* units never trips the guard.
    /// Block comments are handled crudely on purpose — a false positive is a readable failure, and
    /// there is no block comment in the app sources that contains a unit literal.
    private static func codeLines(of source: String) -> [(number: Int, line: String)] {
        source.components(separatedBy: .newlines).enumerated().compactMap { index, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*") else { return nil }
            let code = raw.components(separatedBy: "//").first ?? raw
            return code.trimmingCharacters(in: .whitespaces).isEmpty ? nil : (index + 1, code)
        }
    }
}
