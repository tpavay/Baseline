import Foundation

/// Reads a `WorkoutImportSketch` out of JSON that is still arriving.
///
/// The display rule this exists to satisfy: exercises appear as real, editable rows as they resolve,
/// and **a row that has appeared is never rewritten** — only appended to. A screen where everything
/// jumps once the "real" answer lands teaches the athlete not to trust what they are looking at.
///
/// It gets there by closing the buffer rather than parsing incrementally. A scan finds every point
/// at which the document is between values, and closing the containers open at the latest such point
/// yields valid JSON describing everything that has definitely arrived. The final item of the final
/// block is then withheld, because that is the one still being written; holding it back for one more
/// item's worth of tokens is what makes every row that *is* shown final. `finish()` keeps everything.
struct WorkoutImportSketchStream: Sendable {
    private var buffer = ""

    init() {}

    /// Append a raw JSON fragment. Returns the sketch as it can be trusted so far, or nil when
    /// nothing complete has arrived yet.
    mutating func append(_ fragment: String) -> WorkoutImportSketch? {
        buffer += fragment
        return Self.decodeLongestPrefix(of: buffer).map(Self.withoutTrailingItem)
    }

    /// The complete sketch once the stream has ended. Falls back to the longest decodable prefix, so
    /// a truncated response still yields the exercises it did carry rather than nothing at all.
    func finish() -> WorkoutImportSketch? {
        Self.decode(buffer) ?? Self.decodeLongestPrefix(of: buffer)
    }

    var isEmpty: Bool { buffer.isEmpty }

    // MARK: - Decoding a partial buffer

    /// Close the containers left open at the latest point the document was between values, and
    /// decode. Walks back through earlier such points if the newest one somehow will not parse, so a
    /// surprising fragment costs one item rather than the whole stream.
    static func decodeLongestPrefix(of buffer: String) -> WorkoutImportSketch? {
        for closed in closures(of: buffer, limit: 8) {
            if let sketch = decode(closed) { return sketch }
        }
        return nil
    }

    /// Valid completions of `buffer`, longest first, at most `limit` of them.
    ///
    /// The limit is not cosmetic. `append` runs once per streamed fragment and a sketch has roughly
    /// one cut point per JSON token, so materializing a string per cut point would copy the whole
    /// buffer hundreds of times per delta. Only the newest few are ever decoded, so only those are
    /// ever built.
    static func closures(of buffer: String, limit: Int = .max) -> [String] {
        cutPoints(of: buffer).suffix(max(limit, 0)).reversed().map { cut in
            var closed = String(buffer[buffer.startIndex..<cut.index])
            for opener in cut.open.reversed() { closed.append(opener == "{" ? "}" : "]") }
            return closed
        }
    }

    private struct Cut { var index: String.Index; var open: [Character] }

    /// Scan once, recording each index at which the document sits between values — after a closed
    /// string, number, literal, object, or array, and immediately inside a freshly opened container.
    /// At any of those, appending the still-open closers produces valid JSON.
    private static func cutPoints(of buffer: String) -> [Cut] {
        /// What a string literal would mean right now. Only a *value* string ends a value; a key
        /// leaves the object mid-pair, where closing it would drop the key on the floor.
        enum Slot { case key, value }

        var open: [Character] = []
        var expecting: Slot = .value
        var cuts: [Cut] = []
        var index = buffer.startIndex

        func record(_ at: String.Index) { cuts.append(Cut(index: at, open: open)) }

        while index < buffer.endIndex {
            let character = buffer[index]
            switch character {
            case "\"":
                guard let end = endOfString(in: buffer, from: index) else { return cuts }  // unterminated
                if expecting == .value { record(end) }
                index = end
                continue
            case "{":
                open.append("{")
                expecting = .key
                index = buffer.index(after: index)
                record(index)
                continue
            case "[":
                open.append("[")
                expecting = .value
                index = buffer.index(after: index)
                record(index)
                continue
            case "}", "]":
                if !open.isEmpty { open.removeLast() }
                expecting = .value
                index = buffer.index(after: index)
                record(index)
                continue
            case ":":
                expecting = .value
            case ",":
                expecting = open.last == "{" ? .key : .value
            default:
                if character.isNumber || character == "-" {
                    guard let end = endOfNumberOrLiteral(in: buffer, from: index) else { return cuts }
                    record(end)
                    index = end
                    continue
                }
                if character == "t" || character == "f" || character == "n" {
                    guard let end = endOfNumberOrLiteral(in: buffer, from: index) else { return cuts }
                    record(end)
                    index = end
                    continue
                }
            }
            index = buffer.index(after: index)
        }
        return cuts
    }

    /// The index just past the closing quote, or nil when the string is still being written.
    private static func endOfString(in buffer: String, from start: String.Index) -> String.Index? {
        var index = buffer.index(after: start)
        var escaped = false
        while index < buffer.endIndex {
            let character = buffer[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return buffer.index(after: index)
            }
            index = buffer.index(after: index)
        }
        return nil
    }

    /// The index just past a number or bare literal, or nil when the buffer ends inside one — a
    /// trailing "40" may yet become "400", so it is not a value until a delimiter proves it is.
    private static func endOfNumberOrLiteral(in buffer: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < buffer.endIndex {
            let character = buffer[index]
            if character.isLetter || character.isNumber || character == "." || character == "+" || character == "-" {
                index = buffer.index(after: index)
                continue
            }
            return index
        }
        return nil
    }

    private static func decode(_ json: String) -> WorkoutImportSketch? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WorkoutImportSketch.self, from: data)
    }

    /// The last item of the last block is the one currently being written, so it is withheld. Once
    /// the next item starts, this one is closed and shows up — final, and never edited afterwards.
    private static func withoutTrailingItem(_ sketch: WorkoutImportSketch) -> WorkoutImportSketch {
        var sketch = sketch
        guard let lastBlock = sketch.blocks.indices.last,
              !sketch.blocks[lastBlock].items.isEmpty else { return sketch }
        sketch.blocks[lastBlock].items.removeLast()
        return sketch
    }
}
