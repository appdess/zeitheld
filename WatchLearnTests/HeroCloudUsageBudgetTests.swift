import Foundation
import XCTest
@testable import WatchLearn

@MainActor
final class HeroCloudUsageBudgetTests: XCTestCase {
    func testColoringCanFollowImageImmediatelyButSharesDailyImageAllowance() async throws {
        let suite = "HeroCloudUsageBudgetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let budget = PersistentHeroCloudUsageBudget(defaults: defaults, keyPrefix: "fixture")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try await budget.authorize(.image, at: start)
        try await budget.authorize(.coloring, at: start)
        do {
            try await budget.authorize(.coloring, at: start.addingTimeInterval(2))
            XCTFail("Repeated coloring must still use its own cooldown.")
        } catch {
            XCTAssertEqual(error as? HeroCloudUsageBudgetError, .cooldown(operation: .coloring, seconds: 13))
        }
        for index in 1...3 {
            let next = start.addingTimeInterval(TimeInterval(index * 20))
            try await budget.authorize(.image, at: next)
            try await budget.authorize(.coloring, at: next)
        }
        for operation in [HeroCloudOperation.image, .coloring] {
            do {
                try await budget.authorize(operation, at: start.addingTimeInterval(180))
                XCTFail("Images and coloring pages must share the eight-image allowance.")
            } catch {
                XCTAssertEqual(error as? HeroCloudUsageBudgetError, .dailyLimit(operation: operation))
            }
        }
    }

    func testImageCooldownAndDailyLimitAreEnforced() async throws {
        let suite = "HeroCloudUsageBudgetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let budget = PersistentHeroCloudUsageBudget(
            defaults: defaults,
            calendar: calendar,
            keyPrefix: "fixture"
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        try await budget.authorize(.image, at: start)
        do {
            try await budget.authorize(.image, at: start.addingTimeInterval(2))
            XCTFail("Expected cooldown")
        } catch {
            XCTAssertEqual(
                error as? HeroCloudUsageBudgetError,
                .cooldown(operation: .image, seconds: 13)
            )
        }

        for index in 1..<8 {
            try await budget.authorize(
                .image,
                at: start.addingTimeInterval(TimeInterval(index * 20))
            )
        }
        do {
            try await budget.authorize(.image, at: start.addingTimeInterval(180))
            XCTFail("Expected daily limit")
        } catch {
            XCTAssertEqual(
                error as? HeroCloudUsageBudgetError,
                .dailyLimit(operation: .image)
            )
        }
    }

    func testTranscriptionHasIndependentBudget() async throws {
        let suite = "HeroCloudUsageBudgetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let budget = PersistentHeroCloudUsageBudget(
            defaults: defaults,
            keyPrefix: "fixture"
        )
        let date = Date(timeIntervalSince1970: 1_800_100_000)

        try await budget.authorize(.image, at: date)
        try await budget.authorize(.transcription, at: date)
    }
}
