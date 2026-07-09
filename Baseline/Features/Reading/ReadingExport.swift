import Foundation

extension Reading {
    /// Where a reading's raw per-frame camera signal is stored (nil for strap — the R-R array in
    /// the JSON is a strap's fullest record). Keyed by the reading id so it survives to History.
    static var rawSignalDirectory: URL {
        let dir = URL.documentsDirectory.appending(path: "raw-signals")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    var rawSignalURL: URL { Reading.rawSignalDirectory.appending(path: "\(id.uuidString).csv") }
    var hasRawSignal: Bool { FileManager.default.fileExists(atPath: rawSignalURL.path) }

    /// Persist the raw per-frame CSV alongside this reading so it's exportable later from History.
    func saveRawSignal(_ csv: String) {
        try? csv.write(to: rawSignalURL, atomically: true, encoding: .utf8)
    }

    /// Everything to share for diagnostics: the JSON (R-R + metrics, always) plus the raw
    /// per-frame CSV when the reading was a camera capture — "as much data as possible".
    func exportShareItems() -> [URL] {
        var items: [URL] = []
        if let json = exportFileURL() { items.append(json) }
        if hasRawSignal { items.append(rawSignalURL) }
        return items
    }

    /// Write a JSON snapshot of this reading — including every raw R-R interval — to a temp
    /// file for sharing. Used for diagnostics (so an off reading can be analysed offline).
    func exportFileURL() -> URL? {
        struct Export: Encodable {
            let schema = "baseline.reading.v2"
            let exportedAt: Date
            let date: Date
            let source: String
            let deviceName: String
            let position: String
            let kind: String
            let durationSeconds: Int
            let meanHR: Double
            let minHR: Int
            let maxHR: Int
            let rmssdMs: Double
            let lnRMSSD: Double
            let beatCount: Int
            let artifactsCorrected: Int
            let signalQuality: String
            let rawSignalAttached: Bool
            let rawSignalKind: String
            let rrIntervalsMs: [Double]
        }

        let export = Export(
            exportedAt: .now,
            date: date,
            source: source.rawValue,
            deviceName: deviceName,
            position: position.rawValue,
            kind: kind.rawValue,
            durationSeconds: durationSeconds,
            meanHR: meanHR,
            minHR: minHR,
            maxHR: maxHR,
            rmssdMs: rmssd,
            lnRMSSD: lnRMSSD,
            beatCount: beatCount,
            artifactsCorrected: artifacts,
            signalQuality: signalQuality.rawValue,
            rawSignalAttached: hasRawSignal,
            rawSignalKind: source == .camera ? "camera-per-frame-csv" : "ecg-130hz-csv",
            rrIntervalsMs: rrIntervalsMs
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(export) else { return nil }

        let stamp = Int(date.timeIntervalSince1970)
        let url = URL.temporaryDirectory.appending(path: "baseline-reading-\(stamp).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
