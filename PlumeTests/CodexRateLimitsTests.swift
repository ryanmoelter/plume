import Foundation
import Testing

@testable import Plume

@MainActor
struct CodexRateLimitsTests {
    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test func accountReadSelectsCodexAndUsesWindowDurations() throws {
        var limits = CodexRateLimits()
        let info = limits.receive(try decode(#"""
        {"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300}},
         "rateLimitsByLimitId":{"codex":{"limitId":"codex",
           "primary":{"usedPercent":70,"windowDurationMins":10080,"resetsAt":1800000000},
           "secondary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1799990000}}}}
        """#))
        #expect(info?.fiveHour?.utilization == 0.25)
        #expect(info?.sevenDay?.utilization == 0.70)
        #expect(info?.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(info?.isUsingOverage == false)
    }

    @Test func rollingUpdatesClearExplicitNullMetadataAndWindows() throws {
        var limits = CodexRateLimits()
        _ = limits.receive(try decode(#"""
        {"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800000000},
          "secondary":{"usedPercent":70,"windowDurationMins":10080}}}
        """#))
        let info = limits.receive(try decode(#"""
        {"rateLimits":{"primary":{"usedPercent":30,"windowDurationMins":null,"resetsAt":null},"secondary":null}}
        """#))
        #expect(info == nil)
        #expect(limits.windows[0].usedPercent == 30)
        #expect(limits.windows[0].resetsAt == nil)
        #expect(info?.sevenDay == nil)
        #expect(limits.windows.count == 1)
        #expect(limits.windows[0].durationMinutes == nil)
    }

    @Test func unrelatedBucketsDoNotOverwriteCodex() throws {
        var limits = CodexRateLimits()
        let original = limits.receive(try decode(#"""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300}}}
        """#))
        let update = limits.receive(try decode(#"""
        {"rateLimits":{"limitId":"codex_other","primary":{"usedPercent":99,"windowDurationMins":300}}}
        """#))
        #expect(update == original)
    }

    @Test func nullableMultiBucketSnapshotFallsBackToLegacyWindow() throws {
        var limits = CodexRateLimits()
        let info = limits.receive(try decode(#"""
        {"rateLimitsByLimitId":null,"rateLimits":{"limitId":null,
          "primary":{"usedPercent":18,"windowDurationMins":300,"resetsAt":1800000000},
          "secondary":null}}
        """#))
        #expect(info?.fiveHour?.utilization == 0.18)
        #expect(info?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(info?.sevenDay == nil)
    }

    @Test func rollingResetReplacesUtilizationAndResetTime() throws {
        var limits = CodexRateLimits()
        _ = limits.receive(try decode(#"""
        {"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1800000000},
          "secondary":{"usedPercent":70,"windowDurationMins":10080}}}
        """#))
        let info = limits.receive(try decode(#"""
        {"rateLimits":{"primary":{"usedPercent":0,"resetsAt":1800018000}}}
        """#))
        #expect(info?.fiveHour?.utilization == 0)
        #expect(info?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_800_018_000))
        #expect(info?.sevenDay?.utilization == 0.70)
    }

    @Test func unknownDurationsAreNotMislabeled() throws {
        var limits = CodexRateLimits()
        let info = limits.receive(try decode(#"""
        {"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":60},"secondary":{"usedPercent":70}}}
        """#))
        #expect(info == nil)
        #expect(limits.windows.count == 2)
        #expect(limits.windows[0].durationMinutes == 60)
        #expect(limits.windows[1].durationMinutes == nil)
    }

    @Test func fullSnapshotPreservesEveryBucketAndEveryDuration() throws {
        var limits = CodexRateLimits()
        _ = limits.receive(try decode(#"""
        {"rateLimits": {"primary":{"usedPercent":1,"windowDurationMins":300}},
         "rateLimitsByLimitId": {
           "codex": {"limitId":"codex","limitName":"Codex","primary":{"usedPercent":25,"windowDurationMins":60}},
           "team": {"limitId":"team","primary":{"usedPercent":80,"windowDurationMins":1440},"secondary":{"usedPercent":5,"windowDurationMins":null}}
         }}
        """#))

        #expect(limits.windows.map(\.bucketID) == ["codex", "team", "team"])
        #expect(limits.windows.map(\.durationMinutes) == [60, 1440, nil])
        #expect(limits.windows.map(\.usedPercent) == [25, 80, 5])
    }

    @Test func aLaterFullSnapshotRemovesBucketsThatDisappeared() throws {
        var limits = CodexRateLimits()
        _ = limits.receive(try decode(#"""
        {"rateLimitsByLimitId": {
          "codex": {"primary":{"usedPercent":25,"windowDurationMins":300}},
          "team": {"primary":{"usedPercent":80,"windowDurationMins":1440}}
        }, "rateLimits": {"primary":{"usedPercent":25,"windowDurationMins":300}}}
        """#))
        _ = limits.receive(try decode(#"""
        {"rateLimitsByLimitId": {
          "codex": {"primary":{"usedPercent":30,"windowDurationMins":300}}
        }, "rateLimits": {"primary":{"usedPercent":30,"windowDurationMins":300}}}
        """#))

        #expect(limits.windows.count == 1)
        #expect(limits.windows[0].bucketID == "codex")
    }

    @Test func sparseUpdateWithoutBucketIDDoesNotOverwriteOtherBuckets() throws {
        var limits = CodexRateLimits()
        _ = limits.receive(try decode(#"""
        {"rateLimitsByLimitId": {
          "codex": {"primary":{"usedPercent":25,"windowDurationMins":300}},
          "team": {"primary":{"usedPercent":80,"windowDurationMins":1440}}
        }, "rateLimits": {"primary":{"usedPercent":25,"windowDurationMins":300}}}
        """#))
        _ = limits.receive(try decode(#"""
        {"rateLimits":{"primary":{"usedPercent":30,"windowDurationMins":null}}}
        """#))

        #expect(limits.windows.count == 2)
        #expect(limits.windows.first(where: { $0.bucketID == "codex" })?.usedPercent == 30)
        #expect(limits.windows.first(where: { $0.bucketID == "team" })?.usedPercent == 80)
    }

    @Test func notificationUpdatesTheSessionQuota() {
        let client = CodexAppServerClient { _ in true }
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: client)
        client.receive(#"""
        {"method":"account/rateLimits/updated","params":{"rateLimits":{
          "primary":{"usedPercent":45,"windowDurationMins":300},
          "secondary":{"usedPercent":81,"windowDurationMins":10080}}}}
        """#)
        #expect(session.rateLimit?.fiveHour?.utilization == 0.45)
        #expect(session.rateLimit?.sevenDay?.utilization == 0.81)
    }

    @Test func initialFetchPopulatesQuotaBeforeAnyTurn() async throws {
        var client: CodexAppServerClient!
        var requestedMethod: String?
        client = CodexAppServerClient { line in
            let request = try! JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            requestedMethod = request["method"]?.stringValue
            let response: JSONValue = .object([
                "id": request["id"]!,
                "result": .object(["rateLimits": .object([
                    "primary": .object(["usedPercent": .number(12), "windowDurationMins": .number(300)]),
                    "secondary": .object(["usedPercent": .number(34), "windowDurationMins": .number(10_080)])
                ])])
            ])
            client.receive(String(data: try! JSONEncoder().encode(response), encoding: .utf8)!)
            return true
        }
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: client)
        defer { client.stop() }
        await session.hydrateRateLimits()
        #expect(requestedMethod == "account/rateLimits/read")
        #expect(session.rateLimit?.fiveHour?.utilization == 0.12)
        #expect(session.rateLimit?.sevenDay?.utilization == 0.34)
        #expect(session.lastError == nil)
        #expect(session.sessionID == nil)
    }

    @Test func unavailableAccountQuotaDoesNotFailTheSession() async {
        let client = CodexAppServerClient { _ in false }
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: client)
        await session.hydrateRateLimits()
        #expect(session.rateLimit == nil)
        #expect(session.lastError == nil)
        #expect(!session.hasExited)
    }
}
