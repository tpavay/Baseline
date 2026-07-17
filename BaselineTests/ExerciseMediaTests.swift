import Foundation
import Testing
@testable import Baseline

struct ExerciseMediaTests {
    @Test func bundledManifestMatchesCatalog() throws {
        let manifest = ExerciseMediaManifest.current
        let mediaBackedCatalogIDs = Set(ExerciseCatalog.definitions.filter { $0.media != nil }.map(\.id))
        #expect(manifest.schemaVersion == 1)
        #expect(Set(manifest.exercises.keys) == mediaBackedCatalogIDs,
                "Every media-backed catalog exercise should have exactly one manifest entry.")
        #expect(manifest.exercises.values.filter {
            $0.publicationStatus == .draft || $0.publicationStatus == .blocked ||
                $0.publicationStatus == .retired
        }.isEmpty)
        #expect(manifest.exercises.values.filter {
            $0.publicationStatus == .ready || $0.publicationStatus == .published
        }.count == manifest.exercises.count)

        let wallBalls = try #require(manifest.exercises["wall_balls"])
        #expect(wallBalls.sourceFilename == "wallballs.png")
        #expect(wallBalls.version == 2)

        let skiErg = try #require(manifest.exercises["ski_erg"])
        #expect(skiErg.sourceFilename == "skiErg.png")
        #expect(skiErg.version == 2)
    }

    @Test(arguments: [
        "barbell_box_squat",
        "box_jump",
        "box_step_over",
        "burpee_to_plate",
        "calf_raise",
        "dual_db_thruster",
        "dumbbell_bench_press",
        "echo_bike",
        "elliptical",
        "hand_release_push_up",
        "hanging_leg_raise",
        "lateral_burpee_over_barbell",
        "leg_press",
        "plank",
        "stair_stepper",
    ])
    func expandedLibraryIsPublishedAndLinkedToCatalog(_ exerciseID: String) throws {
        let manifestMedia = try #require(ExerciseMediaManifest.current.exercises[exerciseID])
        let definition = try #require(ExerciseCatalog.definition(id: exerciseID))

        #expect(manifestMedia.publicationStatus == .published)
        #expect(manifestMedia.publishedThumbnailPath != nil)
        #expect(manifestMedia.publishedDetailPath != nil)
        #expect(definition.media == manifestMedia)
    }

    @Test(arguments: [
        "barbell_hip_thrust",
        "barbell_overhead_press",
        "barbell_walking_lunge",
        "bike_erg",
        "bodyweight_hip_thrust",
        "bodyweight_walking_lunge",
        "dumbbell_walking_lunge",
        "front_squat",
        "goblet_squat",
        "kettlebell_swing",
        "medicine_ball_slam",
        "single_arm_dumbbell_row",
        "single_leg_hip_thrust",
        "ski_erg",
        "sled_pull",
        "wall_balls",
    ])
    func incomingBatchIsDeployableAndLinkedToCatalog(_ exerciseID: String) throws {
        let manifestMedia = try #require(ExerciseMediaManifest.current.exercises[exerciseID])
        let definition = try #require(ExerciseCatalog.definition(id: exerciseID))

        #expect(manifestMedia.publicationStatus == .ready ||
                manifestMedia.publicationStatus == .published)
        #expect(definition.media == manifestMedia)
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
