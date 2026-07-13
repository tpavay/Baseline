import Foundation
import Testing
@testable import Baseline

/// The app-wide metric formatter: anything of a minute or more reads in minutes (m:ss), bare input in a
/// duration field means MINUTES, and edit-text round-trips exactly (what a field shows re-parses to the
/// same canonical value — the bug where typing "10:00" got mangled per keystroke lives or dies here).
struct MetricFormatTests {

    // MARK: Display

    @Test func durationDisplaysMinutesAboveSixtySeconds() {
        #expect(MetricFormat.duration(45) == "45s")
        #expect(MetricFormat.duration(60) == "1:00")
        #expect(MetricFormat.duration(300) == "5:00")
        #expect(MetricFormat.duration(1800) == "30:00")
        #expect(MetricFormat.duration(630) == "10:30")
        #expect(MetricFormat.duration(3900) == "1:05:00")
    }

    @Test func durationLongForAggregates() {
        #expect(MetricFormat.durationLong(45) == "45s")
        #expect(MetricFormat.durationLong(2280) == "38m")
        #expect(MetricFormat.durationLong(16800) == "4h 40m")
    }

    @Test func nonDurationValuesKeepUnits() {
        #expect(MetricFormat.value(100, .load, unit: .kilograms) == "100 kg")
        #expect(MetricFormat.value(1609.344, .distance, unit: .miles) == "1 mi")
        #expect(MetricFormat.value(600, .duration, unit: .seconds) == "10:00")   // unit pref ignored for time
        #expect(MetricFormat.value(600, .duration, unit: .minutes) == "10:00")
    }

    // MARK: Parsing — bare numbers are MINUTES

    @Test func parseDurationBareNumberMeansMinutes() {
        #expect(MetricFormat.parseDuration("10") == 600)
        #expect(MetricFormat.parseDuration("7.5") == 450)
        #expect(MetricFormat.parseDuration("30") == 1800)
    }

    @Test func parseDurationColonAndSuffixForms() {
        #expect(MetricFormat.parseDuration("10:30") == 630)
        #expect(MetricFormat.parseDuration("0:45") == 45)
        #expect(MetricFormat.parseDuration("1:05:00") == 3900)
        #expect(MetricFormat.parseDuration("10:") == 600)      // trailing colon = minutes typed so far
        #expect(MetricFormat.parseDuration("45s") == 45)
        #expect(MetricFormat.parseDuration("90 s") == 90)
        #expect(MetricFormat.parseDuration("10m") == 600)
        #expect(MetricFormat.parseDuration("10 min") == 600)
        #expect(MetricFormat.parseDuration("1h") == 3600)
        #expect(MetricFormat.parseDuration("abc") == nil)
        #expect(MetricFormat.parseDuration("") == nil)
        #expect(MetricFormat.parseDuration("1:2:3:4") == nil)
    }

    // MARK: Round-trip — a field's own display must re-parse to the same value

    @Test func editTextRoundTripsExactly() {
        for seconds in [1.0, 45, 59, 60, 61, 300, 630, 1800, 3599, 3600, 3900, 5405] {
            let text = MetricFormat.editText(seconds, .duration, unit: .seconds)
            #expect(MetricFormat.parse(text, .duration, unit: .seconds) == seconds, "duration \(seconds) → \(text)")
        }
        // Sub-minute renders with a colon so it can't be re-read as minutes.
        #expect(MetricFormat.editText(45, .duration, unit: .seconds) == "0:45")

        let load = MetricFormat.editText(102.5, .load, unit: .kilograms)
        #expect(MetricFormat.parse(load, .load, unit: .kilograms) == 102.5)
        let miles = MetricFormat.editText(1609.344, .distance, unit: .miles)   // "1"
        #expect(MetricFormat.parse(miles, .distance, unit: .miles) == 1609.344)
    }

    @Test func parseNonDurationUsesDisplayUnit() {
        #expect(MetricFormat.parse("225", .load, unit: .pounds).map { abs($0 - 102.058) < 0.01 } == true)
        #expect(MetricFormat.parse("5", .distance, unit: .kilometers) == 5000)
        #expect(MetricFormat.parse("12,5", .load, unit: .kilograms) == 12.5)   // comma decimal tolerated
        #expect(MetricFormat.parse("junk", .load, unit: .kilograms) == nil)
    }

    // MARK: Hardening — hostile input must never trap, display must never crash

    @Test func hostileInputNeverTrapsAndIsSanitized() {
        // The reproduced crash: huge digits (bare minutes ×60 > Int64.max) and "inf".
        #expect(MetricFormat.parseDuration("999999999999999999") == MetricFormat.maxDurationSeconds)
        #expect(MetricFormat.parseDuration("inf") == nil)
        #expect(MetricFormat.parse("inf", .load, unit: .kilograms) == nil)
        #expect(MetricFormat.parse("99999999999999999999", .reps, unit: .count) == MetricFormat.maxCanonicalValue)
        #expect(MetricFormat.parse("-5", .load, unit: .kilograms) == 0)        // negatives clamp to zero
        // Display paths survive absurd stored values (bad import/agent write) instead of trapping.
        #expect(MetricFormat.duration(.infinity) == "0s")
        #expect(MetricFormat.duration(1e300) == "168:00:00")                   // capped at 7 days
        #expect(MetricFormat.value(.infinity, .load, unit: .kilograms) == "— kg")
    }

    @Test func integerMetricsRoundOnParse() {
        #expect(MetricFormat.parse("5.7", .reps, unit: .count) == 6)           // reps are whole
        #expect(MetricFormat.parseDuration("0:45.5") == 46)                    // whole seconds
        #expect(MetricFormat.parse("102.5", .load, unit: .kilograms) == 102.5) // load keeps fractions
    }

    @Test func convertedValuesShowReadableDecimals() {
        #expect(MetricFormat.value(5000, .distance, unit: .miles) == "3.11 mi")   // not 3.10686
        #expect(MetricFormat.value(60, .load, unit: .pounds) == "132.28 lb")
        #expect(MetricFormat.editText(102.5, .load, unit: .kilograms) == "102.5") // trailing zeros trimmed
    }

    @Test func columnHeadersCarryUnits() {
        #expect(MetricFormat.columnHeader(.duration, unit: .seconds) == "TIME")
        #expect(MetricFormat.columnHeader(.load, unit: .pounds) == "LB")
        #expect(MetricFormat.columnHeader(.distance, unit: .miles) == "MI")
        #expect(MetricFormat.columnHeader(.reps, unit: .count) == "REPS")
    }
}
