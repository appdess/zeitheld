import Foundation

enum ProjectLinks {
    // Enable only after these public destinations actually exist.
    static let hasPublishedRepository = true
    static let repository = URL(string: "https://github.com/appdess/zeitheld")!
    static let issueTracker = URL(string: "https://github.com/appdess/zeitheld/issues/new/choose")!
    static let privateSecurityReport = URL(string: "https://github.com/appdess/zeitheld/security/advisories/new")!
    static let privacyPolicy = URL(string: "https://github.com/appdess/zeitheld/blob/main/PRIVACY.md")!
}
