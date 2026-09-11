import Foundation
import XCTest
@testable import WatchLearn

final class HeroTemporaryAudioCleanupTests: XCTestCase {
    @MainActor
    func testStaleSweepDeletesOnlyOwnedUUIDRecordings() throws {
        let directory = FileManager.default.temporaryDirectory
        let owned = directory.appendingPathComponent(
            "watchlearn-hero-\(UUID().uuidString).m4a"
        )
        let lookalike = directory.appendingPathComponent("watchlearn-hero-not-a-uuid.m4a")
        let unrelated = directory.appendingPathComponent("another-app-\(UUID().uuidString).m4a")
        try Data([0x01]).write(to: owned)
        try Data([0x02]).write(to: lookalike)
        try Data([0x03]).write(to: unrelated)
        defer {
            try? FileManager.default.removeItem(at: owned)
            try? FileManager.default.removeItem(at: lookalike)
            try? FileManager.default.removeItem(at: unrelated)
        }

        HeroDescriptionRecorder.purgeStaleTemporaryRecordings()

        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lookalike.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @MainActor
    func testScopedRemovalRejectsUnownedPath() throws {
        let unrelated = FileManager.default.temporaryDirectory
            .appendingPathComponent("unrelated.m4a")
        try Data([0x01]).write(to: unrelated)
        defer { try? FileManager.default.removeItem(at: unrelated) }

        XCTAssertThrowsError(
            try HeroDescriptionRecorder.removeTemporaryRecording(at: unrelated)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
