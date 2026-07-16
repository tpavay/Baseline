import Foundation
import OSLog

enum WorkoutImportJobRepositoryError: Error, Equatable {
    case unsupportedSchema(version: Int, jobID: UUID, expiresAt: Date, lastUpdated: Date)
    case invalidPageIndex
    case invalidRelativePath
    case manifestIdentityMismatch
    case missingJob
}

struct WorkoutImportCancellationTombstone: Identifiable, Codable, Equatable, Sendable {
    var id: UUID { jobID }
    var jobID: UUID
    var serverJobID: String
    var requestID: UUID
    var createdAt: Date
}

protocol WorkoutImportJobStoring: Sendable {
    func create(_ job: WorkoutImportJob) async throws
    func load(_ id: UUID) async throws -> WorkoutImportJob?
    func mostRecentActiveJob(now: Date) async throws -> WorkoutImportJob?
    func save(_ job: WorkoutImportJob) async throws
    func writeSource(_ data: Data, jobID: UUID, pageIndex: Int) async throws -> String
    func writeImage(_ image: ImportedWorkoutImage, jobID: UUID, pageIndex: Int) async throws -> String
    func imageData(jobID: UUID, relativeFilename: String) async throws -> Data
    func remove(_ id: UUID) async
    func removeExpired(now: Date) async
    func saveCancellation(_ tombstone: WorkoutImportCancellationTombstone) async throws
    func pendingCancellations() async throws -> [WorkoutImportCancellationTombstone]
    func removeCancellation(_ id: UUID) async
}

actor FileWorkoutImportJobRepository: WorkoutImportJobStoring {
    static let folderName = "WorkoutImports"
    static let manifestFilename = "manifest.json"
    static let cancellationFolderName = "Cancellations"
    static let protectedWriteOptions: Data.WritingOptions = [.atomic, .completeFileProtection]

    private let root: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private static let logger = Logger(
        subsystem: "com.tylerpavay.Baseline",
        category: "WorkoutImportManifest"
    )

    private struct ManifestSchemaEnvelope: Decodable {
        var schemaVersion: Int
        var id: UUID
        var expiresAt: Date
        var lastUpdated: Date
    }

    init(root: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let root {
            self.root = root
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = applicationSupport.appending(path: Self.folderName, directoryHint: .isDirectory)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    func create(_ job: WorkoutImportJob) throws {
        try prepareJobDirectory(job.id)
        try persist(job)
    }

    func load(_ id: UUID) throws -> WorkoutImportJob? {
        let manifest = manifestURL(id)
        guard fileManager.fileExists(atPath: manifest.path) else { return nil }
        let data = try Data(contentsOf: manifest)
        let envelope = try decoder.decode(ManifestSchemaEnvelope.self, from: data)
        guard envelope.id == id else {
            throw WorkoutImportJobRepositoryError.manifestIdentityMismatch
        }
        guard envelope.schemaVersion == WorkoutImportJob.schemaVersion else {
            Self.logger.error(
                "Found incompatible workout import manifest for job \(id.uuidString, privacy: .public), schema \(envelope.schemaVersion)"
            )
            throw WorkoutImportJobRepositoryError.unsupportedSchema(
                version: envelope.schemaVersion,
                jobID: envelope.id,
                expiresAt: envelope.expiresAt,
                lastUpdated: envelope.lastUpdated
            )
        }
        let job = try decoder.decode(WorkoutImportJob.self, from: data)
        return job
    }

    func mostRecentActiveJob(now: Date = Date()) throws -> WorkoutImportJob? {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var jobs: [WorkoutImportJob] = []
        var incompatible: [WorkoutImportJobRepositoryError] = []
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            do {
                if let job = try load(id), job.expiresAt > now { jobs.append(job) }
            } catch let error as WorkoutImportJobRepositoryError {
                if case .unsupportedSchema(_, _, let expiresAt, _) = error,
                   expiresAt > now {
                    incompatible.append(error)
                }
            } catch {
                continue
            }
        }
        if let job = jobs.max(by: { $0.lastUpdated < $1.lastUpdated }) { return job }
        if let error = incompatible.max(by: { left, right in
            guard case .unsupportedSchema(_, _, _, let leftUpdated) = left,
                  case .unsupportedSchema(_, _, _, let rightUpdated) = right else { return false }
            return leftUpdated < rightUpdated
        }) {
            throw error
        }
        return nil
    }

    func save(_ job: WorkoutImportJob) throws {
        guard fileManager.fileExists(atPath: jobDirectory(job.id).path) else {
            throw WorkoutImportJobRepositoryError.missingJob
        }
        try persist(job)
    }

    func writeSource(_ data: Data, jobID: UUID, pageIndex: Int) throws -> String {
        guard (0..<WorkoutImageImportLimits.maximumImageCount).contains(pageIndex) else {
            throw WorkoutImportJobRepositoryError.invalidPageIndex
        }
        try WorkoutImageSourceValidator.validate(byteCount: data.count)
        try prepareJobDirectory(jobID)
        let relative = "sources/\(pageIndex).source"
        let sourceFolder = jobDirectory(jobID).appending(path: "sources", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try excludeFromBackup(sourceFolder)
        let destination = try resolvedURL(jobID: jobID, relativeFilename: relative)
        try data.write(to: destination, options: Self.protectedWriteOptions)
        return relative
    }

    func writeImage(_ image: ImportedWorkoutImage, jobID: UUID, pageIndex: Int) throws -> String {
        guard (0..<WorkoutImageImportLimits.maximumImageCount).contains(pageIndex) else {
            throw WorkoutImportJobRepositoryError.invalidPageIndex
        }
        try prepareJobDirectory(jobID)
        let relative = "pages/\(pageIndex).jpg"
        let pageFolder = jobDirectory(jobID).appending(path: "pages", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: pageFolder, withIntermediateDirectories: true)
        try excludeFromBackup(pageFolder)
        let destination = try resolvedURL(jobID: jobID, relativeFilename: relative)
        try image.data.write(to: destination, options: Self.protectedWriteOptions)
        return relative
    }

    func imageData(jobID: UUID, relativeFilename: String) throws -> Data {
        try Data(contentsOf: resolvedURL(jobID: jobID, relativeFilename: relativeFilename))
    }

    func remove(_ id: UUID) {
        try? fileManager.removeItem(at: jobDirectory(id))
    }

    func removeExpired(now: Date = Date()) {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for directory in directories {
            if directory.lastPathComponent == Self.cancellationFolderName { continue }
            guard let id = UUID(uuidString: directory.lastPathComponent) else {
                try? fileManager.removeItem(at: directory)
                continue
            }
            let job: WorkoutImportJob
            do {
                guard let loaded = try load(id) else { continue }
                job = loaded
            } catch WorkoutImportJobRepositoryError.unsupportedSchema(let version, _, let expiresAt, _) {
                if expiresAt <= now {
                    try? fileManager.removeItem(at: directory)
                } else {
                    Self.logger.error(
                        "Preserving incompatible workout import manifest for job \(id.uuidString, privacy: .public), schema \(version)"
                    )
                }
                continue
            } catch {
                try? fileManager.removeItem(at: directory)
                continue
            }
            if job.expiresAt <= now { try? fileManager.removeItem(at: directory) }
        }
    }

    func saveCancellation(_ tombstone: WorkoutImportCancellationTombstone) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try excludeFromBackup(root)
        let directory = cancellationDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try excludeFromBackup(directory)
        let data = try encoder.encode(tombstone)
        try data.write(to: cancellationURL(tombstone.id), options: Self.protectedWriteOptions)
    }

    func pendingCancellations() throws -> [WorkoutImportCancellationTombstone] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: cancellationDirectory(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            return try? decoder.decode(WorkoutImportCancellationTombstone.self, from: Data(contentsOf: url))
        }.sorted { $0.createdAt < $1.createdAt }
    }

    func removeCancellation(_ id: UUID) {
        try? fileManager.removeItem(at: cancellationURL(id))
    }

    private func persist(_ job: WorkoutImportJob) throws {
        let data = try encoder.encode(job)
        try data.write(to: manifestURL(job.id), options: Self.protectedWriteOptions)
    }

    private func prepareJobDirectory(_ id: UUID) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try excludeFromBackup(root)
        let directory = jobDirectory(id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try excludeFromBackup(directory)
    }

    private func resolvedURL(jobID: UUID, relativeFilename: String) throws -> URL {
        guard !relativeFilename.hasPrefix("/"),
              !relativeFilename.split(separator: "/").contains("..") else {
            throw WorkoutImportJobRepositoryError.invalidRelativePath
        }
        let directory = jobDirectory(jobID).standardizedFileURL
        let resolved = directory.appending(path: relativeFilename).standardizedFileURL
        guard resolved.path.hasPrefix(directory.path + "/") else {
            throw WorkoutImportJobRepositoryError.invalidRelativePath
        }
        return resolved
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
    }

    private func jobDirectory(_ id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func manifestURL(_ id: UUID) -> URL {
        jobDirectory(id).appending(path: Self.manifestFilename)
    }

    private func cancellationDirectory() -> URL {
        root.appending(path: Self.cancellationFolderName, directoryHint: .isDirectory)
    }

    private func cancellationURL(_ id: UUID) -> URL {
        cancellationDirectory().appending(path: "\(id.uuidString).json")
    }
}
