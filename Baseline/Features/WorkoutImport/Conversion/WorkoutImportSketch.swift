import Foundation

/// What the model is asked for: a **comprehension** of the source, not a Baseline workout.
///
/// Every field is text, deliberately. `sets: "15"` is not the number 15 and `"400m"` is not a
/// distance of 400 metres — nothing in this shape can be logged against, unit-converted, or edited
/// set by set. Turning it into something that can is the job of `WorkoutImportSketchConverter`,
/// which is deterministic and unit-tested. The previous design asked the model for a rigid
/// intermediate representation and discarded the entire parse whenever it fell short of one
/// structural rule; measured against a real import, four model calls all succeeded and all four
/// were thrown away (`data/baseline-import-latency-p5`). A permissive schema also costs roughly a
/// third of the output tokens, and output tokens are what the latency is made of.
///
/// Unknown keys decode away and missing keys default, so a model that adds or omits a field
/// degrades the parse rather than failing it.
struct WorkoutImportSketch: Codable, Equatable, Sendable {
    var title: String = ""
    /// Coach commentary that belongs to the whole session: intent, scaling levels, execution notes.
    var notes: [String] = []
    var blocks: [Block] = []

    struct Block: Codable, Equatable, Sendable {
        var name: String = ""
        var notes: [String] = []
        var items: [Item] = []

        private enum CodingKeys: String, CodingKey { case name, notes, items }

        init(name: String = "", notes: [String] = [], items: [Item] = []) {
            self.name = name
            self.notes = notes
            self.items = items
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
            items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        }
    }

    /// One exercise card as the source wrote it.
    struct Item: Codable, Equatable, Sendable {
        /// The superset ordinal shared by the members of one group — "1" for a 1A/1B pair. Absent
        /// for a standalone movement. The letter is positional and is never carried here, because
        /// grouping in Baseline is one level deep and the order inside a group supplies it.
        var group: String?
        var name: String = ""
        /// How many times the work repeats, as written: "3", "15 x", "3 working sets".
        var sets: String?
        /// The work itself, as written: "400m", "8 reps", "20 sec", "6-8 reps".
        var prescription: String?
        /// Load as written: "60kg", "heavier than race weight".
        var load: String?
        var rest: String?
        /// Pace, RPE, or effort language: "3-5km pace", "8/9 RPE". Always prose.
        var intensity: String?
        var note: String?

        private enum CodingKeys: String, CodingKey {
            case group, name, sets, prescription, load, rest, intensity, note
        }

        init(
            group: String? = nil, name: String = "", sets: String? = nil, prescription: String? = nil,
            load: String? = nil, rest: String? = nil, intensity: String? = nil, note: String? = nil
        ) {
            self.group = group
            self.name = name
            self.sets = sets
            self.prescription = prescription
            self.load = load
            self.rest = rest
            self.intensity = intensity
            self.note = note
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            group = try c.decodeIfPresent(String.self, forKey: .group)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            sets = try c.decodeIfPresent(String.self, forKey: .sets)
            prescription = try c.decodeIfPresent(String.self, forKey: .prescription)
            load = try c.decodeIfPresent(String.self, forKey: .load)
            rest = try c.decodeIfPresent(String.self, forKey: .rest)
            intensity = try c.decodeIfPresent(String.self, forKey: .intensity)
            note = try c.decodeIfPresent(String.self, forKey: .note)
        }
    }

    private enum CodingKeys: String, CodingKey { case title, notes, blocks }

    init(title: String = "", notes: [String] = [], blocks: [Block] = []) {
        self.title = title
        self.notes = notes
        self.blocks = blocks
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        blocks = try c.decodeIfPresent([Block].self, forKey: .blocks) ?? []
    }
}
