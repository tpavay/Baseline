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
private final class AddSheetScreen {
    private let window: UIWindow
    private(set) var selected: [AddToDayOption] = []

    init(cameraAvailable: Bool) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.first as? UIWindowScene,
            "No window scene: the test bundle must be hosted by the app."
        )
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let root = AddToDaySheet(
            date: Calendar.planWeek.startOfDay(for: Date()),
            templates: [],
            cameraAvailable: cameraAvailable,
            onSelect: { [weak self] option in self?.selected.append(option) }
        )
        .preferredColorScheme(.dark)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    func element(labelled text: String) -> NSObject? {
        AccessibilityElementWalker.elements(in: window)
            .first { $0.accessibilityLabel?.contains(text) ?? false }
    }

    func activate(labelled text: String) -> Bool {
        element(labelled: text)?.accessibilityActivate() ?? false
    }

    func settle() async throws {
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            spin(0.05)
            await Task.yield()
        }
        spin(0.1)
    }

    func settleUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            spin(0.05)
            await Task.yield()
        }
        try #require(condition(), "Condition not met within \(timeout)s")
    }

    private func spin(_ seconds: TimeInterval) {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
    }

    func capture(_ name: String) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        let url = AccessibilityElementWalker.evidenceDirectory.appendingPathComponent("\(name).png")
        try data.write(to: url, options: .atomic)
        print("SCREENSHOT \(url.path)")
    }
}
