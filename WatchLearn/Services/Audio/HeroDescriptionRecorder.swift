import AVFoundation
import Foundation
import Observation

enum HeroDescriptionRecorderError: LocalizedError, Equatable, Sendable {
    case permissionDenied
    case alreadyRecording
    case couldNotStart
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Microphone access is off. A parent can enable it in iOS Settings."
        case .alreadyRecording:
            "A hero description is already being recorded."
        case .couldNotStart:
            "The microphone could not start."
        case .encodingFailed:
            "The hero description could not be recorded."
        }
    }
}

@MainActor
protocol HeroDescriptionRecording: AnyObject {
    var isRecording: Bool { get }
    var audioLevel: Double { get }
    var elapsedSeconds: TimeInterval { get }
    func recordClip(maxDuration: TimeInterval) async throws -> URL
    func stopRecording()
    func cancelRecording()
}

extension HeroDescriptionRecording {
    var audioLevel: Double { 0 }
    var elapsedSeconds: TimeInterval { 0 }
}

@MainActor
@Observable
final class HeroDescriptionRecorder: NSObject, AVAudioRecorderDelegate, HeroDescriptionRecording {
    private let permissionService: any MicrophonePermissionProviding
    private let audioSession: AVAudioSession
    private let fileManager: FileManager
    private var recorder: AVAudioRecorder?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var recordingURL: URL?

    private(set) var isRecording = false
    private(set) var maximumDuration: TimeInterval = 15

    var elapsedSeconds: TimeInterval { recorder?.currentTime ?? 0 }
    var audioLevel: Double {
        guard isRecording, let recorder else { return 0 }
        recorder.updateMeters()
        // A real input meter: silence remains empty, louder speech fills it.
        return min(1, max(0, (Double(recorder.averagePower(forChannel: 0)) + 55) / 55))
    }

    init(
        permissionService: any MicrophonePermissionProviding = SystemMicrophonePermissionService(),
        audioSession: AVAudioSession = .sharedInstance(),
        fileManager: FileManager = .default
    ) {
        self.permissionService = permissionService
        self.audioSession = audioSession
        self.fileManager = fileManager
        super.init()
        Self.purgeStaleTemporaryRecordings(fileManager: fileManager)
    }

    func recordClip(maxDuration: TimeInterval = 15) async throws -> URL {
        guard !isRecording, continuation == nil else {
            throw HeroDescriptionRecorderError.alreadyRecording
        }
        guard await microphoneIsAvailable() else {
            throw HeroDescriptionRecorderError.permissionDenied
        }
        try Task.checkCancellation()

        self.maximumDuration = min(max(maxDuration, 3), 20)
        let fileURL = fileManager.temporaryDirectory
            .appendingPathComponent("watchlearn-hero-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        do {
            // spokenAudio is a playback mode and is not valid for record-only
            // sessions. Use the recording category's supported default mode.
            try audioSession.setCategory(.record, mode: .default, options: [])
            try audioSession.setActive(true)
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord() else {
                try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                throw HeroDescriptionRecorderError.couldNotStart
            }
            try Self.protectTemporaryRecording(at: fileURL, fileManager: fileManager)
            guard recorder.record(forDuration: self.maximumDuration) else {
                try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                throw HeroDescriptionRecorderError.couldNotStart
            }
            self.recorder = recorder
            recordingURL = fileURL
            isRecording = true
        } catch let error as HeroDescriptionRecorderError {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            try? Self.removeTemporaryRecording(at: fileURL, fileManager: fileManager)
            throw error
        } catch {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            try? Self.removeTemporaryRecording(at: fileURL, fileManager: fileManager)
            throw HeroDescriptionRecorderError.couldNotStart
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRecording()
            }
        }
    }

    /// Calling stop is safe while `recordClip` is suspended; the original call
    /// resumes with the finished temporary file and can immediately transcribe it.
    func stopRecording() {
        guard isRecording else { return }
        recorder?.stop()
    }

    func cancelRecording() {
        guard isRecording || continuation != nil else { return }
        recorder?.stop()
        let pending = continuation
        continuation = nil
        cleanupAudioState(deleteTemporaryFile: true)
        pending?.resume(throwing: CancellationError())
    }

    nonisolated func audioRecorderDidFinishRecording(
        _: AVAudioRecorder,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.finishRecording(successfully: flag)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(
        _: AVAudioRecorder,
        error _: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            self?.finishRecording(successfully: false)
        }
    }

    private func microphoneIsAvailable() async -> Bool {
        switch permissionService.currentPermission() {
        case .granted:
            true
        case .denied:
            false
        case .undetermined:
            await permissionService.requestPermission()
        }
    }

    private func finishRecording(successfully: Bool) {
        guard let pending = continuation else {
            cleanupAudioState(deleteTemporaryFile: !successfully)
            return
        }
        continuation = nil
        let url = recordingURL
        cleanupAudioState(deleteTemporaryFile: !successfully)

        if successfully, let url {
            pending.resume(returning: url)
        } else {
            pending.resume(throwing: HeroDescriptionRecorderError.encodingFailed)
        }
    }

    private func cleanupAudioState(deleteTemporaryFile: Bool) {
        let url = recordingURL
        recorder?.delegate = nil
        recorder = nil
        recordingURL = nil
        isRecording = false
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        if deleteTemporaryFile, let url {
            try? Self.removeTemporaryRecording(at: url, fileManager: fileManager)
        }
    }

    /// Removes only files created by this recorder. Exact prefix/suffix and a
    /// UUID filename are required so cleanup can never expand beyond its scope.
    static func removeTemporaryRecording(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        let canonicalURL = url.standardizedFileURL
        let temporaryDirectory = fileManager.temporaryDirectory.standardizedFileURL
        guard canonicalURL.deletingLastPathComponent() == temporaryDirectory,
              isOwnedTemporaryRecordingName(canonicalURL.lastPathComponent) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard fileManager.fileExists(atPath: canonicalURL.path) else { return }
        try fileManager.removeItem(at: canonicalURL)
    }

    static func purgeStaleTemporaryRecordings(fileManager: FileManager = .default) {
        let directory = fileManager.temporaryDirectory
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in urls where isOwnedTemporaryRecordingName(url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private static func protectTemporaryRecording(
        at url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private static func isOwnedTemporaryRecordingName(_ name: String) -> Bool {
        let prefix = "watchlearn-hero-"
        let suffix = ".m4a"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        return UUID(uuidString: String(name[start..<end])) != nil
    }
}
