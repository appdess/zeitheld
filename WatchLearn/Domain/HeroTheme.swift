import Foundation

/// Original, generic hero identities. They deliberately avoid names or visual traits
/// associated with existing entertainment properties.
public enum HeroTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case skyGuardian
    case oceanExplorer
    case starInventor
    case emberRider

    public var id: String { rawValue }

    /// Asset names are owned by the app's asset catalog. Keeping the mapping here
    /// lets callers provide a graceful symbol fallback when an asset is unavailable.
    public var assetName: String {
        switch self {
        case .skyGuardian: "HeroGearwing"
        case .oceanExplorer: "HeroCoral"
        case .starInventor: "HeroNova"
        case .emberRider: "HeroEmber"
        }
    }

    public func name(language: LearningLanguage) -> String {
        switch (self, language) {
        case (.skyGuardian, .german): "Himmelswächter"
        case (.skyGuardian, .english): "Sky Guardian"
        case (.oceanExplorer, .german): "Meeresforscher"
        case (.oceanExplorer, .english): "Ocean Explorer"
        case (.starInventor, .german): "Sternenerfinderin"
        case (.starInventor, .english): "Star Inventor"
        case (.emberRider, .german): "Glutreiter"
        case (.emberRider, .english): "Ember Rider"
        }
    }
}
