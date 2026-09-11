import Foundation
import UIKit
import XCTest
@testable import WatchLearn

final class HeroLifecycleTests: XCTestCase {
    @MainActor
    func testCancelVoiceDescriptionStopsRecordingAndReturnsToIdle() async {
        let recorder = FakeHeroDescriptionRecorder()
        let viewModel = HeroLabViewModel(
            imageGenerator: UnusedHeroImageGenerator(),
            transcriber: UnusedHeroTranscriber(),
            recorder: recorder,
            store: GeneratedHeroImageStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("unused-hero-lifecycle-\(UUID().uuidString)")
            ),
            usageBudget: UnlimitedHeroCloudUsageBudget()
        )

        let task = Task {
            await viewModel.toggleVoiceDescription(
                apiKey: "sk-fixture-never-real",
                language: .english
            )
        }
        for _ in 0..<20 where !recorder.isRecording {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.phase, .recording)
        XCTAssertTrue(recorder.isRecording)

        viewModel.cancelVoiceDescription()
        await task.value

        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(recorder.wasCancelled)
        XCTAssertEqual(viewModel.phase, .idle)
    }

    @MainActor
    func testExplicitCloudCancellationDoesNotSaveOrPublishAnImage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancelled-hero-generation-\(UUID().uuidString)")
        let store = GeneratedHeroImageStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let viewModel = HeroLabViewModel(
            imageGenerator: SlowHeroImageGenerator(),
            transcriber: UnusedHeroTranscriber(),
            recorder: FakeHeroDescriptionRecorder(),
            store: store,
            usageBudget: UnlimitedHeroCloudUsageBudget()
        )

        let task = viewModel.startGeneration(apiKey: "sk-fixture-never-real")
        for _ in 0..<30 where viewModel.phase != .generating {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.phase, .generating)

        viewModel.cancelCloudWork()
        await task.value

        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertNil(viewModel.latestImageData)
        let latestStoredImage = try await store.loadLatest()
        XCTAssertNil(latestStoredImage)
    }

    @MainActor
    func testViewDisappearanceLetsGenerationFinishAndPersist() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-hero-generation-\(UUID().uuidString)")
        let store = GeneratedHeroImageStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousImage = try XCTUnwrap(lifecycleHeroPNG(color: .systemBlue))
        _ = try await store.saveLatest(previousImage)
        let generator = GatedHeroImageGenerator()
        let viewModel = HeroLabViewModel(
            imageGenerator: generator,
            transcriber: UnusedHeroTranscriber(),
            recorder: FakeHeroDescriptionRecorder(),
            store: store,
            usageBudget: UnlimitedHeroCloudUsageBudget()
        )
        let expectedImage = try XCTUnwrap(lifecycleHeroPNG())
        await viewModel.loadSavedImages()
        XCTAssertEqual(viewModel.latestImageData, previousImage)

        let task = viewModel.startGeneration(apiKey: "sk-fixture-never-real")
        await generator.waitUntilStarted()
        XCTAssertEqual(viewModel.phase, .generating)

        // A view reappearance may ask for persisted images while generation
        // is in flight. That stale snapshot must not win over the completion.
        await viewModel.loadSavedImages()
        XCTAssertEqual(viewModel.latestImageData, previousImage)

        // Models the Hero Lab disappearing because the child changed tabs.
        viewModel.viewDidDisappear()
        XCTAssertEqual(viewModel.phase, .generating)

        await generator.succeed(with: expectedImage)
        await task.value

        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertEqual(viewModel.latestImageData, expectedImage)
        let persisted = try await store.loadLatest()
        XCTAssertEqual(persisted?.imageData, expectedImage)
    }

    @MainActor
    func testDeletionDuringCompletedGenerationCannotRecreateAnImage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deleted-hero-generation-\(UUID().uuidString)")
        let store = GeneratedHeroImageStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousImage = try XCTUnwrap(lifecycleHeroPNG(color: .systemBlue))
        let replacementImage = try XCTUnwrap(lifecycleHeroPNG(color: .systemOrange))
        _ = try await store.saveLatest(previousImage)
        let generator = GatedHeroImageGenerator()
        let viewModel = HeroLabViewModel(
            imageGenerator: generator,
            transcriber: UnusedHeroTranscriber(),
            recorder: FakeHeroDescriptionRecorder(),
            store: store,
            usageBudget: UnlimitedHeroCloudUsageBudget()
        )

        let task = viewModel.startGeneration(apiKey: "sk-fixture-never-real")
        await generator.waitUntilStarted()
        await generator.succeed(with: replacementImage)
        viewModel.cancelCloudWork()
        try await store.deleteAll()
        await task.value

        let reloaded = try await store.loadLatest()
        XCTAssertNil(reloaded)
        XCTAssertNil(viewModel.latestImageData)
    }

    @MainActor
    func testCancelledGenerationRetriesRollbackAfterTransientCleanupFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retry-generation-rollback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backupManager = LifecycleGatedBackupExclusionManager(steps: [
            .result(true),
            .gated(true),
            .result(true),
            .result(true),
            .result(true),
            .result(true),
        ])
        let fileManager = LifecycleRemovalFailingFileManager(
            failingLastPathComponent: "latest-",
            failureCount: 1
        )
        let store = GeneratedHeroImageStore(
            directory: directory,
            fileManager: fileManager,
            backupExclusionManager: backupManager
        )
        let previous = try XCTUnwrap(lifecycleHeroPNG(color: .systemBlue))
        let replacement = try XCTUnwrap(lifecycleHeroPNG(color: .systemOrange))
        _ = try await store.saveLatest(previous)
        let viewModel = HeroLabViewModel(
            imageGenerator: ImmediateHeroImageGenerator(imageData: replacement),
            transcriber: UnusedHeroTranscriber(),
            recorder: FakeHeroDescriptionRecorder(),
            store: store,
            usageBudget: UnlimitedHeroCloudUsageBudget()
        )

        let task = viewModel.startGeneration(apiKey: "sk-fixture-never-real")
        defer { backupManager.releaseGate() }
        try await waitUntilBackupGateIsReached(backupManager)
        viewModel.cancelCloudWork()
        backupManager.releaseGate()
        await task.value

        let persisted = try await store.loadLatest()
        XCTAssertEqual(persisted?.imageData, previous)
        XCTAssertNil(viewModel.issue)
    }

    @MainActor
    func testCancelledGenerationSurfacesPersistentStagingCleanupFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancelled-generation-cleanup-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backupManager = LifecycleGatedBackupExclusionManager(steps: [
            .result(true),
            .gated(true),
            .result(true),
            .result(true),
            .result(true),
            .result(true),
            .result(true),
            .result(true),
            .result(true),
        ])
        let store = GeneratedHeroImageStore(
            directory: directory,
            fileManager: LifecycleRemovalFailingFileManager(
                failingLastPathComponent: "latest-",
                failureCount: 4
            ),
            backupExclusionManager: backupManager
        )
        let previous = try XCTUnwrap(lifecycleHeroPNG(color: .systemBlue))
        let replacement = try XCTUnwrap(lifecycleHeroPNG(color: .systemOrange))
        _ = try await store.saveLatest(previous)
        let viewModel = HeroLabViewModel(
            imageGenerator: ImmediateHeroImageGenerator(imageData: replacement),
            transcriber: UnusedHeroTranscriber(),
            recorder: FakeHeroDescriptionRecorder(),
            store: store,
            usageBudget: UnlimitedHeroCloudUsageBudget()
        )
        await viewModel.loadSavedImages()

        let generation = viewModel.startGeneration(apiKey: "sk-fixture-never-real")
        defer { backupManager.releaseGate() }
        try await waitUntilBackupGateIsReached(backupManager)
        viewModel.cancelCloudWork()
        backupManager.releaseGate()
        await generation.value

        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertEqual(viewModel.issue, .localCleanupFailed)
        XCTAssertEqual(viewModel.latestImageData, previous)
        let persisted = try await store.loadLatest()
        XCTAssertEqual(persisted?.imageData, previous)
        let subpaths = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
        XCTAssertEqual(
            subpaths.filter {
                $0.hasPrefix(".hero-staging/")
                    && $0.split(separator: "/").last?.hasPrefix("latest-") == true
            }.count,
            1
        )
    }

    @MainActor
    func testCancelledSelectionRetriesRollbackAfterTransientCleanupFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retry-selection-rollback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backupManager = LifecycleGatedBackupExclusionManager(steps: [
            .result(true),
            .result(true),
            .result(true),
            .gated(true),
            .result(true),
            .result(true),
            .result(true),
            .result(true),
        ])
        let fileManager = LifecycleRemovalFailingFileManager(
            failingLastPathComponent: "selected-",
            failureCount: 1
        )
        let store = GeneratedHeroImageStore(
            directory: directory,
            fileManager: fileManager,
            backupExclusionManager: backupManager
        )
        let previous = try XCTUnwrap(lifecycleHeroPNG(color: .systemBlue))
        let replacement = try XCTUnwrap(lifecycleHeroPNG(color: .systemOrange))
        _ = try await store.saveLatest(previous)
        _ = try await store.selectLatestAsBackground()
        _ = try await store.saveLatest(replacement)
        let viewModel = HeroLabViewModel(
            imageGenerator: UnusedHeroImageGenerator(),
            transcriber: UnusedHeroTranscriber(),
            recorder: FakeHeroDescriptionRecorder(),
            store: store,
            usageBudget: UnlimitedHeroCloudUsageBudget()
        )
        await viewModel.loadSavedImages()

        let task = Task { @MainActor in
            await viewModel.selectLatestAsBackground()
        }
        defer { backupManager.releaseGate() }
        try await waitUntilBackupGateIsReached(backupManager)
        task.cancel()
        backupManager.releaseGate()
        let selected = await task.value

        XCTAssertNil(selected)
        let persisted = try await store.loadSelectedBackground()
        XCTAssertEqual(persisted?.imageData, previous)
        XCTAssertEqual(viewModel.selectedBackgroundData, previous)
        XCTAssertNil(viewModel.issue)
    }

    @MainActor
    func testAtomicCommitFailureDoesNotPublishCandidateOrReplaceCommittedImage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-generation-commit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GeneratedHeroImageStore(
            directory: directory,
            atomicPromoter: LifecycleFailingAtomicPromoter()
        )
        let previous = try XCTUnwrap(lifecycleHeroPNG(color: .systemBlue))
        let replacement = try XCTUnwrap(lifecycleHeroPNG(color: .systemOrange))
        _ = try await store.saveLatest(previous)
        let viewModel = HeroLabViewModel(
            imageGenerator: ImmediateHeroImageGenerator(imageData: replacement),
            transcriber: UnusedHeroTranscriber(),
            recorder: FakeHeroDescriptionRecorder(),
            store: store,
            usageBudget: UnlimitedHeroCloudUsageBudget()
        )
        await viewModel.loadSavedImages()
        XCTAssertEqual(viewModel.latestImageData, previous)

        let task = viewModel.startGeneration(apiKey: "sk-fixture-never-real")
        await task.value

        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertEqual(viewModel.issue, .localSaveFailed)
        XCTAssertEqual(viewModel.latestImageData, previous)
        let persisted = try await store.loadLatest()
        XCTAssertEqual(persisted?.imageData, previous)
    }

    @MainActor
    func testPersistentStagingCleanupFailureKeepsCleanupIssuePrecedence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-generation-cleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GeneratedHeroImageStore(
            directory: directory,
            fileManager: LifecycleRemovalFailingFileManager(
                failingLastPathComponent: "latest-",
                failureCount: 4
            ),
            atomicPromoter: LifecycleFailingAtomicPromoter()
        )
        let previous = try XCTUnwrap(lifecycleHeroPNG(color: .systemBlue))
        let replacement = try XCTUnwrap(lifecycleHeroPNG(color: .systemOrange))
        _ = try await store.saveLatest(previous)
        let viewModel = HeroLabViewModel(
            imageGenerator: ImmediateHeroImageGenerator(imageData: replacement),
            transcriber: UnusedHeroTranscriber(),
            recorder: FakeHeroDescriptionRecorder(),
            store: store,
            usageBudget: UnlimitedHeroCloudUsageBudget()
        )
        await viewModel.loadSavedImages()

        await viewModel.startGeneration(apiKey: "sk-fixture-never-real").value

        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertEqual(viewModel.issue, .localCleanupFailed)
        XCTAssertEqual(viewModel.latestImageData, previous)
        let persisted = try await store.loadLatest()
        XCTAssertEqual(persisted?.imageData, previous)
    }

    @MainActor
    func testCommitBackupFailureAndPersistentGenerationCleanupKeepResidualExcluded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("generation-backup-cleanup-defense-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backupManager = LifecycleTrackingBackupExclusionManager(
            directory: directory,
            failingDirectoryVerification: 3
        )
        let store = GeneratedHeroImageStore(
            directory: directory,
            fileManager: LifecycleRemovalFailingFileManager(
                failingLastPathComponent: "latest-",
                failureCount: 4
            ),
            backupExclusionManager: backupManager
        )
        let previous = try XCTUnwrap(lifecycleHeroPNG(color: .systemBlue))
        let replacement = try XCTUnwrap(lifecycleHeroPNG(color: .systemOrange))
        _ = try await store.saveLatest(previous)
        let viewModel = HeroLabViewModel(
            imageGenerator: ImmediateHeroImageGenerator(imageData: replacement),
            transcriber: UnusedHeroTranscriber(),
            recorder: FakeHeroDescriptionRecorder(),
            store: store,
            usageBudget: UnlimitedHeroCloudUsageBudget()
        )
        await viewModel.loadSavedImages()

        await viewModel.startGeneration(apiKey: "sk-fixture-never-real").value

        let stagingURL = try XCTUnwrap(
            try lifecycleOnlyStagingFile(in: directory, prefix: "latest-")
        )
        let stagingRootURL = directory.appendingPathComponent(
            ".hero-staging",
            isDirectory: true
        )
        XCTAssertTrue(backupManager.didInjectDirectoryFailure())
        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertEqual(viewModel.issue, .localCleanupFailed)
        XCTAssertEqual(viewModel.latestImageData, previous)
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("latest-generated.png")),
            previous
        )
        XCTAssertEqual(try Data(contentsOf: stagingURL), replacement)
        XCTAssertTrue(backupManager.wasSuccessfullyVerified(stagingRootURL))
        XCTAssertTrue(
            backupManager.wasSuccessfullyVerified(stagingURL.deletingLastPathComponent())
        )
        XCTAssertEqual(backupManager.successfulVerificationCount(for: stagingURL), 6)
        let persisted = try await store.loadLatest()
        XCTAssertEqual(persisted?.imageData, previous)
    }

    @MainActor
    func testCommitBackupFailureAndPersistentSelectionCleanupKeepResidualExcluded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-backup-cleanup-defense-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backupManager = LifecycleTrackingBackupExclusionManager(
            directory: directory,
            failingDirectoryVerification: 5
        )
        let store = GeneratedHeroImageStore(
            directory: directory,
            fileManager: LifecycleRemovalFailingFileManager(
                failingLastPathComponent: "selected-",
                failureCount: 4
            ),
            backupExclusionManager: backupManager
        )
        let previous = try XCTUnwrap(lifecycleHeroPNG(color: .systemBlue))
        let replacement = try XCTUnwrap(lifecycleHeroPNG(color: .systemOrange))
        _ = try await store.saveLatest(previous)
        _ = try await store.selectLatestAsBackground()
        _ = try await store.saveLatest(replacement)
        let viewModel = HeroLabViewModel(
            imageGenerator: UnusedHeroImageGenerator(),
            transcriber: UnusedHeroTranscriber(),
            recorder: FakeHeroDescriptionRecorder(),
            store: store,
            usageBudget: UnlimitedHeroCloudUsageBudget()
        )
        await viewModel.loadSavedImages()

        let selected = await viewModel.selectLatestAsBackground()

        let stagingURL = try XCTUnwrap(
            try lifecycleOnlyStagingFile(in: directory, prefix: "selected-")
        )
        let stagingRootURL = directory.appendingPathComponent(
            ".hero-staging",
            isDirectory: true
        )
        XCTAssertNil(selected)
        XCTAssertTrue(backupManager.didInjectDirectoryFailure())
        XCTAssertEqual(viewModel.issue, .localCleanupFailed)
        XCTAssertEqual(viewModel.selectedBackgroundData, previous)
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("selected-background.png")),
            previous
        )
        XCTAssertEqual(try Data(contentsOf: stagingURL), replacement)
        XCTAssertTrue(backupManager.wasSuccessfullyVerified(stagingRootURL))
        XCTAssertTrue(
            backupManager.wasSuccessfullyVerified(stagingURL.deletingLastPathComponent())
        )
        XCTAssertEqual(backupManager.successfulVerificationCount(for: stagingURL), 6)
        let persisted = try await store.loadSelectedBackground()
        XCTAssertEqual(persisted?.imageData, previous)
    }

    @MainActor
    func testDeleteAfterAtomicRenameCannotRepublishDeletedImage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("delete-after-rename-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let promoter = LifecyclePostRenameGatedAtomicPromoter()
        let store = GeneratedHeroImageStore(
            directory: directory,
            atomicPromoter: promoter
        )
        let previous = try XCTUnwrap(lifecycleHeroPNG(color: .systemBlue))
        let replacement = try XCTUnwrap(lifecycleHeroPNG(color: .systemOrange))
        _ = try await store.saveLatest(previous)
        let viewModel = HeroLabViewModel(
            imageGenerator: ImmediateHeroImageGenerator(imageData: replacement),
            transcriber: UnusedHeroTranscriber(),
            recorder: FakeHeroDescriptionRecorder(),
            store: store,
            usageBudget: UnlimitedHeroCloudUsageBudget()
        )
        await viewModel.loadSavedImages()
        let generation = viewModel.startGeneration(apiKey: "sk-fixture-never-real")
        defer { promoter.release() }
        try await waitUntilAtomicPromotionIsBlocked(promoter)

        viewModel.cancelCloudWork()
        let deletion = Task { try await store.deleteAll() }
        promoter.release()
        try await deletion.value
        await generation.value
        await viewModel.loadSavedImages()

        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertNil(viewModel.latestImageData)
        let persisted = try await store.loadLatest()
        XCTAssertNil(persisted)
    }
}

private func lifecycleHeroPNG(color: UIColor = .systemIndigo) -> Data? {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
    return renderer.pngData { context in
        context.cgContext.setFillColor(color.cgColor)
        context.cgContext.fill(CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
    }
}

private func lifecycleOnlyStagingFile(in directory: URL, prefix: String) throws -> URL? {
    let stagingRootURL = directory.appendingPathComponent(
        ".hero-staging",
        isDirectory: true
    )
    let launchDirectories = try FileManager.default.contentsOfDirectory(
        at: stagingRootURL,
        includingPropertiesForKeys: nil
    )
    let candidates = try launchDirectories.flatMap { launchURL in
        try FileManager.default.contentsOfDirectory(
            at: launchURL,
            includingPropertiesForKeys: nil
        )
    }.filter { $0.lastPathComponent.hasPrefix(prefix) }
    return candidates.count == 1 ? candidates[0] : nil
}

@MainActor
private final class FakeHeroDescriptionRecorder: HeroDescriptionRecording {
    var isRecording = false
    private(set) var wasCancelled = false
    private var continuation: CheckedContinuation<URL, any Error>?

    func recordClip(maxDuration _: TimeInterval) async throws -> URL {
        isRecording = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func stopRecording() {
        isRecording = false
    }

    func cancelRecording() {
        isRecording = false
        wasCancelled = true
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
    }
}

private struct UnusedHeroImageGenerator: HeroImageGenerating {
    func generate(
        design _: HeroDesign,
        description _: String,
        apiKey _: String
    ) async throws -> GeneratedHeroImage {
        throw CancellationError()
    }
}

private struct UnusedHeroTranscriber: HeroDescriptionTranscribing {
    func transcribe(
        fileURL _: URL,
        language _: LearningLanguage,
        apiKey _: String
    ) async throws -> String {
        throw CancellationError()
    }
}

private struct SlowHeroImageGenerator: HeroImageGenerating {
    func generate(
        design _: HeroDesign,
        description _: String,
        apiKey _: String
    ) async throws -> GeneratedHeroImage {
        try await Task.sleep(for: .seconds(30))
        return GeneratedHeroImage(imageData: Data([0x01, 0x02]), prompt: "unused")
    }
}

private struct ImmediateHeroImageGenerator: HeroImageGenerating {
    let imageData: Data

    func generate(
        design _: HeroDesign,
        description _: String,
        apiKey _: String
    ) async throws -> GeneratedHeroImage {
        GeneratedHeroImage(imageData: imageData, prompt: "fixture")
    }
}

private struct LifecycleFailingAtomicPromoter: HeroImageAtomicPromoting {
    func promote(stagingURL _: URL, to _: URL) throws {
        throw LifecycleFixtureError.injectedPromotionFailure
    }
}

private final class LifecyclePostRenameGatedAtomicPromoter:
    HeroImageAtomicPromoting,
    @unchecked Sendable
{
    private let condition = NSCondition()
    private var didPromote = false
    private var canReturn = false

    func promote(stagingURL: URL, to finalURL: URL) throws {
        try SystemHeroImageAtomicPromoter().promote(
            stagingURL: stagingURL,
            to: finalURL
        )
        condition.lock()
        didPromote = true
        condition.broadcast()
        while !canReturn {
            condition.wait()
        }
        condition.unlock()
    }

    func isBlockedAfterPromotion() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return didPromote && !canReturn
    }

    func release() {
        condition.lock()
        canReturn = true
        condition.broadcast()
        condition.unlock()
    }
}

private enum LifecycleBackupStep {
    case result(Bool)
    case gated(Bool)
}

private enum LifecycleFixtureError: Error {
    case unexpectedBackupVerification
    case injectedRemovalFailure
    case injectedPromotionFailure
}

private final class LifecycleGatedBackupExclusionManager:
    HeroImageBackupExclusionManaging,
    @unchecked Sendable
{
    private let condition = NSCondition()
    private var steps: [LifecycleBackupStep]
    private var gateReached = false
    private var gateOpen = false

    init(steps: [LifecycleBackupStep]) {
        self.steps = steps
    }

    func setExcludedFromBackup(at _: URL) throws {}

    func isExcludedFromBackup(at _: URL) throws -> Bool {
        condition.lock()
        guard !steps.isEmpty else {
            condition.unlock()
            throw LifecycleFixtureError.unexpectedBackupVerification
        }
        let step = steps.removeFirst()
        switch step {
        case let .result(result):
            condition.unlock()
            return result
        case let .gated(result):
            gateReached = true
            condition.broadcast()
            while !gateOpen {
                condition.wait()
            }
            gateOpen = false
            condition.unlock()
            return result
        }
    }

    func hasReachedGate() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return gateReached
    }

    func releaseGate() {
        condition.lock()
        gateOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class LifecycleTrackingBackupExclusionManager:
    HeroImageBackupExclusionManaging,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let directoryPath: String
    private let failingDirectoryVerification: Int
    private var directoryVerificationCount = 0
    private var markedPaths: Set<String> = []
    private var successfulVerificationCounts: [String: Int] = [:]
    private var injectedDirectoryFailure = false

    init(directory: URL, failingDirectoryVerification: Int) {
        directoryPath = directory.standardizedFileURL.path
        self.failingDirectoryVerification = failingDirectoryVerification
    }

    func setExcludedFromBackup(at url: URL) throws {
        lock.lock()
        markedPaths.insert(url.standardizedFileURL.path)
        lock.unlock()
    }

    func isExcludedFromBackup(at url: URL) throws -> Bool {
        let path = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if path == directoryPath {
            directoryVerificationCount += 1
            if directoryVerificationCount == failingDirectoryVerification {
                injectedDirectoryFailure = true
                return false
            }
        }
        guard markedPaths.contains(path) else { return false }
        successfulVerificationCounts[path, default: 0] += 1
        return true
    }

    func didInjectDirectoryFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return injectedDirectoryFailure
    }

    func wasSuccessfullyVerified(_ url: URL) -> Bool {
        successfulVerificationCount(for: url) > 0
    }

    func successfulVerificationCount(for url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return successfulVerificationCounts[url.standardizedFileURL.path, default: 0]
    }
}

private final class LifecycleRemovalFailingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private let failingLastPathComponent: String
    private var remainingFailures: Int

    init(failingLastPathComponent: String, failureCount: Int) {
        self.failingLastPathComponent = failingLastPathComponent
        remainingFailures = failureCount
        super.init()
    }

    override func removeItem(at url: URL) throws {
        lock.lock()
        let shouldFail = remainingFailures > 0
            && url.lastPathComponent.hasPrefix(failingLastPathComponent)
        if shouldFail {
            remainingFailures -= 1
        }
        lock.unlock()

        if shouldFail {
            throw LifecycleFixtureError.injectedRemovalFailure
        }
        try super.removeItem(at: url)
    }
}

@MainActor
private func waitUntilBackupGateIsReached(
    _ manager: LifecycleGatedBackupExclusionManager
) async throws {
    for _ in 0..<500 {
        if manager.hasReachedGate() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Timed out waiting for the deterministic backup-exclusion gate")
}

@MainActor
private func waitUntilAtomicPromotionIsBlocked(
    _ promoter: LifecyclePostRenameGatedAtomicPromoter
) async throws {
    for _ in 0..<500 {
        if promoter.isBlockedAfterPromotion() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    XCTFail("Timed out waiting for the post-rename commit gate")
}

private actor GatedHeroImageGenerator: HeroImageGenerating {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation: CheckedContinuation<GeneratedHeroImage, any Error>?

    func generate(
        design _: HeroDesign,
        description _: String,
        apiKey _: String
    ) async throws -> GeneratedHeroImage {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return try await withCheckedThrowingContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func succeed(with imageData: Data) {
        let continuation = resultContinuation
        resultContinuation = nil
        continuation?.resume(returning: GeneratedHeroImage(
            imageData: imageData,
            prompt: "fixture"
        ))
    }
}
