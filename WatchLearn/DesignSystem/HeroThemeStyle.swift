import SwiftUI

public struct HeroPalette {
    public let primary: Color
    public let secondary: Color
    public let background: Color
    public let ink: Color

    public init(primary: Color, secondary: Color, background: Color, ink: Color) {
        self.primary = primary
        self.secondary = secondary
        self.background = background
        self.ink = ink
    }
}

public extension HeroTheme {
    var palette: HeroPalette {
        switch self {
        case .skyGuardian:
            HeroPalette(
                primary: Color(red: 0.14, green: 0.45, blue: 0.92),
                secondary: Color(red: 0.98, green: 0.72, blue: 0.18),
                background: Color(red: 0.88, green: 0.95, blue: 1),
                ink: Color(red: 0.06, green: 0.16, blue: 0.32)
            )
        case .oceanExplorer:
            HeroPalette(
                primary: Color(red: 0.03, green: 0.56, blue: 0.68),
                secondary: Color(red: 1, green: 0.47, blue: 0.38),
                background: Color(red: 0.86, green: 0.98, blue: 0.97),
                ink: Color(red: 0.03, green: 0.21, blue: 0.29)
            )
        case .starInventor:
            HeroPalette(
                primary: Color(red: 0.47, green: 0.25, blue: 0.85),
                secondary: Color(red: 1, green: 0.68, blue: 0.18),
                background: Color(red: 0.95, green: 0.91, blue: 1),
                ink: Color(red: 0.18, green: 0.08, blue: 0.35)
            )
        case .emberRider:
            HeroPalette(
                primary: Color(red: 0.82, green: 0.20, blue: 0.10),
                secondary: Color(red: 1, green: 0.72, blue: 0.16),
                background: Color(red: 1, green: 0.92, blue: 0.84),
                ink: Color(red: 0.30, green: 0.08, blue: 0.04)
            )
        }
    }

    var fallbackSymbolName: String {
        switch self {
        case .skyGuardian: "bird.fill"
        case .oceanExplorer: "water.waves"
        case .starInventor: "sparkles"
        case .emberRider: "flame.fill"
        }
    }
}
