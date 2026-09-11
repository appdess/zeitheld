import Darwin
import Foundation

struct StoredHeroImage: Equatable, Sendable {
    let imageData: Data
    let fileURL: URL
}

enum GeneratedHeroImageStoreError: LocalizedError, Equatable, Sendable {
    case backupExclusionNotApplied
    case pendingCleanupFailed
    case operationSuperseded
    case stagedImageMissing
    case unsafeFilesystemEntry

    var errorDescription: String? {
        switch self {
        case .backupExclusionNotApplied:
            "The generated-image directory could not be excluded from device backups."
        case .pendingCleanupFailed:
            "An interrupted generated-image transaction could not be cleaned up."
        case .operationSuperseded:
            "A newer generated-image operation replaced this operation."
        case .stagedImageMissing:
            "The generated image awaiting commit is no longer available."
        case .unsafeFilesystemEntry:
            "The generated-image directory contains an unsafe filesystem entry."
        }
    }
}

protocol HeroImageBackupExclusionManaging: Sendable {
    func setExcludedFromBackup(at url: URL) throws
    func isExcludedFromBackup(at url: URL) throws -> Bool
}

protocol HeroImageAtomicPromoting: Sendable {
    /// Implementations must either fail before namespace replacement or return
    /// success after it; throwing after the final path has changed would make
    /// committed disk state ambiguous to the caller.
    func promote(stagingURL: URL, to finalURL: URL) throws
}

struct SystemHeroImageAtomicPromoter: HeroImageAtomicPromoting {
    func promote(stagingURL: URL, to finalURL: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: stagingURL.path
        )
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw GeneratedHeroImageStoreError.unsafeFilesystemEntry
        }
        let result = stagingURL.path.withCString { source in
            finalURL.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard result == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
    }
}

struct SystemHeroImageBackupExclusionManager: HeroImageBackupExclusionManaging {
    func setExcludedFromBackup(at url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    func isExcludedFromBackup(at url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        return values.isExcludedFromBackup == true
    }
}

private enum HeroImageTarget: String, CaseIterable, Sendable {
    case latest
    case selectedBackground = "selected"

    var committedFilename: String {
        switch self {
        case .latest: "latest-generated.png"
        case .selectedBackground: "selected-background.png"
        }
    }

    func stagingFilename(operationID: UUID) -> String {
        "\(rawValue)-\(operationID.uuidString.lowercased()).png"
    }

    func parsesStagingFilename(_ filename: String) -> Bool {
        let prefix = "\(rawValue)-"
        let suffix = ".png"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else {
            return false
        }
        let start = filename.index(filename.startIndex, offsetBy: prefix.count)
        let end = filename.index(filename.endIndex, offsetBy: -suffix.count)
        let identifier = String(filename[start..<end])
        guard let uuid = UUID(uuidString: identifier) else { return false }
        return filename == stagingFilename(operationID: uuid)
    }
}

private struct PendingHeroImageOperation: Sendable {
    let storeInstanceID: UUID
    let operationID: UUID
    let stagingURL: URL
    let imageData: Data
}

/// Store actors serialize their own calls, but multiple store instances can
/// address the same directory. Holding this process-wide lock for each complete
/// filesystem transition gives those instances one coherent committed view.
/// The durable source of truth remains the final and staging files: coordinator
/// state deliberately disappears on process termination.
private final class HeroImageOperationCoordinator: @unchecked Sendable {
    static let shared = HeroImageOperationCoordinator()

    let processLaunchID = UUID()
    private let lock = NSRecursiveLock()
    private var pendingOperations: [String: PendingHeroImageOperation] = [:]

    private init() {}

    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func pending(for target: HeroImageTarget, directory: URL) -> PendingHeroImageOperation? {
        pendingOperations[key(for: target, directory: directory)]
    }

    func setPending(
        _ operation: PendingHeroImageOperation?,
        for target: HeroImageTarget,
        directory: URL
    ) {
        pendingOperations[key(for: target, directory: directory)] = operation
    }

    func clearPending(
        for target: HeroImageTarget,
        directory: URL,
        storeInstanceID: UUID,
        operationID: UUID
    ) {
        let key = key(for: target, directory: directory)
        guard let current = pendingOperations[key],
              current.storeInstanceID == storeInstanceID,
              current.operationID == operationID else { return }
        pendingOperations.removeValue(forKey: key)
    }

    func clearAll(in directory: URL) {
        for target in HeroImageTarget.allCases {
            pendingOperations.removeValue(forKey: key(for: target, directory: directory))
        }
    }

    private func key(for target: HeroImageTarget, directory: URL) -> String {
        "\(directory.standardizedFileURL.path)|\(target.rawValue)"
    }
}

actor GeneratedHeroImageStore {
    private let instanceID = UUID()
    private let directory: URL
    private let fileManager: FileManager
    private let backupExclusionManager: any HeroImageBackupExclusionManaging
    private let atomicPromoter: any HeroImageAtomicPromoting
    private let operationCoordinator = HeroImageOperationCoordinator.shared

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        backupExclusionManager: any HeroImageBackupExclusionManaging =
            SystemHeroImageBackupExclusionManager(),
        atomicPromoter: any HeroImageAtomicPromoting = SystemHeroImageAtomicPromoter()
    ) {
        self.fileManager = fileManager
        self.backupExclusionManager = backupExclusionManager
        self.atomicPromoter = atomicPromoter
        if let directory {
            self.directory = directory.standardizedFileURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.directory = applicationSupport
                .appendingPathComponent("WatchLearn", isDirectory: true)
                .appendingPathComponent("GeneratedHeroes", isDirectory: true)
                .standardizedFileURL
        }
    }

    /// Without an operation identifier this is a direct committed write, used
    /// for setup and backwards-compatible callers. With an identifier the data
    /// is only staged; `commitLatest` is the sole transition to committed state.
    func saveLatest(
        _ imageData: Data,
        operationID: UUID? = nil
    ) throws -> StoredHeroImage {
        try operationCoordinator.synchronized {
            try validate(imageData)
            if let operationID {
                return try stage(
                    imageData,
                    target: .latest,
                    operationID: operationID
                )
            }
            return try writeCommitted(imageData, target: .latest)
        }
    }

    func loadLatest() throws -> StoredHeroImage? {
        try operationCoordinator.synchronized {
            try removeOrphanStagingFiles(for: .latest)
            return try loadCommitted(.latest)
        }
    }

    func deleteLatest(ifMatching imageData: Data) throws {
        try operationCoordinator.synchronized {
            try removeOrphanStagingFiles(for: .latest)
            guard let current = try loadCommitted(.latest),
                  current.imageData == imageData else { return }
            try removeOwnedFile(at: committedURL(for: .latest))
        }
    }

    func restoreLatest(
        _ previousImageData: Data?,
        ifCurrentMatches expectedImageData: Data,
        operationID: UUID
    ) throws {
        _ = previousImageData
        try operationCoordinator.synchronized {
            try cancelStagedOperation(
                target: .latest,
                expectedImageData: expectedImageData,
                operationID: operationID
            )
        }
    }

    @discardableResult
    func commitLatest(operationID: UUID) throws -> StoredHeroImage {
        try operationCoordinator.synchronized {
            try commit(target: .latest, operationID: operationID)
        }
    }

    func discardLatest(
        ifCurrentMatches expectedImageData: Data,
        operationID: UUID
    ) throws {
        try operationCoordinator.synchronized {
            try cancelStagedOperation(
                target: .latest,
                expectedImageData: expectedImageData,
                operationID: operationID
            )
        }
    }

    func selectLatestAsBackground(operationID: UUID? = nil) throws -> StoredHeroImage {
        try operationCoordinator.synchronized {
            try removeOrphanStagingFiles(for: .latest)
            guard let latest = try loadCommitted(.latest) else {
                throw CocoaError(.fileNoSuchFile)
            }
            if let operationID {
                return try stage(
                    latest.imageData,
                    target: .selectedBackground,
                    operationID: operationID
                )
            }
            return try writeCommitted(latest.imageData, target: .selectedBackground)
        }
    }

    func loadSelectedBackground() throws -> StoredHeroImage? {
        try operationCoordinator.synchronized {
            try removeOrphanStagingFiles(for: .selectedBackground)
            return try loadCommitted(.selectedBackground)
        }
    }

    func restoreSelectedBackground(
        _ previousImageData: Data?,
        ifCurrentMatches expectedImageData: Data,
        operationID: UUID
    ) throws {
        _ = previousImageData
        try operationCoordinator.synchronized {
            try cancelStagedOperation(
                target: .selectedBackground,
                expectedImageData: expectedImageData,
                operationID: operationID
            )
        }
    }

    @discardableResult
    func commitSelectedBackground(operationID: UUID) throws -> StoredHeroImage {
        try operationCoordinator.synchronized {
            try commit(target: .selectedBackground, operationID: operationID)
        }
    }

    func discardSelectedBackground(
        ifCurrentMatches expectedImageData: Data,
        operationID: UUID
    ) throws {
        try operationCoordinator.synchronized {
            try cancelStagedOperation(
                target: .selectedBackground,
                expectedImageData: expectedImageData,
                operationID: operationID
            )
        }
    }

    /// Deletes only the two committed files and strictly named transaction
    /// staging files inside this store's dedicated directory. Unrecognized
    /// files are never recursively removed. Coordinator ownership is cleared
    /// only after every required removal succeeds.
    func deleteAll() throws {
        try operationCoordinator.synchronized {
            guard try verifyDirectoryIfPresent() else {
                operationCoordinator.clearAll(in: directory)
                return
            }

            for target in HeroImageTarget.allCases {
                try removeOwnedFile(at: committedURL(for: target))
            }
            try removeAllOwnedStagingFiles()
            try removeDirectoryIfEmpty()
            operationCoordinator.clearAll(in: directory)
        }
    }

    private func stage(
        _ imageData: Data,
        target: HeroImageTarget,
        operationID: UUID
    ) throws -> StoredHeroImage {
        try removeOrphanStagingFiles(for: target)

        if let current = operationCoordinator.pending(for: target, directory: directory) {
            if current.storeInstanceID == instanceID,
               current.operationID == operationID {
                guard current.imageData == imageData else {
                    throw GeneratedHeroImageStoreError.operationSuperseded
                }
                let persisted = try loadValidatedRegularFile(at: current.stagingURL)
                guard persisted == imageData else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try applyAndVerifyBackupExclusion(at: current.stagingURL)
                return StoredHeroImage(imageData: imageData, fileURL: committedURL(for: target))
            }

            // A new transaction explicitly supersedes the previous live one.
            // Failure to remove the older stage leaves its ownership intact and
            // prevents a second candidate from being created.
            do {
                try removeOwnedStagingFile(at: current.stagingURL)
            } catch {
                throw GeneratedHeroImageStoreError.pendingCleanupFailed
            }
            operationCoordinator.clearPending(
                for: target,
                directory: directory,
                storeInstanceID: current.storeInstanceID,
                operationID: current.operationID
            )
        }

        try prepareStagingDirectoryForProtectedWrite()
        let stagingURL = stagingURL(for: target, operationID: operationID)
        do {
            try ensureDestinationIsAbsentOrRegular(stagingURL)
            try imageData.write(
                to: stagingURL,
                // This UUID path is never a committed destination. A direct
                // protected write avoids Foundation-owned temporary names;
                // any crash-partial file remains a strictly named, disposable
                // staging record for next-launch cleanup.
                options: [.completeFileProtection]
            )
            let persisted = try loadValidatedRegularFile(at: stagingURL)
            guard persisted == imageData else {
                throw CocoaError(.fileWriteUnknown)
            }
            try applyAndVerifyBackupExclusion(at: stagingURL)
        } catch {
            let stagingError = error
            do {
                try removeOwnedStagingFile(at: stagingURL)
            } catch {
                // The candidate could not be unlinked. Retain its exact owner
                // so a bounded rollback, superseding operation, or delete-all
                // can retry without ever mistaking it for committed state.
                operationCoordinator.setPending(
                    PendingHeroImageOperation(
                        storeInstanceID: instanceID,
                        operationID: operationID,
                        stagingURL: stagingURL,
                        imageData: imageData
                    ),
                    for: target,
                    directory: directory
                )
                throw GeneratedHeroImageStoreError.pendingCleanupFailed
            }
            throw stagingError
        }

        operationCoordinator.setPending(
            PendingHeroImageOperation(
                storeInstanceID: instanceID,
                operationID: operationID,
                stagingURL: stagingURL,
                imageData: imageData
            ),
            for: target,
            directory: directory
        )
        return StoredHeroImage(imageData: imageData, fileURL: committedURL(for: target))
    }

    private func commit(
        target: HeroImageTarget,
        operationID: UUID
    ) throws -> StoredHeroImage {
        let pending = try ownedPendingOperation(target: target, operationID: operationID)
        let persisted: Data
        do {
            persisted = try loadValidatedRegularFile(at: pending.stagingURL)
        } catch where isFileNotFound(error) {
            operationCoordinator.clearPending(
                for: target,
                directory: directory,
                storeInstanceID: instanceID,
                operationID: operationID
            )
            throw GeneratedHeroImageStoreError.stagedImageMissing
        }
        guard persisted == pending.imageData else {
            throw CocoaError(.fileReadCorruptFile)
        }

        // The staging record is independently protected immediately before
        // publication as well as when it is first registered.
        try applyAndVerifyBackupExclusion(at: pending.stagingURL)

        // Verification is repeated immediately before promotion. A failure
        // leaves both the prior committed file and staging file unchanged.
        try prepareDirectoryForProtectedWrite()
        let finalURL = committedURL(for: target)
        try ensureDestinationIsAbsentOrRegular(finalURL)
        try atomicPromoter.promote(stagingURL: pending.stagingURL, to: finalURL)

        // Atomic namespace replacement is the commit point. Everything below
        // is in-memory and nonthrowing, so a successful promotion can never be
        // reported to the UI as a failed commit.
        operationCoordinator.clearPending(
            for: target,
            directory: directory,
            storeInstanceID: instanceID,
            operationID: operationID
        )
        return StoredHeroImage(imageData: pending.imageData, fileURL: finalURL)
    }

    private func cancelStagedOperation(
        target: HeroImageTarget,
        expectedImageData: Data,
        operationID: UUID
    ) throws {
        let pending = try ownedPendingOperation(target: target, operationID: operationID)
        guard pending.imageData == expectedImageData else {
            throw GeneratedHeroImageStoreError.operationSuperseded
        }

        try removeOwnedStagingFile(at: pending.stagingURL)
        operationCoordinator.clearPending(
            for: target,
            directory: directory,
            storeInstanceID: instanceID,
            operationID: operationID
        )
    }

    private func ownedPendingOperation(
        target: HeroImageTarget,
        operationID: UUID
    ) throws -> PendingHeroImageOperation {
        guard let pending = operationCoordinator.pending(for: target, directory: directory),
              pending.storeInstanceID == instanceID,
              pending.operationID == operationID else {
            throw GeneratedHeroImageStoreError.operationSuperseded
        }
        return pending
    }

    private func writeCommitted(
        _ imageData: Data,
        target: HeroImageTarget
    ) throws -> StoredHeroImage {
        try removeOrphanStagingFiles(for: target)
        if let pending = operationCoordinator.pending(for: target, directory: directory) {
            do {
                try removeOwnedStagingFile(at: pending.stagingURL)
            } catch {
                throw GeneratedHeroImageStoreError.pendingCleanupFailed
            }
            operationCoordinator.clearPending(
                for: target,
                directory: directory,
                storeInstanceID: pending.storeInstanceID,
                operationID: pending.operationID
            )
        }

        try prepareDirectoryForProtectedWrite()
        let url = committedURL(for: target)
        try ensureDestinationIsAbsentOrRegular(url)
        try imageData.write(to: url, options: [.atomic, .completeFileProtection])
        let persisted = try loadValidatedRegularFile(at: url)
        guard persisted == imageData else {
            throw CocoaError(.fileWriteUnknown)
        }
        return StoredHeroImage(imageData: imageData, fileURL: url)
    }

    private func loadCommitted(_ target: HeroImageTarget) throws -> StoredHeroImage? {
        guard try verifyDirectoryIfPresent() else { return nil }
        let url = committedURL(for: target)
        do {
            return StoredHeroImage(
                imageData: try loadValidatedRegularFile(at: url),
                fileURL: url
            )
        } catch where isFileNotFound(error) {
            return nil
        }
    }

    private func removeOrphanStagingFiles(for target: HeroImageTarget) throws {
        guard try verifyDirectoryIfPresent() else { return }
        guard try verifyDirectoryIfPresent(stagingRootURL) else { return }
        let currentLaunchName = operationCoordinator.processLaunchID.uuidString.lowercased()

        for launchURL in try directoryContents(at: stagingRootURL) {
            guard isStrictLaunchDirectoryName(launchURL.lastPathComponent) else { continue }
            do {
                if launchURL.lastPathComponent != currentLaunchName {
                    try removeOwnedLaunchDirectory(launchURL)
                    continue
                }

                guard try verifyDirectoryIfPresent(launchURL) else { continue }
                let liveStagingURL = operationCoordinator
                    .pending(for: target, directory: directory)?
                    .stagingURL.standardizedFileURL
                for url in try directoryContents(at: launchURL)
                where target.parsesStagingFilename(url.lastPathComponent) {
                    if url.standardizedFileURL == liveStagingURL { continue }
                    try removeOwnedStagingFile(at: url)
                }
                try removeDirectoryIfEmpty(launchURL)
            } catch {
                throw GeneratedHeroImageStoreError.pendingCleanupFailed
            }
        }
        try removeDirectoryIfEmpty(stagingRootURL)
    }

    private func prepareDirectoryForProtectedWrite() throws {
        if try !verifyDirectoryIfPresent() {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        guard try verifyDirectoryIfPresent() else {
            throw GeneratedHeroImageStoreError.unsafeFilesystemEntry
        }
        try applyAndVerifyBackupExclusion(at: directory)
    }

    private func prepareStagingDirectoryForProtectedWrite() throws {
        try prepareDirectoryForProtectedWrite()
        try createOwnedDirectoryIfNeeded(stagingRootURL)
        try applyAndVerifyBackupExclusion(at: stagingRootURL)
        try createOwnedDirectoryIfNeeded(currentLaunchDirectoryURL)
        try applyAndVerifyBackupExclusion(at: currentLaunchDirectoryURL)
    }

    private func applyAndVerifyBackupExclusion(at url: URL) throws {
        try backupExclusionManager.setExcludedFromBackup(at: url)
        guard try backupExclusionManager.isExcludedFromBackup(at: url) else {
            throw GeneratedHeroImageStoreError.backupExclusionNotApplied
        }
    }

    private func createOwnedDirectoryIfNeeded(_ url: URL) throws {
        if try !verifyDirectoryIfPresent(url) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        }
        guard try verifyDirectoryIfPresent(url) else {
            throw GeneratedHeroImageStoreError.unsafeFilesystemEntry
        }
    }

    @discardableResult
    private func verifyDirectoryIfPresent() throws -> Bool {
        try verifyDirectoryIfPresent(directory)
    }

    @discardableResult
    private func verifyDirectoryIfPresent(_ url: URL) throws -> Bool {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw GeneratedHeroImageStoreError.unsafeFilesystemEntry
            }
            return true
        } catch where isFileNotFound(error) {
            return false
        }
    }

    private func loadValidatedRegularFile(at url: URL) throws -> Data {
        try verifyOwnedParentChain(for: url)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw GeneratedHeroImageStoreError.unsafeFilesystemEntry
        }
        guard let size = attributes[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= GeneratedHeroImageValidator.maximumEncodedImageBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        try validate(data)
        return data
    }

    private func ensureDestinationIsAbsentOrRegular(_ url: URL) throws {
        try verifyOwnedParentChain(for: url)
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw GeneratedHeroImageStoreError.unsafeFilesystemEntry
            }
        } catch where isFileNotFound(error) {
            return
        }
    }

    private func removeOwnedFile(at url: URL) throws {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let type = attributes[.type] as? FileAttributeType,
                  type == .typeRegular || type == .typeSymbolicLink else {
                throw GeneratedHeroImageStoreError.unsafeFilesystemEntry
            }
            // Removing a symbolic link removes the link itself; it never reads
            // or removes the link destination.
            try fileManager.removeItem(at: url)
        } catch where isFileNotFound(error) {
            return
        }
    }

    /// An unlink failure must not turn a disposable candidate into a backup
    /// liability. Reapply and read back exclusion on the exact regular file;
    /// if that metadata operation is unavailable, independently protect its
    /// verified, store-owned launch directory. The caller retains coordinator
    /// ownership by clearing it only after this function returns successfully.
    private func removeOwnedStagingFile(at url: URL) throws {
        do {
            try removeOwnedFile(at: url)
        } catch {
            let removalError = error
            do {
                guard try reapplyBackupExclusionToResidualStage(at: url) else {
                    // A remover may report an error after the namespace entry
                    // is already gone. In that state cleanup is complete.
                    return
                }
            } catch {
                throw GeneratedHeroImageStoreError.pendingCleanupFailed
            }
            throw removalError
        }
    }

    /// Returns `false` when no residual entry exists.
    private func reapplyBackupExclusionToResidualStage(at url: URL) throws -> Bool {
        let standardizedURL = url.standardizedFileURL
        let launchURL = standardizedURL.deletingLastPathComponent().standardizedFileURL
        let rootURL = launchURL.deletingLastPathComponent().standardizedFileURL
        guard rootURL.path == stagingRootURL.path,
              isStrictLaunchDirectoryName(launchURL.lastPathComponent),
              isStrictStagingFilename(standardizedURL.lastPathComponent),
              try verifyDirectoryIfPresent(),
              try verifyDirectoryIfPresent(stagingRootURL),
              try verifyDirectoryIfPresent(launchURL) else {
            throw GeneratedHeroImageStoreError.unsafeFilesystemEntry
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: standardizedURL.path)
        } catch where isFileNotFound(error) {
            return false
        }

        if attributes[.type] as? FileAttributeType == .typeRegular {
            do {
                try applyAndVerifyBackupExclusion(at: standardizedURL)
                return true
            } catch {
                // The verified launch directory is the bounded fallback for a
                // residual candidate whose own metadata cannot be updated.
            }
        }

        try applyAndVerifyBackupExclusion(at: launchURL)
        return true
    }

    private func verifyOwnedParentChain(for url: URL) throws {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        if parent.path == directory.path {
            guard try verifyDirectoryIfPresent() else {
                throw GeneratedHeroImageStoreError.unsafeFilesystemEntry
            }
            return
        }
        if parent.path == currentLaunchDirectoryURL.path {
            guard try verifyDirectoryIfPresent(),
                  try verifyDirectoryIfPresent(stagingRootURL),
                  try verifyDirectoryIfPresent(currentLaunchDirectoryURL) else {
                throw GeneratedHeroImageStoreError.unsafeFilesystemEntry
            }
            return
        }
        throw GeneratedHeroImageStoreError.unsafeFilesystemEntry
    }

    private func removeDirectoryIfEmpty() throws {
        try removeDirectoryIfEmpty(directory)
    }

    private func removeDirectoryIfEmpty(_ url: URL) throws {
        guard try directoryContents(at: url).isEmpty else { return }
        let result = url.path.withCString { Darwin.rmdir($0) }
        guard result == 0 else {
            if errno == ENOENT || errno == ENOTEMPTY { return }
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
    }

    private func directoryContents() throws -> [URL] {
        try directoryContents(at: directory)
    }

    private func directoryContents(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )
    }

    private func committedURL(for target: HeroImageTarget) -> URL {
        directory.appendingPathComponent(target.committedFilename, isDirectory: false)
    }

    private func stagingURL(for target: HeroImageTarget, operationID: UUID) -> URL {
        currentLaunchDirectoryURL.appendingPathComponent(
            target.stagingFilename(operationID: operationID),
            isDirectory: false
        )
    }

    private var stagingRootURL: URL {
        directory.appendingPathComponent(".hero-staging", isDirectory: true)
    }

    private var currentLaunchDirectoryURL: URL {
        stagingRootURL.appendingPathComponent(
            operationCoordinator.processLaunchID.uuidString.lowercased(),
            isDirectory: true
        )
    }

    private func removeAllOwnedStagingFiles() throws {
        guard try verifyDirectoryIfPresent(stagingRootURL) else { return }
        for launchURL in try directoryContents(at: stagingRootURL) {
            guard isStrictLaunchDirectoryName(launchURL.lastPathComponent) else { continue }
            try removeOwnedLaunchDirectory(launchURL)
        }
        try removeDirectoryIfEmpty(stagingRootURL)
    }

    private func removeOwnedLaunchDirectory(_ launchURL: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: launchURL.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            try removeOwnedFile(at: launchURL)
            return
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw GeneratedHeroImageStoreError.unsafeFilesystemEntry
        }
        for url in try directoryContents(at: launchURL) {
            guard isStrictStagingFilename(url.lastPathComponent) else {
                continue
            }
            let childAttributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let type = childAttributes[.type] as? FileAttributeType,
                  type == .typeRegular || type == .typeSymbolicLink else {
                throw GeneratedHeroImageStoreError.unsafeFilesystemEntry
            }
            try removeOwnedStagingFile(at: url)
        }
        try removeDirectoryIfEmpty(launchURL)
    }

    private func isStrictLaunchDirectoryName(_ filename: String) -> Bool {
        guard let uuid = UUID(uuidString: filename) else { return false }
        return filename == uuid.uuidString.lowercased()
    }

    private func isStrictStagingFilename(_ filename: String) -> Bool {
        HeroImageTarget.allCases.contains { $0.parsesStagingFilename(filename) }
    }

    private func validate(_ imageData: Data) throws {
        guard GeneratedHeroImageValidator.isValid(imageData) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private func isFileNotFound(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            return error.code == NSFileNoSuchFileError
                || error.code == NSFileReadNoSuchFileError
        }
        return error.domain == NSPOSIXErrorDomain && error.code == ENOENT
    }
}
