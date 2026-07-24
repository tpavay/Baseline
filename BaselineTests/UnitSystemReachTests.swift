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

    /// Display code must resolve units through `UnitSystem.displayUnit(metric:exercise:)` (directly or via
    /// `WorkoutStore.displayUnit`). Anything that spells a unit out itself has, by construction,
    /// stopped following the setting.
    ///
    /// The allowlist is deliberately tiny and each entry is input-side or definitional — parsing an
    /// athlete's "5 km" or an agent's `"lb"` argument is the one place unit *tokens* belong.
    @Test func newDisplayCodeCannotHardCodeAUnit() throws {
        let allowed: Set<String> = [
            "Metrics.swift",                 // defines the units, the systems, and the conversions
            "WorkoutImportBuilder.swift",    // parse-side: source text → MetricUnit
            "ImportQuantityParser.swift",    // parse-side: source text → canonical quantity
            "ImportExerciseMatcher.swift",   // parse-side: unit tokens stripped from source names
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
            through UnitSystem.displayUnit(metric:exercise:) — or WorkoutStore.displayUnit(_:for:) when there is a \
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

    // MARK: - The approved default policy

    /// The whole policy in one table, so a future change to any line of it has to come here first.
    @Test(arguments: [
        (UnitSystem.imperial, MetricUnit.pounds, MetricUnit.miles, MetricUnit.secondsPerMile),
        (UnitSystem.metric, MetricUnit.kilograms, MetricUnit.kilometers, MetricUnit.secondsPerKilometer),
    ])
    func theApprovedDefaults(system: UnitSystem, load: MetricUnit, endurance: MetricUnit, pace: MetricUnit) {
        let run = ExerciseCatalog.definition(id: "run")
        let sled = ExerciseCatalog.definition(id: "sled_push")

        #expect(system.displayUnit(metric: .load, exercise: sled) == load)
        #expect(system.displayUnit(metric: .distance, exercise: run) == endurance)
        #expect(system.displayUnit(metric: .pace, exercise: run) == pace)

        // The rule that makes distance different from load: floor work is meters to everyone, so the
        // approved detail screen can read "lb" for load and "20 m" for the sled at the same time.
        #expect(system.displayUnit(metric: .distance, exercise: sled) == .meters)

        // No exercise in hand (weekly aggregates, group totals) reads as endurance.
        #expect(system.displayUnit(metric: .distance, exercise: nil) == endurance)

        // Metrics with a single display unit are unaffected, never left nil or guessed at.
        #expect(system.displayUnit(metric: .reps, exercise: nil) == .count)
        #expect(system.displayUnit(metric: .duration, exercise: nil) == .seconds)
        #expect(system.displayUnit(metric: .heartRate, exercise: nil) == .bpm)
    }

    /// Every catalog category has to land on one side of the distance rule deliberately, not by
    /// falling through a `default:`. Adding a category makes this fail until someone decides.
    @Test func everyActivityCategoryDeclaresItsDistanceContext() {
        let endurance: Set<ActivityCategory> = [.cycling, .running, .erg]
        for category in ActivityCategory.allCases {
            let expected: DistanceContext = endurance.contains(category) ? .endurance : .floor
            #expect(category.distanceContext == expected, "\(category.rawValue) is on the wrong side of the distance rule")
        }
    }

    /// Units are never chosen by how big the number is — the same exercise reads in the same unit
    /// whether the athlete did 20 m or 20 km of it.
    @Test func unitsNeverSwitchOnMagnitude() {
        let units = StubUnitSystem(.imperial)
        let store = WorkoutStore(units: units, defaults: UserDefaults(suiteName: "reach-\(UUID().uuidString)")!)
        let run = PlannedExercise(exerciseName: "Run", definitionId: "run", selectedMetrics: [.distance])
        let sled = PlannedExercise(exerciseName: "Sled Push", definitionId: "sled_push", selectedMetrics: [.distance])

        #expect(store.displayUnit(.distance, for: run) == .miles)
        #expect(store.displayUnit(.distance, for: sled) == .meters)
        // Same units at both extremes: a 20 m run is still miles, a 20 km sled push is still meters.
        #expect(MetricFormat.value(20, .distance, unit: store.displayUnit(.distance, for: run)) == "0.01 mi")
        #expect(MetricFormat.value(20_000, .distance, unit: store.displayUnit(.distance, for: sled)) == "20000 m")
    }

    /// A stored choice is the athlete with an unusual preference, and it outranks the category rule.
    @Test func aStoredChoiceOverridesTheCategoryDefault() {
        let units = StubUnitSystem(.metric)
        let store = WorkoutStore(units: units, defaults: UserDefaults(suiteName: "reach-\(UUID().uuidString)")!)

        // This-instance override: someone programming a 400 m sled drag in kilometers.
        let pinned = PlannedExercise(exerciseName: "Sled Push", definitionId: "sled_push",
                                     selectedMetrics: [.distance], displayUnits: [.distance: .kilometers])
        #expect(store.displayUnit(.distance, for: pinned) == .kilometers)

        // Per-exercise preference beats the default for fresh instances of that exercise.
        #expect(store.setExercisePreference(exerciseNamed: "Run", scope: .exercise, units: [.distance: .meters]).succeeded)
        let run = PlannedExercise(exerciseName: "Run", definitionId: "run", selectedMetrics: [.distance])
        #expect(store.displayUnit(.distance, for: run) == .meters)
    }

    /// A custom movement carries its category too, and the unit rule has to see it. Resolving only
    /// against the curated catalog left every `custom_…` id falling through to the generic
    /// definition, i.e. floor, i.e. the reported metres-for-an-imperial-athlete symptom again.
    @Test func aCustomExercisesCategoryReachesTheUnitRule() {
        let units = StubUnitSystem(.imperial)
        let store = WorkoutStore(units: units, defaults: UserDefaults(suiteName: "reach-\(UUID().uuidString)")!)
        let trail = store.createCustomDefinition(name: "Trail Run", category: .running, supported: [.distance, .duration])
        let ex = PlannedExercise(exerciseName: "Trail Run", definitionId: trail.id, selectedMetrics: [.distance])

        #expect(store.displayUnit(.distance, for: ex) == .miles)

        // And the per-category preference tier keys off the same resolved category.
        #expect(store.setExercisePreference(exerciseNamed: "Run", scope: .category, units: [.distance: .meters]).succeeded)
        #expect(store.displayUnit(.distance, for: ex) == .meters)
    }

    /// A group total is one number with room for one unit, so the group's composition decides it —
    /// never the size of the number. Any floor work in the mix puts the whole total in metres.
    @Test func aGroupTotalTakesItsUnitFromTheGroupsComposition() {
        let units = StubUnitSystem(.imperial)
        let store = WorkoutStore(units: units, defaults: UserDefaults(suiteName: "reach-\(UUID().uuidString)")!)
        let run = PlannedExercise(exerciseName: "Run", definitionId: "run", selectedMetrics: [.distance])
        let sled = PlannedExercise(exerciseName: "Sled Push", definitionId: "sled_push", selectedMetrics: [.distance])

        let endurance = WorkoutGroup(label: "Intervals", children: [.exercise(run)])
        let mixed = WorkoutGroup(label: "Hybrid", children: [.exercise(run), .exercise(sled)])

        #expect(store.displayUnit(.distance, forTotalsIn: endurance) == .miles)
        #expect(store.displayUnit(.distance, forTotalsIn: mixed) == .meters)
        // Load is not a distance question and stays on the athlete's system either way.
        #expect(store.displayUnit(.load, forTotalsIn: mixed) == .pounds)
    }

    /// Absence of evidence is not evidence of endurance. A group that carries a distance total but
    /// whose children declare no distance-bearing movement (an AMRAP whose run got matched to a
    /// reps-only movement) must read metres, not fall vacuously through to the endurance unit.
    @Test func aGroupWithNoDistanceMovementReadsItsTotalInMetres() {
        let units = StubUnitSystem(.imperial)
        let store = WorkoutStore(units: units, defaults: UserDefaults(suiteName: "reach-\(UUID().uuidString)")!)
        let pullUp = PlannedExercise(exerciseName: "Pull-Up", definitionId: "pull_up", selectedMetrics: [.reps])
        let group = WorkoutGroup(label: "AMRAP",
                                 execution: GroupExecution(totalTargets: MetricValues([.distance: 100])),
                                 children: [.exercise(pullUp)])

        #expect(store.displayUnit(.distance, forTotalsIn: group) == .meters)
    }

    /// Retiring a unit must not be undone by state written before it was retired: pace no longer
    /// offers raw `s/m`, so a stored `s/m` falls through to the default instead of rendering "0:00".
    @Test func aStoredUnitThatIsNoLongerOfferedFallsThrough() {
        let units = StubUnitSystem(.imperial)
        let store = WorkoutStore(units: units, defaults: UserDefaults(suiteName: "reach-\(UUID().uuidString)")!)
        let stale = PlannedExercise(exerciseName: "Run", definitionId: "run",
                                    selectedMetrics: [.pace], displayUnits: [.pace: .secondsPerMeter])
        #expect(store.displayUnit(.pace, for: stale) == .secondsPerMile)
    }

    /// Pace is a time, so it reads as one. 4:35/km is 0.275 s/m canonical.
    @Test func paceReadsAsAClockInTheAthletesUnit() {
        #expect(MetricFormat.value(0.275, .pace, unit: .secondsPerKilometer) == "4:35/km")
        #expect(MetricFormat.value(0.275, .pace, unit: .secondsPerMile) == "7:23/mi")
        #expect(MetricFormat.editText(0.275, .pace, unit: .secondsPerKilometer) == "4:35")
        #expect(MetricFormat.columnHeader(.pace, unit: .secondsPerMile) == "PACE /MI")
        // Typed in the display unit, stored per meter — and round-trips.
        let canonical = MetricFormat.parse("4:35", .pace, unit: .secondsPerKilometer)
        #expect(abs((canonical ?? 0) - 0.275) < 0.0001)
    }

    /// Pace gained units; duration never had any. An imported "3 min" cell stores `.minutes` as its
    /// display unit, and the cascade must still read `3:00` as 180 seconds rather than 60× that.
    @Test func durationCascadeEntryStaysUnitFree() {
        let typed = MetricFormat.cascadeSeconds("300")   // digits shifted in for "3:00"
        #expect(MetricField.canonical(fromCascadeSeconds: typed, .duration, unit: .minutes) == 180)
        #expect(MetricField.canonical(fromCascadeSeconds: typed, .duration, unit: .seconds) == 180)
        #expect(MetricField.cascadeSeconds(fromCanonical: 180, .duration, unit: .minutes) == 180)

        // Pace is the metric that genuinely counts in the displayed unit: 4:35/km is 0.275 s/m.
        let pace = MetricField.canonical(fromCascadeSeconds: 275, .pace, unit: .secondsPerKilometer)
        #expect(abs(pace - 0.275) < 0.0001)
        #expect(abs(MetricField.cascadeSeconds(fromCanonical: 0.275, .pace, unit: .secondsPerKilometer) - 275) < 0.01)
    }

    /// The reported bug in one assertion: the store must follow a live change of the setting, not a
    /// value copied into it at some earlier moment.
    @Test func theStoreFollowsTheSettingWhenItChanges() {
        let units = StubUnitSystem(.metric)
        let store = WorkoutStore(units: units, defaults: UserDefaults(suiteName: "reach-\(UUID().uuidString)")!)
        // A run, because a sled reads in meters under both systems by design and so could not show
        // that the store is following the setting at all.
        let ex = PlannedExercise(exerciseName: "Run", definitionId: "run", selectedMetrics: [.distance, .load])

        #expect(store.displayUnit(.distance, for: ex) == .kilometers)
        units.unitSystem = .imperial
        #expect(store.displayUnit(.distance, for: ex) == .miles)
        #expect(store.displayUnit(.load, for: ex) == .pounds)
        #expect(store.displayUnit(.distance) == .miles)   // and with no exercise to hang it on
    }

    /// Storage stays canonical whatever the athlete is shown — the invariant `WorkoutStoreTests`
    /// asserts, restated here because this suite is what a future unit change gets read against.
    @Test func switchingSystemsNeverTouchesTheStoredValue() throws {
        let units = StubUnitSystem(.metric)
        let store = WorkoutStore(units: units, defaults: UserDefaults(suiteName: "reach-\(UUID().uuidString)")!)
        store.create(title: "Conditioning", goal: nil)
        store.addExercise(name: "Sled Push",
                          toContainerID: try #require(store.current?.blocks.first?.id),
                          atIndex: nil, sets: 1, reps: nil, load: nil,
                          durationSeconds: nil, distanceMeters: 121,
                          expectedRevisionToken: try #require(store.mutationTarget(.plan)?.revisionToken))

        func stored() -> Double? { store.current?.allExercises.first?.prescription.sets.first?.values[.distance] }
        let before = stored()
        units.unitSystem = .imperial
        #expect(stored() == before)
        #expect(abs((before ?? 0) - 121) < 0.001)
    }

    // MARK: - Surfaces that had drifted

    // The Plan tab's weekly distance tile lived here until the weekly-view redesign removed it (the
    // Today tab's "This Week" card is the one weekly total, and it reads performed work rather than
    // the plan). `PlanFormat` went with the tile, so this suite no longer has an aggregate case; the
    // distance-unit contract it pinned is `UnitSystem.displayUnit(metric:exercise:)`, covered above.

    /// The agent narrates from this text. Group totals and adjustments used to be handed to it in raw
    /// canonical units, so it told an imperial athlete their AMRAP target was "2000 m".
    @Test func theAgentSummaryStatesTheSystemAndSpeaksInIt() throws {
        let units = StubUnitSystem(.imperial)
        let store = WorkoutStore(units: units, defaults: UserDefaults(suiteName: "reach-\(UUID().uuidString)")!)
        store.create(title: "Engine", goal: nil)
        store.addExercise(name: "Run",
                          toContainerID: try #require(store.current?.blocks.first?.id),
                          atIndex: nil, sets: 1, reps: nil, load: nil,
                          durationSeconds: nil, distanceMeters: 1609.344,
                          expectedRevisionToken: try #require(store.mutationTarget(.plan)?.revisionToken))

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
