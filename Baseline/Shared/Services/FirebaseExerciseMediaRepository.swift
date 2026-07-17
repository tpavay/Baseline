@preconcurrency import FirebaseStorage
import Foundation

actor FirebaseExerciseMediaRepository {
    private static let maximumImageBytes: Int64 = 5 * 1_024 * 1_024
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    private lazy var storage = Storage.storage()
    private let fileManager = FileManager.default
    private let diskCacheDirectory = URL.cachesDirectory.appending(
        path: "ExerciseMedia",
        directoryHint: .isDirectory
    )
    private let memoryCache = NSCache<NSString, NSData>()

    init() {
        memoryCache.totalCostLimit = 24 * 1_024 * 1_024
        memoryCache.countLimit = 100
    }

    func imageData(for storagePath: String) async throws -> Data {
        guard ExerciseMedia.isValidStoragePath(storagePath, expectedFilename: "thumbnail.png") else {
            throw ExerciseMediaLoadingError.invalidStoragePath
        }

        if let cached = memoryCache.object(forKey: storagePath as NSString) {
            return cached as Data
        }

        let diskURL = diskCacheDirectory.appending(path: storagePath)
        if let diskData = try? Data(contentsOf: diskURL), Self.isValidPNG(diskData) {
            memoryCache.setObject(diskData as NSData, forKey: storagePath as NSString, cost: diskData.count)
            return diskData
        }

        try Task.checkCancellation()
        let data = try await storage.reference(withPath: storagePath).data(maxSize: Self.maximumImageBytes)
        try Task.checkCancellation()
        guard Self.isValidPNG(data) else { throw ExerciseMediaLoadingError.invalidImageData }

        memoryCache.setObject(data as NSData, forKey: storagePath as NSString, cost: data.count)
        try? fileManager.createDirectory(
            at: diskURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: diskURL, options: .atomic)
        return data
    }

    private static func isValidPNG(_ data: Data) -> Bool {
        Int64(data.count) <= maximumImageBytes && data.starts(with: pngSignature)
    }
}
