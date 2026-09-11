import XCTest

@MainActor
final class HeroGenerationPersistenceUITests: XCTestCase {
    func testHeroVoiceInputShowsRecordingProcessingAndAcceptedDescription() throws {
        let app = XCUIApplication()
        app.launchArguments = fixtureArguments
        app.launch()
        app.buttons["hero-lab-tab"].tap()
        let microphone = app.buttons["hero-description-microphone"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 5))
        XCTAssertEqual(microphone.label, "Describe your hero")
        microphone.tap()
        XCTAssertTrue(app.staticTexts["I'm listening!"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.progressIndicators["Microphone level"].exists)
        let recording = XCTAttachment(screenshot: app.screenshot())
        recording.name = "Hero recording feedback"; recording.lifetime = .keepAlways; add(recording)
        microphone.tap()
        XCTAssertTrue(app.descendants(matching: .any)["hero-transcribing-status"].firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["hero-description-accepted"].firstMatch.waitForExistence(timeout: 12))
        XCTAssertEqual(app.textViews["hero-description-text"].value as? String, "A friendly hero with a blue cape.")
        app.buttons["hero-back-to-clock"].tap()
        XCTAssertTrue(app.buttons["voice-coach-button"].waitForExistence(timeout: 3))
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEveryHeroTraitAndCreateSelectDeleteNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = fixtureArguments
        app.launch()
        app.buttons["hero-lab-tab"].tap()
        let title = app.staticTexts["hero-description-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Hero description first"; screenshot.lifetime = .keepAlways; add(screenshot)
        XCTAssertTrue(app.buttons["hero-description-microphone"].isHittable)
        let description = app.textViews["hero-description-text"]
        XCTAssertGreaterThan(title.frame.minY, app.navigationBars["Hero Lab"].frame.maxY)
        XCTAssertLessThan(title.frame.maxY, description.frame.minY)
        description.tap()
        description.typeText("A friendly clock hero with a blue cape.")
        app.buttons["hero-description-done"].tap()
        let optional = app.buttons["hero-optional-choices"]
        scrollUpUntilHittable(optional, in: app)
        optional.tap()
        for label in ["Deep skin tone", "Warm skin tone", "Light skin tone",
                      "Fire flight", "Wave dash", "Star glow", "Cloud bounce",
                      "Wind cape", "Rocket boots", "Time gloves", "Glow suit",
                      "Clock city", "Fire sky", "Moon bridge", "Ocean cliffs"] {
            let button = app.buttons[label]
            scrollUpUntilHittable(button, in: app)
            button.tap()
            XCTAssertTrue(button.isSelected, "The selected trait must visibly change: \(label)")
        }
        app.buttons["hero-back-to-clock"].tap()
        XCTAssertTrue(app.buttons["voice-coach-button"].waitForExistence(timeout: 3))
        app.buttons["hero-lab-tab"].tap()
        let generate = app.buttons["hero-generate-button"]
        scrollUpUntilHittable(generate, in: app)
        generate.tap()
        let select = app.buttons["hero-select-background"]
        XCTAssertTrue(select.waitForExistence(timeout: 12))
        scrollUpUntilHittable(select, in: app)
        select.tap()
        XCTAssertTrue(app.images["learning-custom-hero-background"].waitForExistence(timeout: 3))
        app.buttons["parent-settings-button"].tap()
        let delete = app.buttons["Delete local hero pictures"]
        scrollUpUntilHittable(delete, in: app)
        delete.tap()
        app.buttons["Delete pictures"].tap()
        app.buttons["settings-done-button"].tap()
        XCTAssertFalse(app.images["learning-custom-hero-background"].exists)
        XCTAssertTrue(app.images["learning-built-in-hero-avatar"].exists)
    }

    func testGenerationContinuesAcrossTabChangeAndSelectionPersistsAcrossRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = fixtureArguments
        app.launch()

        app.buttons["hero-lab-tab"].tap()
        XCTAssertTrue(app.staticTexts["Describe your hero"].waitForExistence(timeout: 5))

        let generateButton = app.buttons["hero-generate-button"]
        scrollUpUntilHittable(generateButton, in: app)
        generateButton.tap()
        XCTAssertTrue(
            app.staticTexts["hero-generation-status"]
                .waitForExistence(timeout: 2),
            "The fixture generation must be observably in flight before changing tabs."
        )

        app.buttons["learn-tab"].tap()
        XCTAssertTrue(app.staticTexts["Clock Heroes"].waitForExistence(timeout: 3))

        // The deterministic generator finishes while the Hero Lab is absent.
        XCTAssertFalse(app.images["learning-custom-hero-background"].exists)
        sleep(5)
        app.buttons["hero-lab-tab"].tap()

        let selectButton = app.buttons["hero-select-background"]
        XCTAssertTrue(
            selectButton.waitForExistence(timeout: 3),
            "The completed generated image must still exist after returning to Hero Lab."
        )
        scrollUpUntilHittable(selectButton, in: app)
        selectButton.tap()

        app.buttons["learn-tab"].tap()
        XCTAssertTrue(
            app.images["learning-custom-hero-background"]
                .waitForExistence(timeout: 3),
            "Selecting the generated picture must update the learning screen."
        )

        app.terminate()
        app.launchArguments = fixtureArguments + ["--ui-testing-preserve-state"]
        app.launch()

        XCTAssertTrue(
            app.images["learning-custom-hero-background"]
                .waitForExistence(timeout: 5),
            "The selected generated background must be restored after relaunch."
        )

        // A final non-preserving fixture launch removes only the fixture store.
        app.terminate()
        app.launchArguments = fixtureArguments
        app.launch()
        XCTAssertTrue(
            app.images["learning-built-in-hero-avatar"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.images["learning-custom-hero-background"].exists)
    }

    private var fixtureArguments: [String] {
        [
            "--ui-testing",
            "--english",
            "--ui-testing-hero-generation-fixture"
        ]
    }

    private func scrollUpUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 8
    ) {
        for _ in 0..<attempts where !element.exists || !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        XCTAssertTrue(element.isHittable)
    }
}
