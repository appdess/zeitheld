import SwiftUI

struct VoiceCoachStatusBar: View {
    @Bindable var coordinator: VoiceCoachCoordinator
    let language: InterfaceLanguage

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(indicatorColor.opacity(0.18))
                    .frame(width: 48, height: 48)
                Image(systemName: indicatorIcon)
                    .font(.title2.bold())
                    .foregroundStyle(indicatorColor)
                    .symbolEffect(.pulse, isActive: isAnimated)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .accessibilityValue(accessibilityTranscript)
                if !statusDetail.isEmpty {
                    Text(statusDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button(role: .destructive) {
                coordinator.stopLocalAudioImmediately()
                Task { await coordinator.stop() }
            } label: {
                Image(systemName: "stop.fill")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityLabel(copy(
                de: "Zeithelden stoppen",
                en: "Stop talking to Time Hero"
            ))
            .accessibilityIdentifier("voice-stop-button")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.ultraThickMaterial)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-coach-status-bar")
    }

    private var indicatorIcon: String {
        switch coordinator.phase {
        case .requestingPermission, .connecting: "ellipsis"
        case .listening: "ear.fill"
        case .childSpeaking: "mic.fill"
        case .coachSpeaking: "waveform"
        case .failed: "exclamationmark.triangle.fill"
        case .idle: "waveform"
        }
    }

    private var indicatorColor: Color {
        switch coordinator.phase {
        case .failed: .orange
        case .childSpeaking: .red
        case .coachSpeaking: .indigo
        default: .green
        }
    }

    private var isAnimated: Bool {
        switch coordinator.phase {
        case .connecting, .listening, .childSpeaking, .coachSpeaking: true
        default: false
        }
    }

    private var statusTitle: String {
        switch coordinator.phase {
        case .requestingPermission:
            copy(de: "Mikrofon-Freigabe", en: "Microphone permission")
        case .connecting:
            copy(de: "Verbindung zu deinem Zeithelden …", en: "Connecting to your Time Hero…")
        case .listening:
            copy(de: "Du bist dran – ich höre zu", en: "Your turn — I’m listening")
        case .childSpeaking:
            copy(de: "Ich kann dich hören", en: "I can hear you")
        case .coachSpeaking:
            copy(de: "Dein Zeitheld spricht", en: "Time Hero is speaking")
        case let .failed(message): message
        case .idle: ""
        }
    }

    private var statusDetail: String {
        switch coordinator.phase {
        case .childSpeaking:
            coordinator.childTranscript
        case .coachSpeaking:
            ""
        case .failed:
            copy(de: "Tippe auf Stopp und versuche es noch einmal.", en: "Tap stop, then try again.")
        default:
            copy(
                de: "Der rote Stopp-Knopf schaltet das Mikrofon immer aus.",
                en: "The red stop button always turns the microphone off."
            )
        }
    }

    private var accessibilityTranscript: String {
        switch coordinator.phase {
        case .childSpeaking:
            coordinator.childTranscript
        case .coachSpeaking:
            coordinator.coachTranscript
        default:
            ""
        }
    }

    private func copy(de: String, en: String) -> String {
        language == .german ? de : en
    }
}
