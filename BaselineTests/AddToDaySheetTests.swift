import SwiftUI
import Testing
import UIKit
@testable import Baseline

/// The redesigned per-day add sheet (approved Lavish, screen 3): compact one-line options, a
/// one-tap "Make it a rest day", an empty workout that starts live logging, and an image import
/// that offers Camera or Photos. Hosted in a real window so taps go through the same accessibility
/// actions an athlete's touches resolve to.
@MainActor
@Suite(.serialized)
struct AddToDaySheetTests {

    // MARK: Pure routing

    @Test func importOffersCameraAndPhotosOnlyWhenACameraExists() {
        #expect(AddToDaySheet.importSources(cameraAvailable: true) == [.camera, .photoLibrary])
        #expect(AddToDaySheet.importSources(cameraAvailable: false) == [.photoLibrary])
    }

    @Test func theTitleNamesTheDayBeingDecided() {
        let cal = Calendar.planWeek
        let today = cal.startOfDay(for: Date())
        #expect(AddToDaySheet.title(for: today).hasPrefix("Today, "))
        #expect(AddToDaySheet.title(for: cal.date(byAdding: .day, value: 1, to: today)!)
            .hasPrefix("Tomorrow, "))
        let farOut = cal.date(byAdding: .day, value: 10, to: today)!
        #expect(AddToDaySheet.title(for: farOut)
            .hasPrefix(farOut.formatted(.dateTime.weekday(.wide))))
    }

    // MARK: Hosted behavior

    @Test func oneTapOptionsReportTheirChoice() async throws {
        let screen = try AddSheetScreen(cameraAvailable: true)
        defer { screen.tearDown() }
        try await screen.settle()

        #expect(screen.activate(labelled: "Make it a rest day"))
        try await screen.settleUntil { screen.selected.contains(.restDay) }

        #expect(screen.activate(labelled: "Start an empty workout"))
        try await screen.settleUntil { screen.selected.contains(.startEmptyWorkout) }

        #expect(screen.activate(labelled: "Build with Baseline"))
        try await screen.settleUntil { screen.selected.contains(.buildWithBaseline) }

        try screen.capture("add-to-day-sheet")
    }

    /// With a camera, the row opens a Camera / Photos dialog instead of choosing for the athlete.
    /// (The dialog's buttons are system alert views that don't answer `accessibilityActivate`, so
    /// the tap-through of each choice is covered by `importOffersCameraAndPhotosOnlyWhenACameraExists`
    /// and the no-camera flow below.)
    @Test func importFromImageOffersCameraAndPhotos() async throws {
        let screen = try AddSheetScreen(cameraAvailable: true)
        defer { screen.tearDown() }
        try await screen.settle()

        #expect(screen.activate(labelled: "Import from image"))
        try await screen.settleUntil { screen.element(labelled: "Choose from Photos") != nil }
        #expect(screen.element(labelled: "Take Photo") != nil)
        #expect(screen.selected.isEmpty, "Offering sources must not pre-select one")
        try screen.capture("add-to-day-sheet-import-dialog")
    }

    /// No camera (e.g. Simulator): the row must not dead-end in a one-option dialog — it goes
    /// straight to the photo library.
    @Test func importFromImageSkipsTheDialogWithoutACamera() async throws {
        let screen = try AddSheetScreen(cameraAvailable: false)
        defer { screen.tearDown() }
        try await screen.settle()

        #expect(screen.activate(labelled: "Import from image"))
        try await screen.settleUntil { screen.selected.contains(.importImage(.photoLibrary)) }
        #expect(screen.element(labelled: "Take Photo") == nil)
    }
}

/// Hosts the sheet's content as a window root — detents are presentation chrome; the behavior under
/// test is the option rows and their routing.
@MainActor
private final class AddSheetScreen: HostedScreen {
    let window: UIWindow
    private let recorder = SelectionRecorder()
    var selected: [AddToDayOption] { recorder.selected }

    init(cameraAvailable: Bool) throws {
        let recorder = self.recorder
        let root = AddToDaySheet(
            date: Calendar.planWeek.startOfDay(for: Date()),
            templates: [],
            cameraAvailable: cameraAvailable,
            onSelect: { option in recorder.selected.append(option) }
        )
        .preferredColorScheme(.dark)
        window = try Self.makeWindow(rootView: root)
    }

    private final class SelectionRecorder {
        var selected: [AddToDayOption] = []
    }
}
