import Foundation

struct ExerciseMedia: Codable, Equatable, Sendable {
    let sourceFilename: String
    let thumbnailPath: String
    let detailPath: String
    let previewVideoPath: String?
    let instructionalVideoPath: String?
    let version: Int
    let publicationStatus: ExerciseMediaPublicationStatus

    var publishedThumbnailPath: String? {
        guard publicationStatus == .published,
              Self.isValidStoragePath(
                thumbnailPath,
                expectedFilename: "thumbnail.png",
                expectedVersion: version
              ) else { return nil }
        return thumbnailPath
    }

    var publishedDetailPath: String? {
        guard publicationStatus == .published,
              Self.isValidStoragePath(
                detailPath,
                expectedFilename: "detail.png",
                expectedVersion: version
              ) else { return nil }
        return detailPath
    }

    static func isValidStoragePath(
        _ path: String,
        expectedFilename: String? = nil,
        expectedVersion: Int? = nil
    ) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 4,
              components.first == "exercise-media",
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              components[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }),
              components[2].first == "v",
              components[2].dropFirst().isEmpty == false,
              components[2].dropFirst().allSatisfy(\.isNumber),
              path.contains("\\") == false else { return false }
        if let expectedVersion, components[2] != "v\(expectedVersion)" { return false }
        return expectedFilename.map { components.last.map(String.init) == $0 } ?? true
    }
}
