import Foundation
import XCTest
@testable import WatchLearn

/// Opt-in, cost-bearing smoke test for the complete production Hero pipeline:
/// text moderation, GPT Image generation, and generated-image moderation.
@MainActor
final class LiveOpenAIHeroTests: XCTestCase {
    func testOriginalActionHeroGenerationPipeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WATCHLEARN_RUN_LIVE_HERO"] == "1" else {
            throw XCTSkip("Set WATCHLEARN_RUN_LIVE_HERO=1 to opt in to this cost-bearing live test.")
        }
        guard let apiKey = environment["OPENAI_API_KEY"], !apiKey.isEmpty else {
            throw XCTSkip("Set OPENAI_API_KEY to run the cost-bearing live test.")
        }

        let result = try await OpenAIHeroImageGenerationService().generate(
            design: HeroDesign(),
            description: "Curly hair and a friendly little robot fox companion",
            apiKey: apiKey
        )

        XCTAssertFalse(result.imageData.isEmpty)
        XCTAssertTrue(OpenAIHeroImageGenerationService.isDecodableImage(result.imageData))
        XCTAssertTrue(result.prompt.localizedCaseInsensitiveContains("original"))
        XCTAssertTrue(result.prompt.localizedCaseInsensitiveContains("logos"))
        XCTAssertTrue(result.prompt.localizedCaseInsensitiveContains("no text"))

        if let outputPath = environment["WATCHLEARN_LIVE_HERO_OUTPUT"], !outputPath.isEmpty {
            try result.imageData.write(
                to: URL(fileURLWithPath: outputPath),
                options: [.atomic, .completeFileProtectionUnlessOpen]
            )
        }
    }
}
