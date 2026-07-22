import Foundation

/// One loggable quantity recovered from source text, already in `MetricType.canonicalUnit`.
struct ImportQuantity: Equatable, Sendable {
    var metric: MetricType
    /// Canonical: metres, kilograms, seconds, reps, kcal. Never the unit the source happened to use.
    var canonicalValue: Double
}

/// Text → typed, canonical quantities. The deterministic half of import.
///
/// Two rules govern everything here, and both come from the captain.
///
/// **The source never dictates display units.** "2km" and "1.24mi" both become 2000 metres, and what
/// the athlete sees is decided later by `WorkoutStore.displayUnit(_:for:)` from
/// `AppSettings.unitSystem`. Storage is canonical; display is a preference.
///
/// **Ranges and effort targets stay coach text.** "6-8 reps", "3-5km pace", "7RPE", "max unbroken"
/// are prose a human reads, not numbers a set is logged against, and a shipping app in this exact
/// niche keeps them as prose too (`data/baseline-workout-structure-reference.md`). Inventing "6" or
/// "8" from "6-8 reps" would be the same class of mistake as the deleted fallback builder: a
/// confident answer to a question the source did not settle.
enum ImportQuantityParser {

    /// Metres per yard. Distance is stored in metres, so an imperial source converts on the way in.
    /// The kilometre, mile, and pound factors live on `MetricConvert` and are reused from there.
    private static let metersPerYard = 0.9144
    private static let secondsPerMinute = 60.0
    private static let secondsPerHour = 3_600.0

    /// Every unambiguous quantity in `text`, canonical, in the order written.
    ///
    /// Empty for coach text (see `isCoachText`) and empty when the text states the same metric more
    /// than once — "12.5m sled push / 12.5m sled drag / 12.5m sled push" is a compound prescription,
    /// not a 12.5 m set, and collapsing it to one number would lose two thirds of the work.
    static func quantities(in text: String?) -> [ImportQuantity] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard !isCoachText(text) else { return [] }

        var found: [ImportQuantity] = []
        for match in Self.matches(unitPattern, in: text) {
            guard let value = Double(match.value.replacingOccurrences(of: ",", with: "")),
                  value.isFinite, value >= 0,
                  let unit = unitTable[match.unit.lowercased()] else { continue }
            found.append(ImportQuantity(metric: unit.metric, canonicalValue: value * unit.toCanonical))
        }
        // "1:30" is a duration everywhere a workout is written, and no unit token accompanies it.
        if !found.contains(where: { $0.metric == .duration }),
           let clock = Self.matches(clockPattern, in: text).first,
           let minutes = Double(clock.value), let seconds = Double(clock.unit), seconds < 60 {
            found.append(ImportQuantity(metric: .duration, canonicalValue: minutes * secondsPerMinute + seconds))
        }

        let repeated = Set(found.map(\.metric).filter { metric in found.count { $0.metric == metric } > 1 })
        return found.filter { !repeated.contains($0.metric) }
    }

    /// A bare whole number with no unit, as an intended rep count — the "8" under a Reps column.
    /// Separate from `quantities` because a naked number only means reps in a context that already
    /// established one, so only a caller holding that context may ask.
    static func bareCount(in text: String?) -> Double? {
        guard let text, !isCoachText(text) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite, value >= 0, value == value.rounded() else { return nil }
        return value
    }

    /// Parse one athlete-stated value for a known metric into canonical storage.
    ///
    /// The metric supplies context only for dimensionless values such as reps and RPE.
    /// Dimensional values still require a spoken or written unit, so `185` can never become 185 kg.
    /// Pace is parsed here too because it combines a duration and a distance into seconds per meter.
    static func canonicalValue(for metric: MetricType, valueText: String) -> Double? {
        let text = valueText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let value: Double?
        switch metric {
        case .pace:
            value = paceCanonicalValue(in: text)
        case .reps:
            value = exactQuantity(for: .reps, in: text)?.canonicalValue ?? bareCount(in: text)
        case .rpe:
            value = contextualRPE(in: text)
        case .heartRateZoneTime:
            value = exactQuantity(for: .duration, in: text)?.canonicalValue
        case .power:
            value = powerCanonicalValue(in: text)
        default:
            value = exactQuantity(for: metric, in: text)?.canonicalValue
        }

        guard let value, value.isFinite, value >= 0 else { return nil }
        if metric.isInteger, value != value.rounded() { return nil }
        if metric == .rpe, value > 10 { return nil }
        return value
    }

    /// True when the text is language rather than a quantity, and must survive verbatim as coach text.
    static func isCoachText(_ text: String) -> Bool {
        let value = text.lowercased()
        // A number on both sides of a dash or slash is a range or a pair: "6-8 reps", "8/9 RPE".
        if contains(rangePattern, in: value) { return true }
        return coachVocabulary.contains { value.contains($0) }
    }

    /// Whatever the text says beyond the quantities it states — the coach still talking. Empty when
    /// the text is nothing but a quantity, which is how a caller knows repeating it as a note would
    /// only duplicate the sets it already became.
    static func residualText(in text: String?) -> String {
        guard let text else { return "" }
        var remainder = text
        for pattern in [unitPattern, clockPattern] {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            remainder = expression.stringByReplacingMatches(
                in: remainder,
                range: NSRange(remainder.startIndex..<remainder.endIndex, in: remainder),
                withTemplate: " "
            )
        }
        return remainder.filter { $0.isLetter || $0.isNumber }
    }

    /// Vocabulary that makes a prescription qualitative no matter what numbers sit beside it. Kept
    /// short and evidenced: every entry appears in the captured reference program or the VO2 session.
    private static let coachVocabulary = [
        "rpe", "pace", "amrap", "unbroken", "as prescribed", "as prescibed",
        "to failure", "in reserve", "rir", "max", "maximum", "each side", "per side",
    ]

    private struct Capture { var value: String; var unit: String }

    private struct UnitMeaning { var metric: MetricType; var toCanonical: Double }

    /// Longest tokens first inside each alternation so `min` never matches as `mi` + n, and the
    /// trailing `\b` keeps "400m" out of "40 min".
    private static let unitPattern =
        #"(\d+(?:[.,]\d+)?)\s*(kilometres|kilometers|kilometre|kilometer|km|miles|mile|mi|metres|meters|metre|meter|yards|yard|yds|yd|m|hours|hour|hrs|hr|minutes|minute|mins|min|seconds|second|secs|sec|s|kilograms|kilogram|kilos|kilo|kgs|kg|pounds|pound|lbs|lb|calories|calorie|kcal|cals|cal|reps|rep|bpm|rpm)\b"#
    private static let clockPattern = #"(\d+):(\d{2})\b"#
    private static let rangePattern = #"\d\s*(?:-|–|—|/|\bto\b)\s*\d"#

    private static let unitTable: [String: UnitMeaning] = {
        var table: [String: UnitMeaning] = [:]
        func put(_ tokens: [String], _ metric: MetricType, _ factor: Double) {
            for token in tokens { table[token] = UnitMeaning(metric: metric, toCanonical: factor) }
        }
        put(["m", "meter", "meters", "metre", "metres"], .distance, 1)
        put(["km", "kilometer", "kilometers", "kilometre", "kilometres"], .distance, MetricConvert.metersPerKilometer)
        put(["mi", "mile", "miles"], .distance, MetricConvert.metersPerMile)
        put(["yd", "yds", "yard", "yards"], .distance, metersPerYard)
        put(["s", "sec", "secs", "second", "seconds"], .duration, 1)
        put(["min", "mins", "minute", "minutes"], .duration, secondsPerMinute)
        put(["hr", "hrs", "hour", "hours"], .duration, secondsPerHour)
        put(["kg", "kgs", "kilo", "kilos", "kilogram", "kilograms"], .load, 1)
        put(["lb", "lbs", "pound", "pounds"], .load, MetricConvert.kgPerPound)
        put(["cal", "cals", "kcal", "calorie", "calories"], .calories, 1)
        put(["rep", "reps"], .reps, 1)
        put(["bpm"], .heartRate, 1)
        put(["rpm"], .cadence, 1)
        return table
    }()

    private static func exactQuantity(for metric: MetricType, in text: String) -> ImportQuantity? {
        let found = quantities(in: text)
        guard found.count == 1, found[0].metric == metric, residualText(in: text).isEmpty else { return nil }
        return found[0]
    }

    private static func contextualRPE(in text: String) -> Double? {
        guard let captures = captures(
            #"^\s*(?:rpe\s*)?(\d+(?:\.\d+)?)\s*(?:rpe)?\s*$"#,
            in: text
        ), let value = Double(captures[0]), value.isFinite, (0...10).contains(value) else {
            return nil
        }
        return value
    }

    /// Parse forms athletes naturally say, including `1:19 per 400 m`, `4:30 /km`, and `8 min/mi`.
    private static func paceCanonicalValue(in text: String) -> Double? {
        if let fields = captures(
            #"^\s*(\d+):([0-5]\d)\s*(?:per|/)\s*(\d+(?:\.\d+)?)?\s*(kilometres|kilometers|kilometre|kilometer|km|miles|mile|mi|metres|meters|metre|meter|m)\s*$"#,
            in: text
        ), let minutes = Double(fields[0]), let seconds = Double(fields[1]),
           let distance = paceDistance(value: fields[2], unit: fields[3]) {
            return (minutes * secondsPerMinute + seconds) / distance
        }

        if let fields = captures(
            #"^\s*(\d+(?:\.\d+)?)\s*(minutes|minute|mins|min|seconds|second|secs|sec|s)\s*(?:per|/)\s*(\d+(?:\.\d+)?)?\s*(kilometres|kilometers|kilometre|kilometer|km|miles|mile|mi|metres|meters|metre|meter|m)\s*$"#,
            in: text
        ), let duration = Double(fields[0]),
           let timeUnit = unitTable[fields[1].lowercased()],
           let distance = paceDistance(value: fields[2], unit: fields[3]) {
            return duration * timeUnit.toCanonical / distance
        }
        return nil
    }

    /// Power stays out of the shared unit table: the natural abbreviation `w` is also gym shorthand
    /// for "with" ("3x10 w 25lb vest"), so import never reads a power token and logging accepts
    /// only the full word.
    private static func powerCanonicalValue(in text: String) -> Double? {
        guard let fields = captures(#"^\s*(\d+(?:\.\d+)?)\s*(?:watts|watt)\s*$"#, in: text),
              let value = Double(fields[0]), value.isFinite else { return nil }
        return value
    }

    private static func paceDistance(value: String, unit: String) -> Double? {
        let amount = value.isEmpty ? 1 : Double(value)
        guard let amount, amount.isFinite, amount > 0,
              let meaning = unitTable[unit.lowercased()], meaning.metric == .distance else { return nil }
        return amount * meaning.toCanonical
    }

    /// A plain "does this pattern occur" test, for patterns that capture nothing.
    private static func contains(_ pattern: String, in value: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        return expression.firstMatch(
            in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)
        ) != nil
    }

    private static func matches(_ pattern: String, in value: String) -> [Capture] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap { result in
            guard result.numberOfRanges >= 3,
                  let first = Range(result.range(at: 1), in: value),
                  let second = Range(result.range(at: 2), in: value) else { return nil }
            return Capture(value: String(value[first]), unit: String(value[second]))
        }
    }

    private static func captures(_ pattern: String, in value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..<value.endIndex, in: value)
              ) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
    }
}

/// How many times the work repeats. Separate from `ImportQuantityParser` because a set count is a
/// structural fact about the exercise rather than a value logged against a set.
enum ImportSetCountParser {
    /// A source that appears to ask for more sets than this is far more likely to have been
    /// misread than to mean it, and silently building 400 rows would be worse than keeping the text.
    static let maximumSets = 30

    /// The stated set count, or nil when the text does not settle one — a range ("6-8"), a duration
    /// window ("4 min"), "AMRAP", or an implausible number all stay prose for the athlete to read.
    static func setCount(in text: String?) -> Int? {
        guard let text else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, !ImportQuantityParser.isCoachText(value) else { return nil }
        // A count carrying a unit is a duration or a distance, not a number of sets.
        guard ImportQuantityParser.quantities(in: value).isEmpty else { return nil }

        for pattern in [#"^(\d+)\s*(?:x|×)"#, #"(\d+)\s*(?:working\s+)?(?:sets?|rounds?)\b"#, #"^(\d+)$"#] {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = expression.firstMatch(
                      in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)
                  ),
                  let captured = Range(match.range(at: 1), in: value),
                  let count = Int(value[captured]) else { continue }
            return (1...maximumSets).contains(count) ? count : nil
        }
        return nil
    }
}
