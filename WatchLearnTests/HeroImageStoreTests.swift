import Foundation
import UIKit
import XCTest
@testable import WatchLearn

final class HeroImageStoreTests: XCTestCase {
    func testDirectLatestImageCanBeSelectedAndReloadedAsBackground() async throws {
        let directory = temporaryStoreDirectory("basic")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GeneratedHeroImageStore(directory: directory)
        let image = try XCTUnwrap(testHeroPNG(color: .systemBlue))

        let latest = try await store.saveLatest(image)
        let selected = try await store.selectLatestAsBackground()

        let loadedLatest = try await store.loadLatest()
        let loadedSelection = try await store.loadSelectedBackground()
        XCTAssertEqual(loadedLatest?.imageData, image)
        XCTAssertEqual(loadedSelection?.imageData, image)
        XCTAssertNotEqual(latest.fileURL, selected.fileURL)
    }

    func testProvisionalLatestNeverReplacesCommittedImageBeforeCommit() async throws {
        let directory = temporaryStoreDirectory("provisional")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GeneratedHeroImageStore(directory: directory)
        let previous = try XCTUnwrap(testHeroPNG(color: .systemBlue))
        let replacement = try XCTUnwrap(testHeroPNG(color: .systemOrange))
        let operationID = UUID()
        _ = try await store.saveLatest(previous)

        let staged = try await store.saveLatest(replacement, operationID: operationID)
        let stagingURL = try XCTUnwrap(try onlyStagingFile(in: directory))

        XCTAssertEqual(staged.fileURL.lastPathComponent, "latest-generated.png")
        let beforeCommit = try await store.loadLatest()
        XCTAssertEqual(beforeCommit?.imageData, previous)

        let committed = try await store.commitLatest(operationID: operationID)
        XCTAssertEqual(committed.fileURL.lastPathComponent, "latest-generated.png")
        let afterCommit = try await store.loadLatest()
        XCTAssertEqual(afterCommit?.imageData, replacement)
        XCTAssertFalse(pathExists(stagingURL))
    }

    func testCommittedPreviousImageSurvivesCrashOrphanStagingRecovery() async throws {
        let directory = temporaryStoreDirectory("crash-orphan")
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = try XCTUnwrap(testHeroPNG(color: .systemBlue))
        let orphan = try XCTUnwrap(testHeroPNG(color: .systemOrange))
        let store = GeneratedHeroImageStore(directory: directory)
        _ = try await store.saveLatest(previous)
        let orphanURL = try createOrphanStagingFile(
            in: directory,
            target: "latest",
            data: orphan
        )

        let relaunchedStore = GeneratedHeroImageStore(directory: directory)
        let recovered = try await relaunchedStore.loadLatest()
        XCTAssertEqual(recovered?.imageData, previous)
        XCTAssertFalse(pathExists(orphanURL))
    }

    func testOrphanCleanupPreservesUnrecognizedFileInOldLaunchDirectory() async throws {
        let directory = temporaryStoreDirectory("orphan-unknown-sentinel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = try XCTUnwrap(testHeroPNG(color: .systemBlue))
        let orphan = try XCTUnwrap(testHeroPNG(color: .systemOrange))
        let store = GeneratedHeroImageStore(directory: directory)
        _ = try await store.saveLatest(previous)
        let orphanURL = try createOrphanStagingFile(
            in: directory,
            target: "latest",
            data: orphan
        )
        let sentinelURL = orphanURL.deletingLastPathComponent()
            .appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: sentinelURL)

        let recovered = try await store.loadLatest()

        XCTAssertEqual(recovered?.imageData, previous)
        XCTAssertFalse(pathExists(orphanURL))
        XCTAssertTrue(pathExists(sentinelURL))
        XCTAssertEqual(try Data(contentsOf: sentinelURL), Data("keep".utf8))
    }

    func testOrphanStagingWithoutCommittedImageRecoversToNil() async throws {
        let directory = temporaryStoreDirectory("orphan-no-final")
        defer { try? FileManager.default.removeItem(at: directory) }
        let orphanURL = try createOrphanStagingFile(
            in: directory,
            target: "latest",
            data: try XCTUnwrap(testHeroPNG(color: .systemOrange))
        )

        let store = GeneratedHeroImageStore(directory: directory)
        let recovered = try await store.loadLatest()
        XCTAssertNil(recovered)
        XCTAssertFalse(pathExists(orphanURL))
    }

    func testSecondStoreReadPreservesAnotherLivePendingWrite() async throws {
        let directory = temporaryStoreDirectory("two-store-read")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeA = GeneratedHeroImageStore(directory: directory)
        let storeB = GeneratedHeroImageStore(directory: directory)
        let previous = try XCTUnwrap(testHeroPNG(color: .systemBlue))
        let replacement = try XCTUnwrap(testHeroPNG(color: .systemOrange))
        let operationID = UUID()
        _ = try await storeA.saveLatest(previous)
        _ = try await storeA.saveLatest(replacement, operationID: operationID)
        let stagingURL = try XCTUnwrap(try onlyStagingFile(in: directory))

        let observedBeforeCommit = try await storeB.loadLatest()
        XCTAssertEqual(observedBeforeCommit?.imageData, previous)
        XCTAssertTrue(pathExists(stagingURL))

        _ = try await storeA.commitLatest(operationID: operationID)
        let observedAfterCommit = try await storeB.loadLatest()
        XCTAssertEqual(observedAfterCommit?.imageData, replacement)
    }

    func testDifferentByteSupersedingOperationCannotDivergeUIAndDisk() async throws {
        let directory = temporaryStoreDirectory("supersede-different")
        defer { try? FileManager.default.removeItem(at: directory) }
        let olderStore = GeneratedHeroImageStore(directory: directory)
        let newerStore = GeneratedHeroImageStore(directory: directory)
        let committed = try XCTUnwrap(testHeroPNG(color: .systemBlue))
        let olderImage = try XCTUnwrap(testHeroPNG(color: .systemOrange))
        let newerImage = try XCTUnwrap(testHeroPNG(color: .systemGreen))
        let olderID = UUID()
        let newerID = UUID()
        _ = try await olderStore.saveLatest(committed)
        _ = try await olderStore.saveLatest(olderImage, operationID: olderID)
        let olderStageURL = try XCTUnwrap(try onlyStagingFile(in: directory))
        _ = try await newerStore.saveLatest(newerImage, operationID: newerID)

        XCTAssertFalse(pathExists(olderStageURL))
        await assertSuperseded {
            _ = try await olderStore.commitLatest(operationID: olderID)
        }
        await assertSuperseded {
            try await olderStore.restoreLatest(
                committed,
                ifCurrentMatches: olderImage,
                operationID: olderID
            )
        }
        let beforeNewerCommit = try await newerStore.loadLatest()
        XCTAssertEqual(beforeNewerCommit?.imageData, committed)

        let promoted = try await newerStore.commitLatest(operationID: newerID)
        XCTAssertEqual(promoted.imageData, newerImage)
        let afterNewerCommit = try await olderStore.loadLatest()
        XCTAssertEqual(afterNewerCommit?.imageData, newerImage)
    }

    func testStaleSameByteOwnerCannotDeleteNewerGeneration() async throws {
        let directory = temporaryStoreDirectory("supersede-same")
        defer { try? FileManager.default.removeItem(at: directory) }
        let olderStore = GeneratedHeroImageStore(directory: directory)
        let newerStore = GeneratedHeroImageStore(directory: directory)
        let image = try XCTUnwrap(testHeroPNG(color: .systemOrange))
        let olderID = UUID()
        let newerID = UUID()
        _ = try await olderStore.saveLatest(image, operationID: olderID)
        _ = try await newerStore.saveLatest(image, operationID: newerID)

        await assertSuperseded {
            try await olderStore.discardLatest(
                ifCurrentMatches: image,
                operationID: olderID
            )
        }
        _ = try await newerStore.commitLatest(operationID: newerID)
        await assertSuperseded {
            try await olderStore.discardLatest(
                ifCurrentMatches: image,
                operationID: olderID
            )
        }
        let persisted = try await newerStore.loadLatest()
        XCTAssertEqual(persisted?.imageData, image)
    }

    func testLatestCommitBackupFailurePreservesOldFinalAndRetryableStage() async throws {
        let directory = temporaryStoreDirectory("commit-backup-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = SequencedBackupExclusionManager(results: [
            true, // Initial committed-directory verification.
            true, true, true, true, // Stage directory, root, launch, and exact file.
            true, false, // Exact pre-publish check, then failed directory check.
            true, true, // Retry exact-file and directory checks.
        ])
        let store = GeneratedHeroImageStore(
            directory: directory,
            backupExclusionManager: backup
        )
        let previous = try XCTUnwrap(testHeroPNG(color: .systemBlue))
        let replacement = try XCTUnwrap(testHeroPNG(color: .systemOrange))
        let operationID = UUID()
        _ = try await store.saveLatest(previous)
        _ = try await store.saveLatest(replacement, operationID: operationID)
        let stagingURL = try XCTUnwrap(try onlyStagingFile(in: directory))

        do {
            _ = try await store.commitLatest(operationID: operationID)
            XCTFail("Expected final commit backup verification failure")
        } catch {
            XCTAssertEqual(error as? GeneratedHeroImageStoreError, .backupExclusionNotApplied)
        }
        let afterFailedCommit = try await store.loadLatest()
        XCTAssertEqual(afterFailedCommit?.imageData, previous)
        XCTAssertTrue(pathExists(stagingURL))

        _ = try await store.commitLatest(operationID: operationID)
        let afterRetry = try await store.loadLatest()
        XCTAssertEqual(afterRetry?.imageData, replacement)
    }

    func testAtomicPromotionFailurePreservesOldFinalAndCandidateForRetry() async throws {
        let directory = temporaryStoreDirectory("atomic-promotion-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let promoter = FirstPromotionFailingPromoter()
        let store = GeneratedHeroImageStore(
            directory: directory,
            atomicPromoter: promoter
        )
        let previous = try XCTUnwrap(testHeroPNG(color: .systemBlue))
        let replacement = try XCTUnwrap(testHeroPNG(color: .systemOrange))
        let operationID = UUID()
        _ = try await store.saveLatest(previous)
        _ = try await store.saveLatest(replacement, operationID: operationID)
        let stagingURL = try XCTUnwrap(try onlyStagingFile(in: directory))

        do {
            _ = try await store.commitLatest(operationID: operationID)
            XCTFail("Expected injected atomic promotion failure")
        } catch {
            XCTAssertEqual(error as? PromotionFixtureError, .injectedFailure)
        }
        let afterFailedPromotion = try await store.loadLatest()
        XCTAssertEqual(afterFailedPromotion?.imageData, previous)
        XCTAssertTrue(pathExists(stagingURL))

        _ = try await store.commitLatest(operationID: operationID)
        let afterPromotionRetry = try await store.loadLatest()
        XCTAssertEqual(afterPromotionRetry?.imageData, replacement)
    }

    func testStagingBackupFailureCreatesNoCandidateOrFinal() async throws {
        let directory = temporaryStoreDirectory("stage-backup-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GeneratedHeroImageStore(
            directory: directory,
            backupExclusionManager: SequencedBackupExclusionManager(results: [false])
        )

        do {
            _ = try await store.saveLatest(
                try XCTUnwrap(testHeroPNG(color: .systemOrange)),
                operationID: UUID()
            )
            XCTFail("Expected staging backup verification failure")
        } catch {
            XCTAssertEqual(error as? GeneratedHeroImageStoreError, .backupExclusionNotApplied)
        }
        let committed = try await store.loadLatest()
        XCTAssertNil(committed)
        XCTAssertEqual(try directoryEntriesIfPresent(directory), [])
    }

    func testCancellationRemovesOnlyStagingAndPreservesPreviousFinal() async throws {
        let directory = temporaryStoreDirectory("cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GeneratedHeroImageStore(directory: directory)
        let previous = try XCTUnwrap(testHeroPNG(color: .systemBlue))
        let replacement = try XCTUnwrap(testHeroPNG(color: .systemOrange))
        let operationID = UUID()
        _ = try await store.saveLatest(previous)
        _ = try await store.saveLatest(replacement, operationID: operationID)
        let stagingURL = try XCTUnwrap(try onlyStagingFile(in: directory))

        try await store.restoreLatest(
            previous,
            ifCurrentMatches: replacement,
            operationID: operationID
        )

        XCTAssertFalse(pathExists(stagingURL))
        let persisted = try await store.loadLatest()
        XCTAssertEqual(persisted?.imageData, previous)
    }

    func testCancellationWithNoPreviousFinalLeavesNoCommittedImage() async throws {
        let directory = temporaryStoreDirectory("cancel-no-final")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GeneratedHeroImageStore(directory: directory)
        let image = try XCTUnwrap(testHeroPNG(color: .systemOrange))
        let operationID = UUID()
        _ = try await store.saveLatest(image, operationID: operationID)

        try await store.restoreLatest(
            nil,
            ifCurrentMatches: image,
            operationID: operationID
        )

        let persisted = try await store.loadLatest()
        XCTAssertNil(persisted)
    }

    func testSelectedBackgroundIsPublishedOnlyAfterCommit() async throws {
        let directory = temporaryStoreDirectory("selected-commit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GeneratedHeroImageStore(directory: directory)
        let previous = try XCTUnwrap(testHeroPNG(color: .systemBlue))
        let replacement = try XCTUnwrap(testHeroPNG(color: .systemOrange))
        _ = try await store.saveLatest(previous)
        _ = try await store.selectLatestAsBackground()
        _ = try await store.saveLatest(replacement)
        let operationID = UUID()
        _ = try await store.selectLatestAsBackground(operationID: operationID)

        let beforeCommit = try await store.loadSelectedBackground()
        XCTAssertEqual(beforeCommit?.imageData, previous)
        let committed = try await store.commitSelectedBackground(operationID: operationID)
        XCTAssertEqual(committed.imageData, replacement)
        let afterCommit = try await store.loadSelectedBackground()
        XCTAssertEqual(afterCommit?.imageData, replacement)
    }

    func testDeleteAllFailurePreservesPendingOwnershipForRetry() async throws {
        let directory = temporaryStoreDirectory("delete-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = PrefixRemovalFailingFileManager(
            failingPrefix: "latest-",
            failureCount: 1
        )
        let store = GeneratedHeroImageStore(directory: directory, fileManager: fileManager)
        let image = try XCTUnwrap(testHeroPNG(color: .systemOrange))
        let operationID = UUID()
        _ = try await store.saveLatest(image, operationID: operationID)

        do {
            try await store.deleteAll()
            XCTFail("Expected injected staging removal failure")
        } catch {
            XCTAssertEqual(error as? RemovalFixtureError, .injectedFailure)
        }

        // This succeeds only if deleteAll retained the exact operation owner.
        try await store.discardLatest(
            ifCurrentMatches: image,
            operationID: operationID
        )
        try await store.deleteAll()
        XCTAssertFalse(pathExists(directory))
    }

    func testDeleteAllBetweenStageAndCommitInvalidatesStaleCommit() async throws {
        let directory = temporaryStoreDirectory("delete-fence")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GeneratedHeroImageStore(directory: directory)
        let previous = try XCTUnwrap(testHeroPNG(color: .systemBlue))
        let replacement = try XCTUnwrap(testHeroPNG(color: .systemOrange))
        let operationID = UUID()
        _ = try await store.saveLatest(previous)
        _ = try await store.saveLatest(replacement, operationID: operationID)

        try await store.deleteAll()

        await assertSuperseded {
            _ = try await store.commitLatest(operationID: operationID)
        }
        let persisted = try await store.loadLatest()
        XCTAssertNil(persisted)
        XCTAssertFalse(pathExists(directory))
    }

    func testDeleteAllIsScopedAndLeavesUnrecognizedFiles() async throws {
        let parent = temporaryStoreDirectory("delete-scope")
        let directory = parent.appendingPathComponent("GeneratedHeroes", isDirectory: true)
        let sibling = parent.appendingPathComponent("keep-me.txt")
        let unknown = directory.appendingPathComponent("user-file.txt")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("sibling".utf8).write(to: sibling)
        try Data("unknown".utf8).write(to: unknown)
        let store = GeneratedHeroImageStore(directory: directory)
        _ = try await store.saveLatest(try XCTUnwrap(testHeroPNG(color: .systemBlue)))

        try await store.deleteAll()

        XCTAssertTrue(pathExists(directory))
        XCTAssertTrue(pathExists(unknown))
        XCTAssertTrue(pathExists(sibling))
        let latest = try await store.loadLatest()
        XCTAssertNil(latest)
    }

    func testLoadRejectsFinalSymlinkWithoutFollowingIt() async throws {
        let parent = temporaryStoreDirectory("final-symlink")
        let directory = parent.appendingPathComponent("GeneratedHeroes", isDirectory: true)
        let external = parent.appendingPathComponent("external.png")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = try XCTUnwrap(testHeroPNG(color: .systemBlue))
        try image.write(to: external)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("latest-generated.png"),
            withDestinationURL: external
        )
        let store = GeneratedHeroImageStore(directory: directory)

        do {
            _ = try await store.loadLatest()
            XCTFail("Expected symlink rejection")
        } catch {
            XCTAssertEqual(error as? GeneratedHeroImageStoreError, .unsafeFilesystemEntry)
        }
        XCTAssertEqual(try Data(contentsOf: external), image)
    }

    func testOrphanStagingSymlinkIsUnlinkedWithoutFollowingDestination() async throws {
        let parent = temporaryStoreDirectory("staging-symlink")
        let directory = parent.appendingPathComponent("GeneratedHeroes", isDirectory: true)
        let external = parent.appendingPathComponent("external.png")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = try XCTUnwrap(testHeroPNG(color: .systemBlue))
        try image.write(to: external)
        let launchURL = directory
            .appendingPathComponent(".hero-staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: launchURL, withIntermediateDirectories: true)
        let stagingURL = launchURL.appendingPathComponent(
            "latest-\(UUID().uuidString.lowercased()).png"
        )
        try FileManager.default.createSymbolicLink(at: stagingURL, withDestinationURL: external)
        let store = GeneratedHeroImageStore(directory: directory)

        let latest = try await store.loadLatest()
        XCTAssertNil(latest)
        XCTAssertFalse(pathExists(stagingURL))
        XCTAssertEqual(try Data(contentsOf: external), image)
    }

    func testRejectsInvalidImageBeforeWriting() async throws {
        let directory = temporaryStoreDirectory("invalid")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GeneratedHeroImageStore(directory: directory)

        do {
            _ = try await store.saveLatest(Data("not an image".utf8))
            XCTFail("Expected invalid image rejection")
        } catch {
            XCTAssertNotNil(error as? CocoaError)
        }
        XCTAssertFalse(pathExists(directory.appendingPathComponent("latest-generated.png")))
    }
}

private enum BackupExclusionFixtureError: Error, Equatable {
    case unexpectedVerification
}

private final class SequencedBackupExclusionManager:
    HeroImageBackupExclusionManaging,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var results: [Bool]

    init(results: [Bool]) {
        self.results = results
    }

    func setExcludedFromBackup(at _: URL) throws {}

    func isExcludedFromBackup(at _: URL) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !results.isEmpty else {
            throw BackupExclusionFixtureError.unexpectedVerification
        }
        return results.removeFirst()
    }
}

private enum RemovalFixtureError: Error, Equatable {
    case injectedFailure
}

private enum PromotionFixtureError: Error, Equatable {
    case injectedFailure
}

private final class FirstPromotionFailingPromoter: HeroImageAtomicPromoting, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func promote(stagingURL: URL, to finalURL: URL) throws {
        lock.lock()
        let fail = shouldFail
        shouldFail = false
        lock.unlock()
        if fail {
            throw PromotionFixtureError.injectedFailure
        }
        try SystemHeroImageAtomicPromoter().promote(
            stagingURL: stagingURL,
            to: finalURL
        )
    }
}

private final class PrefixRemovalFailingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private let failingPrefix: String
    private var remainingFailures: Int

    init(failingPrefix: String, failureCount: Int) {
        self.failingPrefix = failingPrefix
        remainingFailures = failureCount
        super.init()
    }

    override func removeItem(at url: URL) throws {
        lock.lock()
        let shouldFail = remainingFailures > 0
            && url.lastPathComponent.hasPrefix(failingPrefix)
        if shouldFail {
            remainingFailures -= 1
        }
        lock.unlock()
        if shouldFail {
            throw RemovalFixtureError.injectedFailure
        }
        try super.removeItem(at: url)
    }
}

private func assertSuperseded(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected operationSuperseded", file: file, line: line)
    } catch {
        XCTAssertEqual(
            error as? GeneratedHeroImageStoreError,
            .operationSuperseded,
            file: file,
            line: line
        )
    }
}

private func pathExists(_ url: URL) -> Bool {
    do {
        _ = try FileManager.default.attributesOfItem(atPath: url.path)
        return true
    } catch {
        return false
    }
}

private func directoryEntriesIfPresent(_ directory: URL) throws -> [String] {
    do {
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    } catch let error as NSError
        where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
        return []
    }
}

private func onlyStagingFile(in directory: URL) throws -> URL? {
    let root = directory.appendingPathComponent(".hero-staging", isDirectory: true)
    let launchDirectories: [URL]
    do {
        launchDirectories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
    } catch let error as NSError
        where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
        return nil
    }
    let files = try launchDirectories.flatMap {
        try FileManager.default.contentsOfDirectory(
            at: $0,
            includingPropertiesForKeys: nil
        )
    }
    return files.count == 1 ? files[0] : nil
}

@discardableResult
private func createOrphanStagingFile(
    in directory: URL,
    target: String,
    data: Data
) throws -> URL {
    let launchURL = directory
        .appendingPathComponent(".hero-staging", isDirectory: true)
        .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: launchURL, withIntermediateDirectories: true)
    let url = launchURL.appendingPathComponent(
        "\(target)-\(UUID().uuidString.lowercased()).png"
    )
    try data.write(to: url, options: [.atomic, .completeFileProtection])
    return url
}

private func temporaryStoreDirectory(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("watchlearn-hero-\(label)-\(UUID().uuidString)")
}

private func testHeroPNG(color: UIColor) -> Data? {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
    return renderer.pngData { context in
        context.cgContext.setFillColor(color.cgColor)
        context.cgContext.fill(CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
    }
}
