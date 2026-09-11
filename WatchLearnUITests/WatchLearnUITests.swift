import XCTest

@MainActor
final class WatchLearnUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPrivacyReviewReturnsToSettingsWithoutAccepting() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--english"]
        app.launch()
        app.buttons["parent-settings-button"].tap()
        let review = app.buttons["parent-review-agreement"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        let back = app.buttons["agreement-back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        let confirmation = app.buttons["agreement-confirm"]
        scrollTo(confirmation, in: app)
        XCTAssertTrue(confirmation.isHittable)
        back.tap()
        XCTAssertTrue(app.buttons["settings-done-button"].waitForExistence(timeout: 5))
        app.buttons["settings-done-button"].tap()
        XCTAssertTrue(app.buttons["voice-coach-button"].waitForExistence(timeout: 5))
    }

    private func revealPrivateKey(_ app: XCUIApplication) {
        // Start from the top of a fresh Settings sheet, regardless of the
        // preceding permissions/language scroll position or expanded state.
        app.buttons["settings-done-button"].tap()
        app.buttons["parent-settings-button"].tap()
        let disclosure = app.buttons["private-key-disclosure"]
        scrollTo(disclosure, in: app)
        disclosure.tap()
        let key = app.secureTextFields["api-key-field"]
        scrollTo(key, in: app)
    }

    func testFiveMinuteTrialAndOwnKeyAreAvailableWithoutSigningIn() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--english", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-parent.language", "en", "-parent.follows-device-language", "NO"]
        app.launch()
        app.buttons["parent-settings-button"].tap()
        let intro = app.staticTexts["free-trial-introduction"]
        XCTAssertTrue(intro.waitForExistence(timeout: 5))
        XCTAssertTrue(intro.label.contains("5 free minutes"))
        let picker = app.segmentedControls["online-access-picker"]
        scrollTo(picker, in: app)
        picker.buttons["Own API key"].tap()
        // This also runs against Release, where fixture/reset switches are absent.
        let field = app.secureTextFields["api-key-field"]
        revealPrivateKey(app)
        scrollTo(field, in: app)
        field.tap()
        field.typeText("sk-fixture-never-real-release-1234567890")
        app.buttons["api-key-save"].tap()
        XCTAssertTrue(app.staticTexts["Stored in iOS Keychain"].exists)
        // Verify the saved key can also be removed after leaving Settings.
        revealPrivateKey(app)
        let delete = app.buttons["api-key-delete"]
        scrollTo(delete, in: app)
        delete.tap()
        XCTAssertFalse(delete.exists)
        let issues = app.buttons["report-issue-link"]
        scrollTo(issues, in: app)
        XCTAssertTrue(issues.label.contains("GitHub"))
        app.buttons["settings-done-button"].tap()
        XCTAssertTrue(app.buttons["voice-coach-button"].isHittable)
    }

    func testBetaTermsAreAvailableInBothLanguagesAndReturnToSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--english"]
        app.launch()
        app.buttons["parent-settings-button"].tap()
        for (linkTitle, pageTitle) in [("Beta terms of use", "Beta use"), ("Nutzungsbedingungen der Beta", "Beta-Nutzung")] {
            if pageTitle == "Beta-Nutzung" {
                let picker = app.segmentedControls["language-picker"]
                for _ in 0..<10 where !picker.isHittable { app.swipeDown() }
                // A hittable segment can still be clipped by the sheet edge.
                // Bring the complete control into the body before selecting it.
                app.swipeDown()
                picker.buttons["Deutsch"].tap()
                XCTAssertTrue(app.navigationBars["Einstellungen"].waitForExistence(timeout: 3))
            }
            let link = app.buttons[linkTitle]
            for _ in 0..<10 where !link.isHittable { app.swipeUp() }
            XCTAssertTrue(link.isHittable)
            link.tap()
            XCTAssertTrue(app.navigationBars[pageTitle].waitForExistence(timeout: 3))
            XCTAssertTrue(app.descendants(matching: .any)["beta-terms-content"].exists)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = pageTitle
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.navigationBars[pageTitle].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["settings-done-button"].exists)
        }
        app.buttons["settings-done-button"].tap()
        XCTAssertTrue(app.buttons["voice-coach-button"].isHittable)
    }

    func testJourneyProfilesResetAndNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--english"]
        app.launch()
        XCTAssertFalse(app.buttons["Deutsch"].exists)
        app.buttons["answer-choice-5-0"].tap()
        app.buttons["answer-choice-4-0"].tap()
        app.buttons["journey-tab"].tap()
        XCTAssertTrue(app.staticTexts["Try-again answers"].waitForExistence(timeout: 3))
        app.buttons["add-child"].tap()
        XCTAssertTrue(app.navigationBars["New child"].waitForExistence(timeout: 3))
        app.textFields["child-name-field"].tap()
        app.textFields["child-name-field"].typeText("Mika")
        app.buttons["save-child"].tap()
        XCTAssertTrue(app.buttons["child-Mika"].waitForExistence(timeout: 3))
        app.buttons["journey-back-to-clock"].tap()
        app.buttons["parent-settings-button"].tap()
        app.buttons["reset-journey"].tap()
        XCTAssertTrue(app.staticTexts["Reset Mika's journey?"].waitForExistence(timeout: 3))
        app.buttons["Erase this journey"].tap()
        app.buttons["settings-done-button"].tap()
        app.buttons["current-child-button"].tap()
        app.buttons["child-My Time Hero"].tap()
        let correct = app.staticTexts["Correct!"]
        for _ in 0..<6 where !correct.isHittable { app.swipeUp() }
        XCTAssertTrue(correct.isHittable)
        XCTAssertTrue(app.staticTexts["Practise again"].exists)
        app.buttons["journey-back-to-clock"].tap()
        app.buttons["hero-lab-tab"].tap()
        XCTAssertTrue(app.buttons["hero-back-to-clock"].waitForExistence(timeout: 3))
        app.buttons["hero-back-to-clock"].tap()
        XCTAssertTrue(app.buttons["parent-settings-button"].isHittable)
    }

    func testJourneyResetIsDirectAndGermanFooterClearsNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["answer-choice-4-0"].tap()
        app.buttons["journey-tab"].tap()
        app.buttons["add-child"].tap()
        app.textFields["child-name-field"].tap()
        app.textFields["child-name-field"].typeText("Mika")
        app.buttons["save-child"].tap()
        app.buttons["journey-back-to-clock"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "answer-choice-")).firstMatch.tap()
        app.buttons["journey-tab"].tap()
        let reset = app.buttons["journey-reset"]
        for _ in 0..<4 where !reset.isHittable { app.swipeUp() }
        reset.tap()
        XCTAssertTrue(app.staticTexts["Lernreise von Mika zurücksetzen?"].waitForExistence(timeout: 3))
        app.buttons["Diese Lernreise löschen"].tap()
        let note = app.staticTexts["journey-storage-note"]
        for _ in 0..<7 where !note.isHittable { app.swipeUp() }
        app.swipeUp() // Settle at the actual end, not a partially visible footer.
        XCTAssertTrue(app.staticTexts["journey-empty-answers"].isHittable)
        XCTAssertEqual(note.label, "Namen, Fortschritt und die letzten 500 Antworten je Kind bleiben auf diesem Gerät.")
        XCTAssertGreaterThan(note.frame.height, 30, "The note must wrap onto multiple visible lines.")
        XCTAssertLessThan(note.frame.maxY, app.buttons["journey-tab"].frame.minY,
                          "The complete storage note must clear the bottom navigation.")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "German journey footer after selected-child reset"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let originalChild = app.buttons["child-Mein ZeitHeld"]
        for _ in 0..<8 where !originalChild.isHittable { app.swipeDown() }
        originalChild.tap()
        let correct = app.staticTexts["Richtig!"]
        for _ in 0..<8 where !correct.isHittable { app.swipeUp() }
        XCTAssertTrue(correct.isHittable, "Resetting Mika must preserve the other child's answer history.")
    }

    func testEasyModeSupportsTapAnswers() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--english"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Clock Heroes"].waitForExistence(timeout: 5))
        let answer = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'answer-choice-'"))
            .firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 3))
        XCTAssertTrue(answer.isHittable, "Tap answers must be visible without scrolling on a phone")
        XCTAssertTrue(app.buttons["voice-coach-button"].isHittable, "Voice must also be reachable on the first screen")
        answer.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["answer-feedback"]
                .waitForExistence(timeout: 3)
        )
    }

    func testCorrectAnswerShowsRewardAndNextQuestion() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--english"]
        app.launch()

        let correctAnswer = app.buttons["answer-choice-4-0"]
        for _ in 0..<3 where !correctAnswer.exists || !correctAnswer.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(correctAnswer.waitForExistence(timeout: 3))
        correctAnswer.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["answer-feedback"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["next-question-button"].exists)
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<18 {
            if element.exists && element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    private func acceptFixtureAgreement(_ app: XCUIApplication, voice: Bool, hero: Bool = false) {
        let review = app.buttons["privacy-permissions-button"]
        scrollTo(review, in: app); review.tap()
        for id in ["agreement-guardian", "agreement-privacy", "agreement-terms"]
            + (voice ? ["agreement-voice"] : []) + (hero ? ["agreement-hero"] : [])
            + (voice || hero ? ["agreement-adult-test"] : []) {
            let toggle = app.switches[id]
            scrollTo(toggle, in: app)
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        let confirm = app.buttons["agreement-confirm"]
        scrollTo(confirm, in: app)
        XCTAssertTrue(confirm.isEnabled); confirm.tap()
    }

    func testSignupRequiresExplicitAgreementAndOptionalCloudCanBeDeclined() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--english"]
        app.launch()
        app.buttons["parent-settings-button"].tap()
        XCTAssertFalse(app.buttons["parent-apple-sign-in"].exists)
        acceptFixtureAgreement(app, voice: false)
        app.buttons["settings-done-button"].tap()
        app.buttons["parent-settings-button"].tap()
        XCTAssertTrue(app.buttons["parent-apple-sign-in"].waitForExistence(timeout: 3))
        scrollTo(app.descendants(matching: .any)["voice-online-toggle"].firstMatch, in: app)
        XCTAssertEqual(app.descendants(matching: .any)["voice-online-toggle"].firstMatch.value as? String, "Off")
        scrollTo(app.descendants(matching: .any)["hero-online-toggle"].firstMatch, in: app)
        XCTAssertEqual(app.descendants(matching: .any)["hero-online-toggle"].firstMatch.value as? String, "Off")
        app.buttons["settings-done-button"].tap()
        XCTAssertTrue(app.buttons["voice-coach-button"].exists)
    }

    func testPrivacyChoicesCanBeWithdrawnWithoutLosingOfflineLearning() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--english"]
        app.launch()
        app.buttons["parent-settings-button"].tap()
        acceptFixtureAgreement(app, voice: true, hero: true)
        let withdraw = app.buttons["withdraw-agreement"]
        scrollTo(withdraw, in: app); withdraw.tap()
        XCTAssertTrue(app.staticTexts["withdrawal-status"].waitForExistence(timeout: 3))
        app.buttons["settings-done-button"].tap()
        app.buttons["parent-settings-button"].tap()
        XCTAssertFalse(app.buttons["parent-apple-sign-in"].exists)
        scrollTo(app.descendants(matching: .any)["voice-online-toggle"].firstMatch, in: app)
        XCTAssertEqual(app.descendants(matching: .any)["voice-online-toggle"].firstMatch.value as? String, "Off")
        scrollTo(app.descendants(matching: .any)["hero-online-toggle"].firstMatch, in: app)
        XCTAssertEqual(app.descendants(matching: .any)["hero-online-toggle"].firstMatch.value as? String, "Off")
        app.buttons["settings-done-button"].tap()
        XCTAssertTrue(app.buttons["voice-coach-button"].exists)
    }

    func testParentSettingsOpenDirectly() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--english"]
        app.launch()

        app.buttons["parent-settings-button"].tap()
        scrollTo(app.segmentedControls["language-picker"], in: app)
        XCTAssertTrue(app.segmentedControls["language-picker"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["parent-gate-answer"].exists)
    }

    func testOnlineAndAPIKeyControlsAreImmediatelyReachable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--english"]
        app.launch()

        app.buttons["parent-settings-button"].tap()
        scrollTo(app.segmentedControls["language-picker"], in: app)
        XCTAssertTrue(app.segmentedControls["language-picker"].waitForExistence(timeout: 3))
        scrollTo(app.descendants(matching: .any)["voice-online-toggle"].firstMatch, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["voice-online-toggle"].firstMatch.exists)
        scrollTo(app.descendants(matching: .any)["hero-online-toggle"].firstMatch, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["hero-online-toggle"].firstMatch.exists)
        revealPrivateKey(app)
        XCTAssertTrue(app.secureTextFields["api-key-field"].isHittable)
    }

    func testParentSettingsIdentifyActiveLive() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--english"]
        app.launch()
        app.buttons["parent-settings-button"].tap()
        let label = app.staticTexts["GPT-Live 1"]
        for _ in 0..<5 where !label.isHittable { app.swipeUp() }
        XCTAssertTrue(label.waitForExistence(timeout: 3))
        XCTAssertTrue(label.isHittable)
        XCTAssertTrue(app.buttons["live-connection-check"].exists)
        XCTAssertFalse(app.buttons["live-connection-check"].isEnabled)
        XCTAssertFalse(app.staticTexts["live-connection-success"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "GPT-Live parent setup"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testIssueReportingLinkIsReachableWithoutAParentGate() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--english"]
        app.launch()

        app.buttons["parent-settings-button"].tap()
        let reportLink = app.descendants(matching: .any)["report-issue-link"]
        for _ in 0..<8 where !reportLink.exists || !reportLink.isHittable {
            app.swipeUp()
        }

        XCTAssertTrue(reportLink.waitForExistence(timeout: 3))
        XCTAssertTrue(reportLink.isHittable)
        XCTAssertFalse(app.textFields["parent-gate-answer"].exists)
    }

    func testHeroLabOffersOfflineTraitButtonsBehindNoCloudRequirement() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--english"]
        app.launch()

        app.buttons["hero-lab-tab"].tap()
        XCTAssertTrue(app.staticTexts["Describe your hero"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["hero-description-microphone"].isHittable)
        XCTAssertTrue(app.buttons["hero-lab-parent-setup"].exists)
        let optional = app.buttons["hero-optional-choices"]
        for _ in 0..<5 where !optional.isHittable { app.swipeUp() }
        optional.tap()
        let deepSkinTone = app.buttons["Deep skin tone"]
        XCTAssertTrue(deepSkinTone.exists)
        for _ in 0..<3 where !deepSkinTone.isHittable { app.swipeUp() }
        deepSkinTone.tap()

        let fireFlight = app.buttons["Fire flight"]
        for _ in 0..<3 where !fireFlight.exists || !fireFlight.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(fireFlight.waitForExistence(timeout: 3))
        XCTAssertTrue(fireFlight.isHittable)
        fireFlight.tap()
        XCTAssertTrue(fireFlight.isSelected)
    }

    func testSavingKeyKeepsOnlineFeaturesExplicitlyOff() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--english"]
        app.launch()

        app.buttons["parent-settings-button"].tap()
        let voiceToggle = app.descendants(matching: .any)["voice-online-toggle"].firstMatch
        let heroToggle = app.descendants(matching: .any)["hero-online-toggle"].firstMatch
        scrollTo(voiceToggle, in: app)
        XCTAssertTrue(voiceToggle.waitForExistence(timeout: 3))
        XCTAssertEqual(voiceToggle.value as? String, "Off")
        scrollTo(heroToggle, in: app)
        XCTAssertEqual(heroToggle.value as? String, "Off")

        revealPrivateKey(app)
        let keyField = app.secureTextFields["api-key-field"]
        keyField.tap()
        keyField.typeText("sk-fixture-never-real-1234567890")
        app.buttons["api-key-save"].tap()

        XCTAssertTrue(app.staticTexts["Stored in iOS Keychain"].exists)

        // Saving clears the secure field and may scroll the Form. Reopen the
        // sheet so this verifies the persisted feature state, not a stale or
        // off-screen accessibility element.
        app.buttons["settings-done-button"].tap()
        app.buttons["parent-settings-button"].tap()
        scrollTo(app.descendants(matching: .any)["voice-online-toggle"].firstMatch, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["voice-online-toggle"].firstMatch.waitForExistence(timeout: 3))
        scrollTo(app.descendants(matching: .any)["voice-online-toggle"].firstMatch, in: app)
        XCTAssertEqual(app.descendants(matching: .any)["voice-online-toggle"].firstMatch.value as? String, "Off")
        scrollTo(app.descendants(matching: .any)["hero-online-toggle"].firstMatch, in: app)
        XCTAssertEqual(app.descendants(matching: .any)["hero-online-toggle"].firstMatch.value as? String, "Off")
    }

    func testLanguageOnlineToggleAndKeychainPersistAcrossRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--english"]
        app.launch()

        app.buttons["parent-settings-button"].tap()
        let languagePicker = app.segmentedControls["language-picker"]
        scrollTo(languagePicker, in: app)
        XCTAssertTrue(languagePicker.waitForExistence(timeout: 3))
        languagePicker.buttons["Deutsch"].tap()

        acceptFixtureAgreement(app, voice: true)
        scrollTo(app.descendants(matching: .any)["voice-online-toggle"].firstMatch, in: app)
        XCTAssertEqual(app.descendants(matching: .any)["voice-online-toggle"].firstMatch.value as? String, "Erlaubt")

        revealPrivateKey(app)
        let keyField = app.secureTextFields["api-key-field"]
        keyField.tap()
        keyField.typeText("sk-fixture-never-real-persistence-1234567890")
        app.buttons["api-key-save"].tap()
        XCTAssertTrue(app.staticTexts["Im iOS-Schlüsselbund gespeichert"].exists)

        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-testing-preserve-state"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Uhrenhelden"].waitForExistence(timeout: 5))
        app.buttons["parent-settings-button"].tap()
        scrollTo(app.descendants(matching: .any)["voice-online-toggle"].firstMatch, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["voice-online-toggle"].firstMatch.waitForExistence(timeout: 3))
        scrollTo(app.descendants(matching: .any)["voice-online-toggle"].firstMatch, in: app)
        XCTAssertEqual(app.descendants(matching: .any)["voice-online-toggle"].firstMatch.value as? String, "Erlaubt")
        revealPrivateKey(app)
        let storedKey = app.staticTexts["Im iOS-Schlüsselbund gespeichert"]
        scrollTo(storedKey, in: app)
        XCTAssertTrue(storedKey.exists)

        // Leave the shared Simulator Keychain clean for manual and live runs.
        app.buttons["api-key-delete"].tap()
    }

    func testEarnedProgressPersistsAcrossRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--english", "--ui-testing-persist-progress"
        ]
        app.launch()

        let correctAnswer = app.buttons["answer-choice-4-0"]
        for _ in 0..<3 where !correctAnswer.exists || !correctAnswer.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(correctAnswer.waitForExistence(timeout: 3))
        correctAnswer.tap()
        XCTAssertTrue(app.staticTexts["Stars: 3"].waitForExistence(timeout: 3))

        app.terminate()
        app.launchArguments = [
            "--ui-testing", "--english", "--ui-testing-persist-progress",
            "--ui-testing-preserve-state"
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Stars: 3"].waitForExistence(timeout: 5))

        // A final non-preserving launch clears the test-only progress record.
        app.terminate()
        app.launchArguments = [
            "--ui-testing", "--english", "--ui-testing-persist-progress"
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["Stars: 0"].waitForExistence(timeout: 5))
    }

    func testCoachButtonClearsBottomNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--english"]
        app.launch()

        let coach = app.buttons["voice-coach-button"]
        let navigation = app.descendants(matching: .any)["main-tab-bar"]
        XCTAssertTrue(coach.waitForExistence(timeout: 3))
        XCTAssertTrue(navigation.waitForExistence(timeout: 3))

        // Liquid-glass navigation intentionally lets scroll content travel
        // beneath it. Keep scrolling until the complete coach control—not
        // merely its tappable center—has cleared the glass edge.
        for _ in 0..<5 where coach.frame.maxY > navigation.frame.minY {
            app.swipeUp()
        }

        XCTAssertTrue(coach.isHittable)
        XCTAssertLessThanOrEqual(coach.frame.maxY, navigation.frame.minY + 1)
    }

    func testVoiceStatusSitsAboveBottomNavigationWithCompactCopy() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--english", "--ui-testing-voice-status"
        ]
        app.launch()

        let status = app.descendants(matching: .any)["voice-coach-status-bar"]
        let navigation = app.descendants(matching: .any)["main-tab-bar"]
        let stop = app.buttons["voice-stop-button"]

        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(navigation.waitForExistence(timeout: 5))
        XCTAssertTrue(stop.exists)
        XCTAssertTrue(stop.isHittable)
        XCTAssertLessThanOrEqual(status.frame.maxY, navigation.frame.minY + 1)
        XCTAssertTrue(app.staticTexts["Time Hero is speaking"].exists)
        XCTAssertLessThanOrEqual(
            status.frame.height,
            72,
            "the compact voice status must remain a single visual line"
        )
    }
}
