import Foundation
import Observation

public struct JourneyAttempt: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let level: TimeLearningLevel
    public let target: ClockTime
    public let answer: ClockTime
    public let correct: Bool
}

public struct ChildJourney: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var progress: LearningProgress
    public var attempts: [JourneyAttempt]
    public var masteredLevels: Set<TimeLearningLevel>? = []
    public var hasStartedVoiceLearning: Bool? = false

    var voiceLearningContext: ClockLearnerContext {
        let recent = attempts.suffix(5)
        return .init(needsIntroduction: hasStartedVoiceLearning != true,
                     totalAttempts: progress.totalAttempts,
                     recentAttempts: recent.count, recentCorrect: recent.filter(\.correct).count)
    }
}

/// Child names and answer history remain on this device. One atomic snapshot
/// keeps profile selection, progress and the latest 500 attempts together.
@MainActor @Observable
public final class ChildJourneyStore {
    public static let storageKey = "watchlearn.child-journeys.v1"
    private struct Snapshot: Codable {
        var children: [ChildJourney]
        var selectedID: UUID
    }
    private let defaults: UserDefaults?
    public private(set) var children: [ChildJourney]
    public private(set) var selectedID: UUID
    public var selected: ChildJourney { children.first { $0.id == selectedID } ?? children[0] }

    public init(defaults: UserDefaults? = .standard, initialProgress: LearningProgress? = nil,
                defaultName: String = "ZeitHeld") {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data),
           !saved.children.isEmpty, Set(saved.children.map(\.id)).count == saved.children.count {
            children = saved.children
            selectedID = saved.children.contains { $0.id == saved.selectedID }
                ? saved.selectedID : saved.children[0].id
        } else {
            let child = ChildJourney(id: UUID(), name: defaultName,
                progress: initialProgress ?? LearningProgress(), attempts: [])
            children = [child]; selectedID = child.id
        }
        persist()
    }

    @discardableResult public func add(name: String) -> UUID? {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        guard !clean.isEmpty, children.count < 12 else { return nil }
        let child = ChildJourney(id: UUID(), name: clean, progress: LearningProgress(), attempts: [])
        children.append(child); selectedID = child.id; persist()
        return child.id
    }

    public func select(_ id: UUID) {
        guard children.contains(where: { $0.id == id }) else { return }
        selectedID = id; persist()
    }

    public func renameSelected(_ name: String) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        guard !clean.isEmpty, let index = children.firstIndex(where: { $0.id == selectedID }) else { return }
        children[index].name = clean; persist()
    }

    public func save(progress: LearningProgress, attempt: JourneyAttempt? = nil, masteredLevel: TimeLearningLevel? = nil) {
        guard let index = children.firstIndex(where: { $0.id == selectedID }) else { return }
        children[index].progress = progress
        if let masteredLevel {
            var completed = children[index].masteredLevels ?? []
            completed.insert(masteredLevel)
            children[index].masteredLevels = completed
        }
        if let attempt {
            children[index].attempts.append(attempt)
            children[index].attempts = Array(children[index].attempts.suffix(500))
        }
        persist()
    }

    public func resetSelected() {
        guard let index = children.firstIndex(where: { $0.id == selectedID }) else { return }
        children[index].progress = LearningProgress()
        children[index].attempts = []
        children[index].masteredLevels = []
        children[index].hasStartedVoiceLearning = false
        persist()
    }

    public func markVoiceLearningStarted() {
        guard let index = children.firstIndex(where: { $0.id == selectedID }) else { return }
        children[index].hasStartedVoiceLearning = true
        persist()
    }

    private func persist() {
        guard let defaults,
              let data = try? JSONEncoder().encode(Snapshot(children: children, selectedID: selectedID)) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
