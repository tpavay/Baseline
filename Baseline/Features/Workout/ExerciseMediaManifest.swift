import Foundation

enum ExerciseMediaManifest {
    struct Document: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let exercises: [String: ExerciseMedia]
    }

    private final class BundleToken {}

    static let current: Document = loadBundledManifest() ?? Document(schemaVersion: 1, exercises: [:])

    static func media(for exerciseDefinitionID: String) -> ExerciseMedia? {
        current.exercises[exerciseDefinitionID]
    }

    static func decode(_ data: Data) throws -> Document {
        try JSONDecoder().decode(Document.self, from: data)
    }

    private static func loadBundledManifest() -> Document? {
        let bundles = [Bundle.main, Bundle(for: BundleToken.self)]
        for bundle in bundles {
            guard let url = bundle.url(forResource: "exercise-media-manifest", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let document = try? decode(data) else { continue }
            return document
        }
        return nil
    }
}
