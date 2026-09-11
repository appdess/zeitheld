import XCTest
import AVFoundation
@testable import WatchLearn

@MainActor
final class HeroRecorderIntegrationTests: XCTestCase {
    func testRealRecorderStartsAndProducesAReadableClip() async throws {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw XCTSkip("Grant microphone access to the test app before the real recorder check")
        }
        let recorder = HeroDescriptionRecorder()
        let clip = try await recorder.recordClip(maxDuration: 3)
        defer { try? HeroDescriptionRecorder.removeTemporaryRecording(at: clip) }
        XCTAssertFalse(recorder.isRecording)
        let file = try AVAudioFile(forReading: clip)
        XCTAssertGreaterThan(file.length, 0)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
    }
}
