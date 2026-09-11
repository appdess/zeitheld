import SwiftUI

/// A real-time companion clock. Lessons use fixed `ClockTime` values, while this view
/// can be shown on a home or free-play screen to connect learning to the current time.
public struct LiveAnalogClockView: View {
    public let theme: HeroTheme
    public let language: LearningLanguage

    public init(
        theme: HeroTheme = .skyGuardian,
        language: LearningLanguage = .german
    ) {
        self.theme = theme
        self.language = language
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let components = Calendar.autoupdatingCurrent.dateComponents(
                [.hour, .minute],
                from: context.date
            )
            let time = ClockTime(
                hour: components.hour ?? 12,
                minute: components.minute ?? 0
            )

            VStack(spacing: WatchLearnSpacing.small) {
                AnalogClockView(time: time, theme: theme, language: language)
                Text(time.digitalText(language: language, includesSuffix: language == .german))
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(theme.palette.ink)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(LearningCopy.text(.liveClock, language: language))
        }
    }
}
