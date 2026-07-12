import CoreGraphics
import Foundation
import ImageIO
import Observation

@MainActor
@Observable
final class ExerciseThumbnailModel {
    private(set) var image: CGImage?
    private var requestedPath: String?

    func load(path: String?, using client: ExerciseMediaClient) async {
        requestedPath = path
        image = nil
        guard let path else { return }

        do {
            let data = try await client.imageData(path)
            try Task.checkCancellation()
            guard requestedPath == path else { return }
            image = Self.decodeImage(data)
        } catch is CancellationError {
            return
        } catch {
            guard requestedPath == path else { return }
            image = nil
        }
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
