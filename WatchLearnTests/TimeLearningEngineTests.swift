import XCTest
@testable import WatchLearn

final class TimeLearningEngineTests: XCTestCase {
    func testJourneyRequiresFourActualHalfHoursBeforeQuarterHoursAcrossSeeds() throws {
        for seed in UInt64(0)..<100 {
            var engine = TimeLearningEngine(seed: seed)
            for _ in 0..<4 {
                XCTAssertEqual(engine.currentQuestion.level, .fullHour)
                _ = engine.submit(answer: engine.currentQuestion.time)
                XCTAssertTrue(engine.moveToNextQuestion())
            }
            for index in 0..<4 {
                XCTAssertEqual(engine.currentQuestion.level, .halfHour)
                XCTAssertEqual(engine.currentQuestion.time.minute, 30)
                let wrong = ClockTime(hour: engine.currentQuestion.time.hour, minute: 0)
                _ = engine.submit(answer: wrong)
                XCTAssertEqual(engine.progress.masteryCount, index)
                _ = engine.submit(answer: engine.currentQuestion.time)
                XCTAssertTrue(engine.moveToNextQuestion())
            }
            XCTAssertEqual(engine.currentQuestion.level, .quarterHour)
        }
    }

    func testDefaultLessonStartsInGermanFullHourEasyMode() {
        let engine = TimeLearningEngine()

        XCTAssertEqual(engine.language, .german)
        XCTAssertEqual(engine.progress.level, .fullHour)
        XCTAssertEqual(engine.currentQuestion.level, .fullHour)
        XCTAssertEqual(engine.currentQuestion.time.minute, 0)
        XCTAssertFalse(engine.isAwaitingNextQuestion)
    }

    func testEveryLevelOnlyGeneratesSupportedTimesAndPedagogicalChoices() throws {
        for level in TimeLearningLevel.allCases {
            var engine = TimeLearningEngine(
                language: .english,
                startingLevel: level,
                seed: UInt64(level.rawValue + 100),
                masteryThreshold: 1_000
            )

            for _ in 0..<80 {
                let question = engine.currentQuestion
                XCTAssertEqual(question.level, level)
                XCTAssertTrue(level.supports(question.time), "Unsupported time at \(level)")
                XCTAssertEqual(question.choices.count, 3)
                XCTAssertEqual(Set(question.choices).count, 3)
                XCTAssertEqual(question.choices.filter { $0 == question.time }.count, 1)
                XCTAssertTrue(
                    question.choices.allSatisfy(level.supports),
                    "A choice introduced minutes beyond \(level)"
                )

                let result = try XCTUnwrap(engine.submit(answer: question.time))
                XCTAssertTrue(result.isCorrect)
                XCTAssertTrue(engine.moveToNextQuestion())
            }
        }
    }

    func testSeedProducesIdenticalQuestionSequence() throws {
        var first = TimeLearningEngine(
            language: .german,
            startingLevel: .anyMinute,
            seed: 42,
            masteryThreshold: 100
        )
        var second = TimeLearningEngine(
            language: .english,
            startingLevel: .anyMinute,
            seed: 42,
            masteryThreshold: 100
        )

        for _ in 0..<20 {
            XCTAssertEqual(first.currentQuestion, second.currentQuestion)
            _ = try XCTUnwrap(first.submit(answer: first.currentQuestion.time))
            _ = try XCTUnwrap(second.submit(answer: second.currentQuestion.time))
            XCTAssertTrue(first.moveToNextQuestion())
            XCTAssertTrue(second.moveToNextQuestion())
        }
    }

    func testIncorrectAnswersRevealHintsInDeterministicOrder() throws {
        var engine = TimeLearningEngine(seed: 7)
        let wrongAnswer = try XCTUnwrap(
            engine.currentQuestion.choices.first { $0 != engine.currentQuestion.time }
        )

        let first = try XCTUnwrap(engine.submit(answer: wrongAnswer))
        XCTAssertFalse(first.isCorrect)
        XCTAssertEqual(first.hint?.focus, .hourHand)
        XCTAssertNil(first.reward)
        XCTAssertEqual(engine.progress.masteryCount, 0)

        let second = try XCTUnwrap(engine.submit(answer: wrongAnswer))
        XCTAssertEqual(second.hint?.focus, .minuteHand)

        let third = try XCTUnwrap(engine.submit(answer: wrongAnswer))
        XCTAssertEqual(third.hint?.focus, .spokenTime)

        let fourth = try XCTUnwrap(engine.submit(answer: wrongAnswer))
        XCTAssertEqual(fourth.hint?.focus, .spokenTime)
        XCTAssertEqual(engine.progress.totalAttempts, 4)
    }

    func testRewardsDecreaseAfterHelpButNeverPunish() throws {
        var firstTryEngine = TimeLearningEngine(seed: 11)
        let firstTry = try XCTUnwrap(
            firstTryEngine.submit(answer: firstTryEngine.currentQuestion.time)
        )
        XCTAssertEqual(firstTry.reward?.stars, 3)
        XCTAssertEqual(firstTryEngine.progress.totalStars, 3)

        var helpedEngine = TimeLearningEngine(seed: 11)
        let wrong = try XCTUnwrap(
            helpedEngine.currentQuestion.choices.first { $0 != helpedEngine.currentQuestion.time }
        )
        _ = helpedEngine.submit(answer: wrong)
        let afterOneHint = try XCTUnwrap(
            helpedEngine.submit(answer: helpedEngine.currentQuestion.time)
        )
        XCTAssertEqual(afterOneHint.reward?.stars, 2)

        var moreHelpEngine = TimeLearningEngine(seed: 11)
        let anotherWrong = try XCTUnwrap(
            moreHelpEngine.currentQuestion.choices.first { $0 != moreHelpEngine.currentQuestion.time }
        )
        _ = moreHelpEngine.submit(answer: anotherWrong)
        _ = moreHelpEngine.submit(answer: anotherWrong)
        let afterMoreHelp = try XCTUnwrap(
            moreHelpEngine.submit(answer: moreHelpEngine.currentQuestion.time)
        )
        XCTAssertEqual(afterMoreHelp.reward?.stars, 1)
        XCTAssertEqual(moreHelpEngine.progress.totalStars, 1)
    }

    func testCorrectAnswerCannotAwardTwiceAndQuestionRequiresSuccessToAdvance() throws {
        var engine = TimeLearningEngine(seed: 88)
        let originalQuestion = engine.currentQuestion

        XCTAssertFalse(engine.moveToNextQuestion())
        _ = try XCTUnwrap(engine.submit(answer: originalQuestion.time))
        XCTAssertNil(engine.submit(answer: originalQuestion.time))
        XCTAssertEqual(engine.progress.totalCorrect, 1)
        XCTAssertEqual(engine.progress.totalStars, 3)

        XCTAssertTrue(engine.moveToNextQuestion())
        XCTAssertNotEqual(engine.currentQuestion.id, originalQuestion.id)
        XCTAssertFalse(engine.isAwaitingNextQuestion)
    }

    func testMasteryUnlocksNextLevelAtExactThreshold() throws {
        var engine = TimeLearningEngine(
            startingLevel: .fullHour,
            seed: 91,
            masteryThreshold: 2
        )

        let first = try XCTUnwrap(engine.submit(answer: engine.currentQuestion.time))
        XCTAssertNil(first.unlockedLevel)
        XCTAssertEqual(engine.progress.masteryCount, 1)
        XCTAssertTrue(engine.moveToNextQuestion())

        let second = try XCTUnwrap(engine.submit(answer: engine.currentQuestion.time))
        XCTAssertEqual(second.unlockedLevel, .halfHour)
        XCTAssertEqual(second.reward?.kind, .levelBadge)
        XCTAssertEqual(engine.progress.level, .halfHour)
        XCTAssertEqual(engine.progress.masteryCount, 0)

        XCTAssertTrue(engine.moveToNextQuestion())
        XCTAssertEqual(engine.currentQuestion.level, .halfHour)
    }

    func testFinalLevelAwardsCurriculumBadgeOnce() throws {
        var engine = TimeLearningEngine(
            startingLevel: .anyMinute,
            seed: 123,
            masteryThreshold: 1
        )

        let completion = try XCTUnwrap(engine.submit(answer: engine.currentQuestion.time))
        XCTAssertTrue(completion.completedCurriculum)
        XCTAssertEqual(completion.reward?.kind, .clockChampionBadge)
        XCTAssertTrue(engine.progress.curriculumCompleted)

        XCTAssertTrue(engine.moveToNextQuestion())
        let laterSuccess = try XCTUnwrap(engine.submit(answer: engine.currentQuestion.time))
        XCTAssertFalse(laterSuccess.completedCurriculum)
        XCTAssertEqual(laterSuccess.reward?.kind, .starBurst)
    }

    func testParentLevelSelectionRetainsEarnedTotalsButResetsCurrentMastery() throws {
        var engine = TimeLearningEngine(masteryThreshold: 5)
        _ = try XCTUnwrap(engine.submit(answer: engine.currentQuestion.time))
        XCTAssertEqual(engine.progress.totalStars, 3)

        engine.start(level: .quarterHour)

        XCTAssertEqual(engine.progress.level, .quarterHour)
        XCTAssertEqual(engine.currentQuestion.level, .quarterHour)
        XCTAssertEqual(engine.progress.masteryCount, 0)
        XCTAssertEqual(engine.progress.currentStreak, 0)
        XCTAssertEqual(engine.progress.totalStars, 3)
        XCTAssertFalse(engine.isAwaitingNextQuestion)
    }

    func testClockTimeNormalizesAndCalculatesHandAngles() {
        XCTAssertEqual(ClockTime(hour: 12, minute: 60), ClockTime(hour: 1, minute: 0))
        XCTAssertEqual(ClockTime(hour: 1, minute: -60), ClockTime(hour: 12, minute: 0))
        XCTAssertEqual(ClockTime(hour: 0, minute: -1), ClockTime(hour: 11, minute: 59))

        let threeThirty = ClockTime(hour: 3, minute: 30)
        XCTAssertEqual(threeThirty.hourHandDegrees, 105, accuracy: 0.0001)
        XCTAssertEqual(threeThirty.minuteHandDegrees, 180, accuracy: 0.0001)
    }

    func testNaturalTimeSpeechInGermanAndEnglish() {
        XCTAssertEqual(ClockTime(hour: 1, minute: 0).spokenText(language: .german), "ein Uhr")
        XCTAssertEqual(ClockTime(hour: 1, minute: 0).spokenText(language: .english), "one o'clock")
        XCTAssertEqual(ClockTime(hour: 3, minute: 15).spokenText(language: .german), "Viertel nach drei")
        XCTAssertEqual(ClockTime(hour: 3, minute: 15).spokenText(language: .english), "quarter past three")
        XCTAssertEqual(ClockTime(hour: 3, minute: 30).spokenText(language: .german), "Halb vier")
        XCTAssertEqual(ClockTime(hour: 3, minute: 30).spokenText(language: .english), "half past three")
        XCTAssertEqual(ClockTime(hour: 3, minute: 45).spokenText(language: .german), "Viertel vor vier")
        XCTAssertEqual(ClockTime(hour: 3, minute: 45).spokenText(language: .english), "quarter to four")
        XCTAssertEqual(ClockTime(hour: 3, minute: 37).spokenText(language: .german), "dreiundzwanzig vor vier")
        XCTAssertEqual(ClockTime(hour: 3, minute: 37).spokenText(language: .english), "twenty-three to four")
    }

    func testEveryLocalizedKeyHasGermanAndEnglishCopy() {
        for key in LearningStringKey.allCases {
            let german = LearningCopy.text(key, language: .german)
            let english = LearningCopy.text(key, language: .english)

            XCTAssertFalse(german.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertNotEqual(german, english, "Key \(key) was not translated")
        }
    }

    func testEveryLevelAndHeroHasLocalizedNames() {
        for level in TimeLearningLevel.allCases {
            XCTAssertNotEqual(level.title(language: .german), level.title(language: .english))
            XCTAssertNotEqual(level.shortTitle(language: .german), level.shortTitle(language: .english))
        }

        XCTAssertEqual(Set(HeroTheme.allCases.map(\.assetName)).count, HeroTheme.allCases.count)
        for hero in HeroTheme.allCases {
            XCTAssertFalse(hero.name(language: .german).isEmpty)
            XCTAssertFalse(hero.name(language: .english).isEmpty)
            XCTAssertNotEqual(hero.name(language: .german), hero.name(language: .english))
        }
    }

    func testFeedbackAndHintsFollowSelectedLanguage() throws {
        var germanEngine = TimeLearningEngine(language: .german, seed: 501)
        let germanWrong = try XCTUnwrap(
            germanEngine.currentQuestion.choices.first { $0 != germanEngine.currentQuestion.time }
        )
        let germanResult = try XCTUnwrap(germanEngine.submit(answer: germanWrong))
        XCTAssertEqual(germanResult.message, "Fast! Versuch es noch einmal.")
        XCTAssertTrue(germanResult.hint?.message.contains("kurze Zeiger") == true)

        var englishEngine = TimeLearningEngine(language: .english, seed: 501)
        let englishWrong = try XCTUnwrap(
            englishEngine.currentQuestion.choices.first { $0 != englishEngine.currentQuestion.time }
        )
        let englishResult = try XCTUnwrap(englishEngine.submit(answer: englishWrong))
        XCTAssertEqual(englishResult.message, "Almost! Try once more.")
        XCTAssertTrue(englishResult.hint?.message.contains("short hand") == true)
    }

    func testChangingEngineLanguageChangesSubsequentFeedbackWithoutChangingQuestion() throws {
        var engine = TimeLearningEngine(language: .german, seed: 902)
        let question = engine.currentQuestion
        engine.setLanguage(.english)

        XCTAssertEqual(engine.currentQuestion, question)
        let evaluation = try XCTUnwrap(engine.submit(answer: question.time))
        XCTAssertTrue(evaluation.message.hasPrefix("Correct!"))
        XCTAssertTrue(evaluation.explanation.contains("long hand"))
    }
}

final class LearningProgressPersistenceTests: XCTestCase {
    func testLearningProgressCodableRoundTripPreservesEarnedState() throws {
        var engine = TimeLearningEngine(seed: 700, masteryThreshold: 2)

        _ = try XCTUnwrap(engine.submit(answer: engine.currentQuestion.time))
        XCTAssertTrue(engine.moveToNextQuestion())
        _ = try XCTUnwrap(engine.submit(answer: engine.currentQuestion.time))
        XCTAssertTrue(engine.moveToNextQuestion())
        let wrongAnswer = try XCTUnwrap(
            engine.currentQuestion.choices.first { $0 != engine.currentQuestion.time }
        )
        _ = try XCTUnwrap(engine.submit(answer: wrongAnswer))

        let data = try JSONEncoder().encode(engine.progress)
        let restored = try JSONDecoder().decode(LearningProgress.self, from: data)

        XCTAssertEqual(restored, engine.progress)
        XCTAssertEqual(restored.level, .halfHour)
        XCTAssertEqual(restored.totalCorrect, 2)
        XCTAssertEqual(restored.totalAttempts, 3)
        XCTAssertEqual(restored.totalStars, 6)
        XCTAssertEqual(restored.currentStreak, 0)
        XCTAssertEqual(restored.longestStreak, 2)
    }

    func testLearningProgressDecodeNormalizesDamagedStatistics() throws {
        let damagedJSON = Data(
            """
            {
              "level": 2,
              "masteryCount": -3,
              "totalCorrect": 2,
              "totalAttempts": 1,
              "totalStars": 999,
              "currentStreak": 8,
              "longestStreak": -4,
              "curriculumCompleted": true
            }
            """.utf8
        )

        let restored = try JSONDecoder().decode(LearningProgress.self, from: damagedJSON)

        XCTAssertEqual(restored.level, .quarterHour)
        XCTAssertEqual(restored.masteryCount, 0)
        XCTAssertEqual(restored.totalCorrect, 2)
        XCTAssertEqual(restored.totalAttempts, 2)
        XCTAssertEqual(restored.totalStars, 6)
        XCTAssertEqual(restored.currentStreak, 2)
        XCTAssertEqual(restored.longestStreak, 2)
        XCTAssertFalse(restored.curriculumCompleted)
    }

    func testEngineRestoresLevelAndClampsMasteryToCurrentThreshold() throws {
        let damagedJSON = Data(
            """
            {
              "level": 3,
              "masteryCount": 500,
              "totalCorrect": 12,
              "totalAttempts": 15,
              "totalStars": 25,
              "currentStreak": 3,
              "longestStreak": 8,
              "curriculumCompleted": false
            }
            """.utf8
        )
        let progress = try JSONDecoder().decode(LearningProgress.self, from: damagedJSON)

        let engine = TimeLearningEngine(
            language: .english,
            restoredProgress: progress,
            seed: 701,
            masteryThreshold: 4
        )

        XCTAssertEqual(engine.progress.level, .fiveMinutes)
        XCTAssertEqual(engine.currentQuestion.level, .fiveMinutes)
        XCTAssertEqual(engine.progress.masteryCount, 3)
        XCTAssertEqual(engine.progress.totalCorrect, 12)
        XCTAssertEqual(engine.progress.totalStars, 25)
        XCTAssertEqual(engine.progress.currentStreak, 3)
        XCTAssertEqual(engine.progress.longestStreak, 8)
    }

    func testExtremeCorruptStatisticsCannotOverflowOnNextAnswer() throws {
        let maximum = Int.max
        let damagedJSON = Data(
            """
            {
              "level": 0,
              "masteryCount": \(maximum),
              "totalCorrect": \(maximum),
              "totalAttempts": \(maximum),
              "totalStars": \(maximum),
              "currentStreak": \(maximum),
              "longestStreak": \(maximum),
              "curriculumCompleted": false
            }
            """.utf8
        )
        let progress = try JSONDecoder().decode(LearningProgress.self, from: damagedJSON)
        var engine = TimeLearningEngine(
            restoredProgress: progress,
            seed: 706,
            masteryThreshold: 4
        )

        XCTAssertLessThan(engine.progress.totalAttempts, Int.max / 2)
        XCTAssertNotNil(engine.submit(answer: engine.currentQuestion.time))
        XCTAssertGreaterThan(engine.progress.totalAttempts, 0)
    }

    func testProgressStoreRoundTripsAndClearsCorruptData() throws {
        let fixture = makeStoreFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        var engine = TimeLearningEngine(seed: 702)
        _ = try XCTUnwrap(engine.submit(answer: engine.currentQuestion.time))

        XCTAssertTrue(fixture.store.save(engine.progress))
        XCTAssertEqual(fixture.store.load(), engine.progress)

        fixture.defaults.set(Data("not-json".utf8), forKey: LearningProgressStore.defaultKey)
        XCTAssertNil(fixture.store.load())
        XCTAssertNil(fixture.defaults.object(forKey: LearningProgressStore.defaultKey))
    }

    @MainActor
    func testViewModelPersistsMutationsAndNextInstanceRestoresThem() throws {
        let fixture = makeStoreFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        let first = LearningViewModel(seed: 703, progressStore: fixture.store)
        first.choose(first.question.time)
        XCTAssertEqual(fixture.store.load(), first.progress)
        first.continueLesson()
        first.start(level: .fiveMinutes)

        let expectedProgress = first.progress
        let second = LearningViewModel(seed: 704, progressStore: fixture.store)

        XCTAssertEqual(second.progress, expectedProgress)
        XCTAssertEqual(second.progress.level, .fiveMinutes)
        XCTAssertEqual(second.question.level, .fiveMinutes)
        XCTAssertEqual(second.progress.totalCorrect, 1)
        XCTAssertEqual(second.progress.totalStars, 3)
    }

    @MainActor
    func testOnlySpokenCorrectAnswerAdvancesAfterFeedbackCompletion() {
        let voiceViewModel = LearningViewModel(seed: 707)
        let spokenQuestionID = voiceViewModel.question.id

        voiceViewModel.chooseSpoken(voiceViewModel.question.time)

        XCTAssertEqual(voiceViewModel.question.id, spokenQuestionID)
        XCTAssertTrue(voiceViewModel.canContinue)
        voiceViewModel.continueAfterSpokenFeedback(questionID: spokenQuestionID)
        XCTAssertNotEqual(voiceViewModel.question.id, spokenQuestionID)

        let tapViewModel = LearningViewModel(seed: 708)
        let tappedQuestionID = tapViewModel.question.id

        tapViewModel.choose(tapViewModel.question.time)
        tapViewModel.continueAfterSpokenFeedback(questionID: tappedQuestionID)

        XCTAssertEqual(tapViewModel.question.id, tappedQuestionID)
        XCTAssertTrue(tapViewModel.canContinue)
        tapViewModel.continueLesson()
        XCTAssertNotEqual(tapViewModel.question.id, tappedQuestionID)

        let fallbackViewModel = LearningViewModel(seed: 710)
        let fallbackQuestionID = fallbackViewModel.question.id
        fallbackViewModel.chooseSpoken(fallbackViewModel.question.time)
        fallbackViewModel.continueLesson()
        let manuallyAdvancedQuestionID = fallbackViewModel.question.id

        fallbackViewModel.continueAfterSpokenFeedback(
            questionID: fallbackQuestionID
        )

        XCTAssertEqual(
            fallbackViewModel.question.id,
            manuallyAdvancedQuestionID,
            "a late drain after manual Next must not advance twice"
        )

        let cancelledViewModel = LearningViewModel(seed: 711)
        let cancelledQuestionID = cancelledViewModel.question.id
        cancelledViewModel.chooseSpoken(cancelledViewModel.question.time)
        cancelledViewModel.cancelSpokenAutoAdvance()
        cancelledViewModel.continueAfterSpokenFeedback(
            questionID: cancelledQuestionID
        )
        XCTAssertEqual(cancelledViewModel.question.id, cancelledQuestionID)
    }

    @MainActor
    func testViewModelFallsBackToCleanProgressWhenStoreIsCorrupt() {
        let fixture = makeStoreFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.defaults.set("wrong-value-type", forKey: LearningProgressStore.defaultKey)

        let viewModel = LearningViewModel(seed: 705, progressStore: fixture.store)

        XCTAssertEqual(viewModel.progress, LearningProgress())
        XCTAssertEqual(fixture.store.load(), LearningProgress())
    }

    private func makeStoreFixture() -> (
        store: LearningProgressStore,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "LearningProgressPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (LearningProgressStore(defaults: defaults), defaults, suiteName)
    }
}
