import SwiftUI

/// A scalable teaching clock. The face is drawn entirely with SwiftUI so it remains
/// crisp at every device size and supports all Dynamic Type settings.
public struct AnalogClockView: View {
    public let time: ClockTime
    public let theme: HeroTheme
    public let language: LearningLanguage
    public let showsMinuteTicks: Bool

    public init(
        time: ClockTime,
        theme: HeroTheme = .skyGuardian,
        language: LearningLanguage = .german,
        showsMinuteTicks: Bool = true
    ) {
        self.time = time
        self.theme = theme
        self.language = language
        self.showsMinuteTicks = showsMinuteTicks
    }

    public var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = side * 0.46
            let palette = theme.palette

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white, palette.background],
                            center: .center,
                            startRadius: 0,
                            endRadius: radius
                        )
                    )
                    .frame(width: side * 0.96, height: side * 0.96)
                    .shadow(color: palette.ink.opacity(0.14), radius: side * 0.035, y: side * 0.02)

                Circle()
                    .stroke(palette.primary, lineWidth: max(side * 0.025, 4))
                    .frame(width: side * 0.92, height: side * 0.92)

                if showsMinuteTicks {
                    minuteTicks(side: side, radius: radius, color: palette.ink)
                }

                hourNumbers(center: center, radius: radius * 0.76, color: palette.ink, side: side)

                ClockHandShape(
                    degrees: time.hourHandDegrees,
                    length: radius * 0.50
                )
                .stroke(
                    palette.ink,
                    style: StrokeStyle(lineWidth: max(side * 0.034, 7), lineCap: .round)
                )

                ClockHandShape(
                    degrees: time.minuteHandDegrees,
                    length: radius * 0.72
                )
                .stroke(
                    palette.primary,
                    style: StrokeStyle(lineWidth: max(side * 0.022, 5), lineCap: .round)
                )

                Circle()
                    .fill(palette.secondary)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .frame(width: side * 0.075, height: side * 0.075)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LearningCopy.text(.questionPrompt, language: language))
        .accessibilityValue(teachingDescription)
    }

    private var teachingDescription: String {
        let hour = time.hour == 0 ? 12 : time.hour
        let minuteNumber = time.minute == 0 ? 12 : time.minute / 5
        let nextHour = hour == 12 ? 1 : hour + 1

        return switch (language, time.minute) {
        case (.german, 0):
            "Der lange Zeiger zeigt auf 12. Der kurze Zeiger zeigt auf \(hour)."
        case (.english, 0):
            "The long hand points to 12. The short hand points to \(hour)."
        case (.german, _):
            "Der lange Zeiger zeigt auf \(minuteNumber). Der kurze Zeiger steht zwischen \(hour) und \(nextHour)."
        case (.english, _):
            "The long hand points to \(minuteNumber). The short hand is between \(hour) and \(nextHour)."
        }
    }

    @ViewBuilder
    private func minuteTicks(side: CGFloat, radius: CGFloat, color: Color) -> some View {
        ForEach(0..<60, id: \.self) { minute in
            let isHour = minute.isMultiple(of: 5)
            Capsule()
                .fill(color.opacity(isHour ? 0.78 : 0.30))
                .frame(
                    width: isHour ? max(side * 0.014, 3) : max(side * 0.006, 1.5),
                    height: isHour ? side * 0.055 : side * 0.025
                )
                .offset(y: -radius * 0.91)
                .rotationEffect(.degrees(Double(minute) * 6))
        }
    }

    @ViewBuilder
    private func hourNumbers(center: CGPoint, radius: CGFloat, color: Color, side: CGFloat) -> some View {
        ForEach(1...12, id: \.self) { hour in
            let angle = Double(hour) * .pi / 6 - .pi / 2
            Text("\(hour)")
                .font(.system(size: side * 0.088, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
                .minimumScaleFactor(0.7)
                .position(
                    x: center.x + CGFloat(cos(angle)) * radius,
                    y: center.y + CGFloat(sin(angle)) * radius
                )
        }
    }
}

private struct ClockHandShape: Shape {
    let degrees: Double
    let length: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radians = degrees * .pi / 180 - .pi / 2
        let endpoint = CGPoint(
            x: center.x + CGFloat(cos(radians)) * length,
            y: center.y + CGFloat(sin(radians)) * length
        )

        var path = Path()
        path.move(to: center)
        path.addLine(to: endpoint)
        return path
    }
}
