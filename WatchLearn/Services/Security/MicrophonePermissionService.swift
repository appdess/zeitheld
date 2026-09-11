import AVFoundation

enum MicrophonePermission: Sendable {
    case undetermined
    case denied
    case granted
}

protocol MicrophonePermissionProviding: Sendable {
    func currentPermission() -> MicrophonePermission
    func requestPermission() async -> Bool
}

struct SystemMicrophonePermissionService: MicrophonePermissionProviding {
    func currentPermission() -> MicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: .undetermined
        case .denied: .denied
        case .granted: .granted
        @unknown default: .denied
        }
    }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
