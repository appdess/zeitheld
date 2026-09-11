import SwiftUI

public enum WatchLearnSpacing {
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 16
    public static let large: CGFloat = 24
    public static let cornerRadius: CGFloat = 24
    public static let minimumTapHeight: CGFloat = 54
}

public struct KidCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(WatchLearnSpacing.medium)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: WatchLearnSpacing.cornerRadius)
            )
            .background(
                Color.white.opacity(0.18),
                in: RoundedRectangle(cornerRadius: WatchLearnSpacing.cornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: WatchLearnSpacing.cornerRadius)
                    .stroke(.white.opacity(0.82), lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
    }
}

public struct HeroButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public let color: Color
    public let isProminent: Bool
    public let horizontalPadding: CGFloat

    public init(
        color: Color,
        isProminent: Bool = true,
        horizontalPadding: CGFloat = WatchLearnSpacing.medium
    ) {
        self.color = color
        self.isProminent = isProminent
        self.horizontalPadding = horizontalPadding
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(isProminent ? Color.white : color)
            .frame(maxWidth: .infinity, minHeight: WatchLearnSpacing.minimumTapHeight)
            .padding(.horizontal, horizontalPadding)
            .background {
                RoundedRectangle(cornerRadius: 18)
                    .fill(isProminent ? color : color.opacity(0.12))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(color.opacity(isProminent ? 0 : 0.35), lineWidth: 2)
            }
            .saturation(isEnabled ? 1 : 0.25)
            .opacity(isEnabled ? 1 : 0.48)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

public struct MasteryProgressView: View {
    public let progress: Double
    public let color: Color
    public let accessibilityLabel: String

    public init(progress: Double, color: Color, accessibilityLabel: String) {
        self.progress = progress
        self.color = color
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.16))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: geometry.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
    }
}
