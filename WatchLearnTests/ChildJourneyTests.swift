import XCTest
@testable import WatchLearn

@MainActor
final class ChildJourneyTests: XCTestCase {
    func testVoiceIntroductionPersistsPerChildAndResetsWithJourney() throws {
        let name = "voice-introduction-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ChildJourneyStore(defaults: defaults)
        let firstID = store.selectedID
        XCTAssertTrue(store.selected.voiceLearningContext.needsIntroduction)
        store.markVoiceLearningStarted()
        XCTAssertFalse(store.selected.voiceLearningContext.needsIntroduction)
        store.add(name: "Second child")
        XCTAssertTrue(store.selected.voiceLearningContext.needsIntroduction)
        store.select(firstID)
        let restored = ChildJourneyStore(defaults: defaults)
        XCTAssertFalse(restored.selected.voiceLearningContext.needsIntroduction)
        restored.resetSelected()
        XCTAssertTrue(restored.selected.voiceLearningContext.needsIntroduction)
    }

    func testMigrationHistorySwitchAndResetAreIsolatedAndPersistent() throws {
        let name = "journey-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var legacy = LearningProgress(level: .quarterHour)
        legacy.totalCorrect = 2; legacy.totalAttempts = 3; legacy.totalStars = 5
        let store = ChildJourneyStore(defaults: defaults, initialProgress: legacy)
        let firstID = store.selectedID
        let model = LearningViewModel(journeys: store)
        XCTAssertEqual(model.progress.totalStars, 5)
        let target = model.question.time
        model.choose(ClockTime(hour: target.hour + 1, minute: target.minute))
        model.choose(target)
        model.choose(target) // A repeated tap cannot duplicate the success.
        XCTAssertEqual(store.selected.attempts.map(\.correct), [false, true])
        XCTAssertEqual(store.selected.attempts[0].target, target)
        XCTAssertEqual(store.selected.attempts[0].level, .quarterHour)
        let firstProgress = model.progress
        model.addChild(name: "  Sam  ")
        let secondID = store.selectedID
        XCTAssertEqual(store.selected.name, "Sam")
        XCTAssertEqual(model.progress.totalStars, 0)
        model.choose(model.question.time)
        XCTAssertEqual(model.progress.totalCorrect, 1)
        model.resetJourney()
        XCTAssertTrue(store.selected.attempts.isEmpty)
        XCTAssertEqual(model.progress.totalCorrect, 0)
        model.selectChild(firstID)
        XCTAssertEqual(model.progress, firstProgress)
        XCTAssertEqual(store.selected.attempts.count, 2)
        let restored = ChildJourneyStore(defaults: defaults, initialProgress: LearningProgress())
        XCTAssertEqual(restored.selectedID, firstID)
        XCTAssertEqual(restored.selected.progress, firstProgress)
        XCTAssertEqual(restored.children.first { $0.id == secondID }?.progress.totalCorrect, 0)
    }

    func testHistoryIsBoundedAndNamesValidated() {
        let store = ChildJourneyStore(defaults: nil)
        XCTAssertNil(store.add(name: " \n "))
        store.renameSelected(String(repeating: "a", count: 100))
        XCTAssertEqual(store.selected.name.count, 30)
        for minute in 0..<510 {
            store.save(progress: LearningProgress(), attempt: JourneyAttempt(id: UUID(), date: Date(),
                level: .anyMinute, target: ClockTime(hour: 1, minute: minute % 60),
                answer: ClockTime(hour: 2, minute: minute % 60), correct: false))
        }
        XCTAssertEqual(store.selected.attempts.count, 500)
        XCTAssertEqual(store.selected.attempts.first?.target.minute, 10)
    }

    func testDeviceLanguageUsesPrimaryLanguage() {
        XCTAssertEqual(ParentPreferences.deviceLanguage(preferredLanguages: ["de-DE", "en-US"]), .german)
        XCTAssertEqual(ParentPreferences.deviceLanguage(preferredLanguages: ["en-GB", "de-DE"]), .english)
        XCTAssertEqual(ParentPreferences.deviceLanguage(preferredLanguages: ["fr-FR"]), .english)
        XCTAssertEqual(ParentPreferences.deviceLanguage(preferredLanguages: []), .english)
    }
}
