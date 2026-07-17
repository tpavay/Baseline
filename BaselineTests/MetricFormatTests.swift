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

    // MARK: Digit-cascade duration entry (stopwatch-style: no colon key on the number pad)

    @Test func cascadeAppendBuildsTimeFromTheRight() {
        var digits = ""
        digits = MetricFormat.cascadeAppend(digits, "1"); #expect(MetricFormat.cascadeDisplay(digits) == "0:01")
        digits = MetricFormat.cascadeAppend(digits, "0"); #expect(MetricFormat.cascadeDisplay(digits) == "0:10")
        digits = MetricFormat.cascadeAppend(digits, "3"); #expect(MetricFormat.cascadeDisplay(digits) == "1:03")
        digits = MetricFormat.cascadeAppend(digits, "0"); #expect(MetricFormat.cascadeDisplay(digits) == "10:30")
        #expect(MetricFormat.cascadeSeconds(digits) == 630)
    }

    @Test func cascadeAppendIgnoresNonDigits() {
        #expect(MetricFormat.cascadeAppend("1", ":") == "1")
        #expect(MetricFormat.cascadeAppend("1", "s") == "1")
    }

    @Test func cascadeCapsAtSixDigits() {
        let digits = "1234567".reduce("") { MetricFormat.cascadeAppend($0, $1) }
        #expect(digits == "234567")   // oldest (most-significant) digit dropped, not the newest
        #expect(digits.count == 6)
    }

    @Test func cascadeBackspaceRemovesOneDigitAtATime_andFullyClears() {
        var digits = "1030"
        digits = MetricFormat.cascadeBackspace(digits); #expect(digits == "103")
        #expect(MetricFormat.cascadeDisplay(digits) == "1:03")
        digits = MetricFormat.cascadeBackspace(digits)
        digits = MetricFormat.cascadeBackspace(digits)
        digits = MetricFormat.cascadeBackspace(digits)
        #expect(digits == "")                                  // fully clears — no "stuck at 0:00"
        #expect(MetricFormat.cascadeDisplay(digits) == "")
        #expect(MetricFormat.cascadeBackspace("") == "")        // backspace on empty is a no-op
    }

    @Test func cascadeDigitsFromSecondsRoundTrips() {
        for seconds in [1.0, 45, 60, 630, 1800, 3900, 5405] {
            let digits = MetricFormat.cascadeDigits(fromSeconds: seconds)
            #expect(MetricFormat.cascadeSeconds(digits) == seconds, "seconds \(seconds) → digits \(digits)")
        }
        #expect(MetricFormat.cascadeDigits(fromSeconds: 0) == "")
    }

    /// Adversarial review found: an extreme synced value (168h = maxDurationSeconds) produced 7 raw
    /// digits, one more than cascadeAppend's 6-digit cap — so the *next* keystroke silently truncated a
    /// different leading digit than cascadeDigits itself did, jumping the value on first edit.
    @Test func cascadeDigitsCapsToSixLikeAppendDoes() {
        let digits = MetricFormat.cascadeDigits(fromSeconds: MetricFormat.maxDurationSeconds)   // 168:00:00
        #expect(digits.count <= 6)
        // Appending a digit afterward must not jump the value by truncating a *different* leading digit.
        let appended = MetricFormat.cascadeAppend(digits, "5")
        #expect(appended.count <= 6)
    }

    /// Adversarial review: classifying purely off `new.count < old.count` misreads "select-all then type
    /// a shorter replacement" as a backspace and silently drops the typed digit. Prefix-based
    /// classification must fall through to a full re-derive instead.
    @Test func cascadeEditHandlesSelectAllReplace() {
        // Selected all of "1:03" (digits "103") and typed "5" → the field now shows just "5".
        #expect(MetricFormat.cascadeEdit(old: "1:03", new: "5", rawDigits: "103") == "5")
    }

    /// Same review finding, the other blind spot: a same-length replacement matches neither the append
    /// nor backspace fast path and must not be silently dropped.
    @Test func cascadeEditHandlesSameLengthReplacement() {
        #expect(MetricFormat.cascadeEdit(old: "103", new: "105", rawDigits: "103") == "105")
    }

    /// When the replacement text is a formatted clock string (the realistic case — the field always
    /// displays with a colon), the fallback prefers reading it as m:ss over blindly stripping the colon:
    /// editing "1:03" to read "1:53" is best honored as "the athlete means 1:53", not "153".
    @Test func cascadeEditSameLengthReplacementWithColonParsesAsClockTime() {
        #expect(MetricFormat.cascadeEdit(old: "1:03", new: "1:53", rawDigits: "103") == "0153")
    }

    @Test func cascadeEditPasteOfFormattedDuration() {
        #expect(MetricFormat.cascadeEdit(old: "", new: "10:30", rawDigits: "") == "1030")
    }

    @Test func cascadeEditFastPathsMatchDirectAppendBackspace() {
        #expect(MetricFormat.cascadeEdit(old: "0:01", new: "0:010", rawDigits: "1") == MetricFormat.cascadeAppend("1", "0"))
        #expect(MetricFormat.cascadeEdit(old: "0:10", new: "0:1", rawDigits: "10") == MetricFormat.cascadeBackspace("10"))
    }

    @Test func columnHeadersCarryUnits() {
        #expect(MetricFormat.columnHeader(.duration, unit: .seconds) == "TIME")
        #expect(MetricFormat.columnHeader(.load, unit: .pounds) == "LB")
        #expect(MetricFormat.columnHeader(.distance, unit: .miles) == "MI")
        #expect(MetricFormat.columnHeader(.reps, unit: .count) == "REPS")
    }
}
