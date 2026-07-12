import Foundation
import Testing
@testable import Baseline

struct ExerciseMediaTests {
    @Test func bundledManifestMatchesCatalog() throws {
        let manifest = ExerciseMediaManifest.current
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.exercises.count == 17)
        #expect(manifest.exercises.values.filter { $0.publicationStatus == .published }.count == 15)
        #expect(manifest.exercises.values.filter { $0.publicationStatus == .blocked }.count == 2)

        for exerciseID in manifest.exercises.keys {
            #expect(ExerciseCatalog.definition(id: exerciseID) != nil)
        }

        let wallBalls = try #require(manifest.exercises["wall_balls"])
        #expect(wallBalls.sourceFilename == "WallBalls.png")
        #expect(wallBalls.publicationStatus == .blocked)

        let skiErg = try #require(manifest.exercises["ski_erg"])
        #expect(skiErg.publicationStatus == .blocked)
    }

    @Test func onlyPublishedMediaExposesNetworkPaths() {
        let ready = media(status: .ready)
        #expect(ready.publishedThumbnailPath == nil)
        #expect(ready.publishedDetailPath == nil)

        let published = media(status: .published)
        #expect(published.publishedThumbnailPath == "exercise-media/deadlift/v1/thumbnail.png")
        #expect(published.publishedDetailPath == "exercise-media/deadlift/v1/detail.png")

        let mismatchedVersion = media(status: .published, version: 2)
        #expect(mismatchedVersion.publishedThumbnailPath == nil)
        #expect(mismatchedVersion.publishedDetailPath == nil)
    }

    @Test(arguments: [
        "../users/private.png",
        "exercise-media/deadlift/../thumbnail.png",
        "exercise-media/deadlift/v1/nested/thumbnail.png",
        "exercise-media/deadlift/version1/thumbnail.png",
        "exercise-media/deadlift/v1/not-a-thumbnail.png",
        "exercise-media\\deadlift\\v1\\thumbnail.png"
    ])
    func rejectsInvalidThumbnailStoragePaths(_ path: String) {
        #expect(ExerciseMedia.isValidStoragePath(path, expectedFilename: "thumbnail.png") == false)
    }

    @Test func oldCustomDefinitionsDecodeWithoutMedia() throws {
        let json = """
        {
          "id": "custom_test",
          "name": "Custom Test",
          "category": "other",
          "supported": ["reps"],
          "defaults": ["reps"],
          "aliases": ["custom test"]
        }
        """

        let definition = try JSONDecoder().decode(ExerciseDefinition.self, from: Data(json.utf8))
        #expect(definition.media == nil)
    }

    @MainActor
    @Test func thumbnailModelDecodesClientData() async throws {
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let client = ExerciseMediaClient { _ in png }
        let model = ExerciseThumbnailModel()

        await model.load(path: "exercise-media/deadlift/v1/thumbnail.png", using: client)

        #expect(model.image?.width == 1)
        #expect(model.image?.height == 1)
    }

    private func media(status: ExerciseMediaPublicationStatus, version: Int = 1) -> ExerciseMedia {
        ExerciseMedia(
            sourceFilename: "Deadlift.png",
            thumbnailPath: "exercise-media/deadlift/v1/thumbnail.png",
            detailPath: "exercise-media/deadlift/v1/detail.png",
            previewVideoPath: nil,
            instructionalVideoPath: nil,
            version: version,
            publicationStatus: status
        )
    }
}
