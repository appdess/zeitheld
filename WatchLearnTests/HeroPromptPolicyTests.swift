import XCTest
@testable import WatchLearn

final class HeroPromptPolicyTests: XCTestCase {
    func testSanitizesWhitespaceControlsAndLength() throws {
        let raw = "  Curly\n\thair\u{0007} and a robot fox  " + String(repeating: "!", count: 400)
        let sanitized = try HeroPromptPolicy.sanitize(raw)

        XCTAssertTrue(sanitized.hasPrefix("Curly hair and a robot fox"))
        XCTAssertFalse(sanitized.contains("\n"))
        XCTAssertLessThanOrEqual(sanitized.count, HeroPromptPolicy.maximumDescriptionLength)
    }

    func testRejectsExistingCharacterAndWeaponReferences() {
        XCTAssertThrowsError(try HeroPromptPolicy.sanitize("Superman flies over a clock")) {
            XCTAssertEqual($0 as? HeroPromptPolicyError, .existingCharacter)
        }
        XCTAssertThrowsError(try HeroPromptPolicy.sanitize("A friendly hero with a sword")) {
            XCTAssertEqual($0 as? HeroPromptPolicyError, .unsafeAction)
        }
        XCTAssertThrowsError(try HeroPromptPolicy.sanitize("Ein Held will schießen")) {
            XCTAssertEqual($0 as? HeroPromptPolicyError, .unsafeAction)
        }
        XCTAssertThrowsError(try HeroPromptPolicy.sanitize("Ein gruseliger Dämon")) {
            XCTAssertEqual($0 as? HeroPromptPolicyError, .unsafeAction)
        }
        XCTAssertThrowsError(try HeroPromptPolicy.sanitize("Email me at kid@example.com")) {
            XCTAssertEqual($0 as? HeroPromptPolicyError, .personalInformation)
        }
    }

    func testRejectsCommonChildPIIPhrasesInEnglishAndGerman() {
        let privateIdeas = [
            "My name is Mia and I can fly",
            "I'm Mia and my cape glows",
            "I’m Charlotte and my boots sparkle",
            "i'm mia and my cape glows",
            "ich bin Mia und ich fliege",
            "I am Charlotte and my cape glows",
            "I live at 8 River Road",
            "My school is Rainbow School",
            "I go to Sunflower Kindergarten",
            "Ich heiße Ben und fliege schnell",
            "Mein Name ist Noah",
            "Ich wohne in Berlin",
            "Meine Schule ist die Sonnenschule",
            "Ich gehe in die Regenbogen Kita"
        ]

        for idea in privateIdeas {
            XCTAssertThrowsError(try HeroPromptPolicy.sanitize(idea), idea) {
                XCTAssertEqual($0 as? HeroPromptPolicyError, .personalInformation)
            }
        }
    }

    func testBoundsInputBeforeRegexAndUnicodeNormalization() throws {
        let oversizedPrefix = String(repeating: "✨", count: 20_000)
        let sanitized = try HeroPromptPolicy.sanitize(oversizedPrefix)

        XCTAssertLessThanOrEqual(sanitized.count, HeroPromptPolicy.maximumDescriptionLength)
        XCTAssertLessThanOrEqual(
            sanitized.unicodeScalars.count,
            HeroPromptPolicy.maximumRawInputScalars
        )
    }

    func testAllowsNonPersonalFirstPersonHeroTraits() throws {
        XCTAssertEqual(
            try HeroPromptPolicy.sanitize("I am a fast hero with curly hair"),
            "I am a fast hero with curly hair"
        )
        XCTAssertEqual(
            try HeroPromptPolicy.sanitize("Ich bin ein mutiger Held mit Leuchtstiefeln"),
            "Ich bin ein mutiger Held mit Leuchtstiefeln"
        )
        XCTAssertEqual(
            try HeroPromptPolicy.sanitize("A skillful hero with glowing boots"),
            "A skillful hero with glowing boots"
        )
    }

    func testRejectsCommonFranchiseSpacingAndHyphenVariants() {
        for idea in ["Super Man", "Super-Man", "Spider Man", "Iron-Man"] {
            XCTAssertThrowsError(try HeroPromptPolicy.sanitize(idea), idea) {
                XCTAssertEqual($0 as? HeroPromptPolicyError, .existingCharacter)
            }
        }
    }

    func testBuildsDeterministicKidSafeOriginalPrompt() throws {
        let idea = try HeroPromptPolicy.sanitize("Curly hair and a tiny robot fox")
        let design = HeroDesign(
            skinTone: .deep,
            power: .fireFlight,
            gear: .rocketBoots,
            scene: .fireSky
        )

        let first = HeroGenerationPromptBuilder.prompt(
            design: design,
            approvedDescription: idea
        )
        let second = HeroGenerationPromptBuilder.prompt(
            design: design,
            approvedDescription: idea
        )

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("deep brown skin"))
        XCTAssertTrue(first.contains("safe glowing fire rings"))
        XCTAssertTrue(first.contains("entirely original"))
        XCTAssertTrue(first.contains("No text, letters, numbers, logos"))
        XCTAssertTrue(first.contains("No text, letters, numbers, logos, brands, watermarks, weapons"))
        XCTAssertTrue(first.contains("Curly hair and a tiny robot fox"))
        XCTAssertTrue(first.contains("analog clock face"))
    }

    func testSelectedTraitsAreEnoughWithoutFreeText() throws {
        XCTAssertEqual(try HeroPromptPolicy.sanitize(""), "")
        let prompt = HeroGenerationPromptBuilder.prompt(
            design: HeroDesign(),
            approvedDescription: ""
        )
        XCTAssertTrue(prompt.contains("use only the selected traits"))
    }
}
