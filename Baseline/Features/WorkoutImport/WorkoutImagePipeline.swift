import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum WorkoutImagePipelineError: LocalizedError {
    case noImages
    case tooManyImages(maximum: Int)
    case emptyData
    case tooLarge
    case unreadable
    case encodingFailed
    case noText

    var errorDescription: String? {
        switch self {
        case .noImages: "Choose at least one workout image."
        case .tooManyImages(let maximum): "Choose up to \(maximum) workout images at a time."
        case .emptyData: "That image is empty."
        case .tooLarge: "That image is too large. Choose one under 20 MB."
        case .unreadable: "Baseline couldn't read that image format."
        case .encodingFailed: "Baseline couldn't prepare that image."
        case .noText: "No workout text was found. Try a clearer or more tightly cropped image."
        }
    }
}

enum WorkoutImageImportLimits {
    static let maximumImageCount = 10
    static let maximumSourceBytes = 20 * 1_024 * 1_024
}

enum WorkoutImageSourceValidator {
    static func validate(byteCount: Int) throws {
        guard byteCount > 0 else { throw WorkoutImagePipelineError.emptyData }
        guard byteCount <= WorkoutImageImportLimits.maximumSourceBytes else {
            throw WorkoutImagePipelineError.tooLarge
        }
    }
}

enum WorkoutImageTransferFiles {
    static let folderName = "WorkoutImageTransfers"

    static var defaultRoot: URL {
        FileManager.default.temporaryDirectory.appending(path: folderName, directoryHint: .isDirectory)
    }

    static func copyProtectedFile(
        at source: URL,
        root: URL = defaultRoot,
        fileManager: FileManager = .default
    ) throws -> URL {
        let sourceValues = try source.resourceValues(forKeys: [.fileSizeKey])
        if let size = sourceValues.fileSize {
            try WorkoutImageSourceValidator.validate(byteCount: size)
        }
        let directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let destination = directory.appending(path: "source")
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try protectAndExclude(root, fileManager: fileManager)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try protectAndExclude(directory, fileManager: fileManager)
            try fileManager.copyItem(at: source, to: destination)
            try protectAndExclude(destination, fileManager: fileManager)
            let copiedSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try WorkoutImageSourceValidator.validate(byteCount: copiedSize)
            return destination
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    static func loadDataAndRemove(
        at fileURL: URL,
        fileManager: FileManager = .default
    ) async throws -> Data {
        defer { try? fileManager.removeItem(at: fileURL.deletingLastPathComponent()) }
        try Task.checkCancellation()
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize {
            try WorkoutImageSourceValidator.validate(byteCount: size)
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        try Task.checkCancellation()
        try WorkoutImageSourceValidator.validate(byteCount: data.count)
        return data
    }

    static func removeAll(
        root: URL = defaultRoot,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: root)
    }

    private static func protectAndExclude(_ url: URL, fileManager: FileManager) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}

protocol WorkoutImageNormalizing: Sendable {
    func normalize(_ data: Data) async throws -> ImportedWorkoutImage
}

struct WorkoutImageNormalizer: WorkoutImageNormalizing {
    static let maximumInputBytes = WorkoutImageImportLimits.maximumSourceBytes
    static let maximumLongEdge = 2_400

    func normalize(_ data: Data) async throws -> ImportedWorkoutImage {
        try WorkoutImageSourceValidator.validate(byteCount: data.count)
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                throw WorkoutImagePipelineError.unreadable
            }
            let maxEdge = max(width, height)
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(maxEdge, Self.maximumLongEdge),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                throw WorkoutImagePipelineError.unreadable
            }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw WorkoutImagePipelineError.encodingFailed
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw WorkoutImagePipelineError.encodingFailed }
            try Task.checkCancellation()
            return ImportedWorkoutImage(data: output as Data, pixelWidth: image.width, pixelHeight: image.height)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

protocol WorkoutTextRecognizing: Sendable {
    func recognize(image: ImportedWorkoutImage, sourceImageIndex: Int,
                   customWords: [String]) async throws -> [WorkoutTextObservation]
}

struct VisionWorkoutTextRecognizer: WorkoutTextRecognizing {
    func recognize(image: ImportedWorkoutImage, sourceImageIndex: Int,
                   customWords: [String]) async throws -> [WorkoutTextObservation] {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let pageDigest = WorkoutImportStableIdentity.page(data: image.data)
            let pageIdentity = WorkoutImportStableIdentity.digest([pageDigest, String(sourceImageIndex)])
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            request.customWords = Array(customWords.prefix(500))
            let handler = VNImageRequestHandler(data: image.data, options: [:])
            try handler.perform([request])
            let observations = (request.results ?? []).compactMap { observation -> WorkoutTextObservation? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                let bounds = WorkoutTextObservation.Rect(
                    x: box.origin.x,
                    y: box.origin.y,
                    width: box.width,
                    height: box.height
                )
                return WorkoutTextObservation(
                    id: WorkoutImportStableIdentity.observation(
                        pageDigest: pageIdentity,
                        text: candidate.string,
                        boundingBox: bounds
                    ),
                    text: candidate.string,
                    confidence: candidate.confidence,
                    boundingBox: bounds,
                    sourceImageIndex: sourceImageIndex
                )
            }.sorted { lhs, rhs in
                let lhsTop = lhs.boundingBox.y + lhs.boundingBox.height
                let rhsTop = rhs.boundingBox.y + rhs.boundingBox.height
                if abs(lhsTop - rhsTop) > 0.02 { return lhsTop > rhsTop }
                if abs(lhs.boundingBox.x - rhs.boundingBox.x) > 0.001 {
                    return lhs.boundingBox.x < rhs.boundingBox.x
                }
                return lhs.id < rhs.id
            }
            guard !observations.isEmpty else { throw WorkoutImagePipelineError.noText }
            try Task.checkCancellation()
            return observations
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

enum WorkoutImportTemporaryFiles {
    private static let folderName = "WorkoutImports"
    static let protectedWriteOptions: Data.WritingOptions = [.atomic, .completeFileProtection]

    static func writeProtected(_ image: ImportedWorkoutImage, sessionID: UUID, sourceImageIndex: Int) throws -> URL {
        guard (0..<WorkoutImageImportLimits.maximumImageCount).contains(sourceImageIndex) else {
            throw WorkoutImagePipelineError.tooManyImages(maximum: WorkoutImageImportLimits.maximumImageCount)
        }
        let folder = rootFolder.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(sourceImageIndex).jpg")
        try image.data.write(to: url, options: protectedWriteOptions)
        return url
    }

    static func remove(sessionID: UUID) {
        try? FileManager.default.removeItem(
            at: rootFolder.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
        )
        // Remove temporary files produced by the original single-image implementation.
        try? FileManager.default.removeItem(at: rootFolder.appending(path: "\(sessionID.uuidString).jpg"))
    }

    static func removeExpired(olderThan age: TimeInterval = 24 * 60 * 60, now: Date = Date()) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: rootFolder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modified) > age { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static var rootFolder: URL {
        FileManager.default.temporaryDirectory.appending(path: folderName, directoryHint: .isDirectory)
    }
}
