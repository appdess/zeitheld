import Foundation

enum HeroSkinTone: String, CaseIterable, Codable, Identifiable, Sendable {
    case deep
    case warm
    case light

    var id: String { rawValue }

    func title(in language: LearningLanguage) -> String {
        switch (self, language) {
        case (.deep, .german): "Dunkle Haut"
        case (.deep, .english): "Deep skin tone"
        case (.warm, .german): "Warme Haut"
        case (.warm, .english): "Warm skin tone"
        case (.light, .german): "Helle Haut"
        case (.light, .english): "Light skin tone"
        }
    }

    var promptFragment: String {
        switch self {
        case .deep: "deep brown skin"
        case .warm: "warm medium-brown skin"
        case .light: "light skin"
        }
    }
}

enum HeroPower: String, CaseIterable, Codable, Identifiable, Sendable {
    case fireFlight
    case oceanDash
    case starGlow
    case stormBounce

    var id: String { rawValue }

    func title(in language: LearningLanguage) -> String {
        switch (self, language) {
        case (.fireFlight, .german): "Feuerflug"
        case (.fireFlight, .english): "Fire flight"
        case (.oceanDash, .german): "Wellen-Sprint"
        case (.oceanDash, .english): "Wave dash"
        case (.starGlow, .german): "Sternenlicht"
        case (.starGlow, .english): "Star glow"
        case (.stormBounce, .german): "Wolken-Sprung"
        case (.stormBounce, .english): "Cloud bounce"
        }
    }

    var systemImage: String {
        switch self {
        case .fireFlight: "flame.fill"
        case .oceanDash: "water.waves"
        case .starGlow: "sparkles"
        case .stormBounce: "cloud.bolt.rain.fill"
        }
    }

    var promptFragment: String {
        switch self {
        case .fireFlight: "soaring through safe glowing fire rings"
        case .oceanDash: "surfing a curling turquoise energy wave"
        case .starGlow: "leaping along trails of friendly cosmic starlight"
        case .stormBounce: "bouncing between soft electric storm clouds"
        }
    }
}

enum HeroGear: String, CaseIterable, Codable, Identifiable, Sendable {
    case windCape
    case rocketBoots
    case clockGauntlets
    case glowSuit

    var id: String { rawValue }

    func title(in language: LearningLanguage) -> String {
        switch (self, language) {
        case (.windCape, .german): "Wind-Umhang"
        case (.windCape, .english): "Wind cape"
        case (.rocketBoots, .german): "Raketenstiefel"
        case (.rocketBoots, .english): "Rocket boots"
        case (.clockGauntlets, .german): "Zeit-Handschuhe"
        case (.clockGauntlets, .english): "Time gloves"
        case (.glowSuit, .german): "Leuchtanzug"
        case (.glowSuit, .english): "Glow suit"
        }
    }

    var systemImage: String {
        switch self {
        case .windCape: "wind"
        case .rocketBoots: "shoe.2.fill"
        case .clockGauntlets: "clock.badge.checkmark.fill"
        case .glowSuit: "lightbulb.max.fill"
        }
    }

    var promptFragment: String {
        switch self {
        case .windCape: "an original short wind cape with no emblem"
        case .rocketBoots: "colorful rounded rocket boots with soft vapor trails"
        case .clockGauntlets: "friendly clock-themed gloves that are tools, never weapons"
        case .glowSuit: "an original glowing action suit with simple geometric panels"
        }
    }
}

enum HeroScene: String, CaseIterable, Codable, Identifiable, Sendable {
    case clockCity
    case fireSky
    case moonBridge
    case oceanCliffs

    var id: String { rawValue }

    func title(in language: LearningLanguage) -> String {
        switch (self, language) {
        case (.clockCity, .german): "Uhrenstadt"
        case (.clockCity, .english): "Clock city"
        case (.fireSky, .german): "Feuerhimmel"
        case (.fireSky, .english): "Fire sky"
        case (.moonBridge, .german): "Mondbrücke"
        case (.moonBridge, .english): "Moon bridge"
        case (.oceanCliffs, .german): "Meeresklippen"
        case (.oceanCliffs, .english): "Ocean cliffs"
        }
    }

    var systemImage: String {
        switch self {
        case .clockCity: "building.2.crop.circle.fill"
        case .fireSky: "sun.max.trianglebadge.exclamationmark.fill"
        case .moonBridge: "moon.stars.fill"
        case .oceanCliffs: "mountain.2.fill"
        }
    }

    var promptFragment: String {
        switch self {
        case .clockCity: "a fantastical clockwork city at golden hour"
        case .fireSky: "a dramatic orange sunset sky with safe magical fire arcs"
        case .moonBridge: "a luminous sky bridge beneath a big friendly moon"
        case .oceanCliffs: "bright ocean cliffs with spray and sweeping clouds"
        }
    }
}

struct HeroDesign: Codable, Equatable, Sendable {
    var skinTone: HeroSkinTone = .deep
    var power: HeroPower = .fireFlight
    var gear: HeroGear = .windCape
    var scene: HeroScene = .fireSky

    func childSummary(in language: LearningLanguage) -> String {
        switch language {
        case .german:
            "\(skinTone.title(in: language)), \(power.title(in: language)), \(gear.title(in: language)), \(scene.title(in: language))"
        case .english:
            "\(skinTone.title(in: language)), \(power.title(in: language)), \(gear.title(in: language)), \(scene.title(in: language))"
        }
    }
}
