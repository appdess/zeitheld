import XCTest

@MainActor
final class JourneyStageSelectionUITests: XCTestCase {
    func testJourneyStageButtonsOpenHalfThenFullHourPractice() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--english"]
        app.launch()
        for stage in [1, 0] {
            app.buttons["journey-tab"].tap()
            let button = app.buttons["journey-level-\(stage)"]
            for _ in 0..<20 {
                let top = app.navigationBars.firstMatch.frame.maxY + 8
                let bottom = app.buttons["journey-tab"].frame.minY - 8
                if button.exists && button.isHittable,
                   button.frame.minY >= top,
                   button.frame.maxY <= bottom { break }
                let above = button.exists && button.frame.minY < top
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.4 : 0.7))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.6 : 0.5))
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
            }
            XCTAssertTrue(button.isHittable)
            button.tap()
            XCTAssertTrue(app.buttons["voice-coach-button"].waitForExistence(timeout: 3))
            let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "answer-choice-"))
            XCTAssertEqual(choices.count, 3)
            // Check the actual clock, not every distractor: the half-hour stage
            // deliberately offers a whole-hour wrong answer as well.
            let description = stage == 1 ? "The long hand points to 6." : "The long hand points to 12."
            let clock = app.descendants(matching: .any).matching(NSPredicate(format: "value BEGINSWITH %@", description)).firstMatch
            XCTAssertTrue(clock.waitForExistence(timeout: 3))
            XCTAssertTrue(choices.allElementsBoundByIndex.contains { $0.identifier.hasSuffix(stage == 1 ? "-30" : "-0") })
        }
    }
}
