import Photos
import SwiftUI
import UIKit

/// Renders the composed share image and routes it to Photos or the system share sheet.
@MainActor
struct ShareComposerExporter {
    static let exportSize = CGSize(width: 1080, height: 1920)

    func renderImage(viewModel: ShareComposerViewModel) async -> UIImage? {
        let canvas = ShareExportCanvas(viewModel: viewModel, size: Self.exportSize)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// Ferries a non-Sendable `UIImage` into the nonisolated Photos change block.
    private struct UncheckedImage: @unchecked Sendable { let image: UIImage }

    /// Saves the image to the Photos library using add-only permission.
    func saveToPhotos(_ image: UIImage) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        return await Self.writeToLibrary(image)
    }

    /// Performs the actual library write off the main actor.
    ///
    /// `PHPhotoLibrary` runs the change block on its own private serial queue.
    /// A change block created inside this `@MainActor` type is implicitly inferred
    /// MainActor-isolated, so running it off-main trips `dispatch_assert_queue`
    /// and crashes with `EXC_BREAKPOINT` (see Apple DTS forum 763665 /
    /// swiftlang/swift#75453). Marking this helper `nonisolated` keeps the
    /// change block free of MainActor isolation so Photos can run it on its queue safely.
    nonisolated private static func writeToLibrary(_ image: UIImage) async -> Bool {
        let boxed = UncheckedImage(image: image)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest.creationRequestForAsset(from: boxed.image)
                request.creationDate = Date()
            }
            return true
        } catch {
            return false
        }
    }

    /// Returns false when there is no window to present from, so the caller can say so rather than
    /// leaving a tapped share button looking like it did nothing.
    @discardableResult
    func presentShareSheet(image: UIImage) -> Bool {
        present(items: [image])
    }

    @discardableResult
    func presentShareSheet(text: String) -> Bool {
        present(items: [text])
    }

    private func present(items: [Any]) -> Bool {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController
        else {
            return false
        }
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        if let pop = activityVC.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 40, width: 0, height: 0)
        }
        presenter.present(activityVC, animated: true)
        return true
    }
}
