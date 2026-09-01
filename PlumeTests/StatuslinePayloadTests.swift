import Testing
import Foundation
@testable import Plume

struct StatuslinePayloadTests {
    @Test func decodesAFullPayload() throws {
        let json = """
        {
          "context_window": {
            "used_percentage": 41.5,
            "total_input_tokens": 80000,
            "total_output_tokens": 2000,
            "context_window_size": 200000
          },
          "rate_limits": {
            "five_hour": { "used_percentage": 30, "resets_at": 1735689600 },
            "seven_day": { "used_percentage": 55, "resets_at": 1736294400 }
          },
          "cost": { "total_cost_usd": 1.23 },
          "workspace": { "current_dir": "/repo" },
          "cwd": "/repo/sub",
          "model": { "display_name": "Sonnet 5" },
          "effort": { "level": "medium" }
        }
        """
        let payload = try JSONDecoder().decode(StatuslinePayload.self, from: Data(json.utf8))

        #expect(payload.contextWindow?.usedPercentage == 41.5)
        #expect(payload.contextUsedTokens == 82000)
        #expect(payload.rateLimits?.fiveHour?.usedPercentage == 30)
        #expect(payload.rateLimits?.sevenDay?.resetsAt == 1736294400)
        #expect(payload.cost?.totalCostUSD == 1.23)
        #expect(payload.effectiveCwd == "/repo")
        #expect(payload.model?.displayName == "Sonnet 5")
        #expect(payload.effort?.level == "medium")
    }

    @Test func decodesWithRateLimitsAbsent() throws {
        let json = """
        {
          "context_window": {
            "used_percentage": 10,
            "total_input_tokens": 1000,
            "total_output_tokens": 0,
            "context_window_size": 200000
          },
          "cost": { "total_cost_usd": 0.01 },
          "cwd": "/repo",
          "model": { "display_name": "Sonnet 5" },
          "effort": { "level": "" }
        }
        """
        let payload = try JSONDecoder().decode(StatuslinePayload.self, from: Data(json.utf8))

        #expect(payload.rateLimits == nil)
        #expect(payload.effectiveCwd == "/repo")
        #expect(payload.contextUsedTokens == 1000)
    }

    @Test func decodesAnEmptyPayloadWithoutThrowing() throws {
        let payload = try JSONDecoder().decode(StatuslinePayload.self, from: Data("{}".utf8))
        #expect(payload.contextWindow == nil)
        #expect(payload.contextUsedTokens == nil)
        #expect(payload.effectiveCwd == nil)
    }

    @Test func decodesUnknownFieldsWithoutThrowing() throws {
        let json = """
        { "some_new_field": { "nested": true }, "cost": { "total_cost_usd": 0.5 } }
        """
        let payload = try JSONDecoder().decode(StatuslinePayload.self, from: Data(json.utf8))
        #expect(payload.cost?.totalCostUSD == 0.5)
    }
}
