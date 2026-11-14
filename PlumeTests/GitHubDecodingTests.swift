import Testing
import Foundation
@testable import Plume

/// `notability-pending.json` is a real `gh api graphql` response: one open
/// draft PR with 50 rollup contexts spanning both union members.
struct GitHubDecodingTests {
    private static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Forge/\(name).json")
        return try Data(contentsOf: url)
    }

    private func decodeFixture() throws -> PullRequest {
        let data = try Self.fixture("notability-pending")
        let decoded = try GitHubQuery.decode(data, aliasToBranch: ["b0": "some-branch"])
        return try #require(decoded["some-branch"] ?? nil)
    }

    @Test func theCapturedResponseDecodes() throws {
        let pr = try decodeFixture()
        #expect(pr.number == 61730)
        #expect(pr.state == .open)
        #expect(pr.isDraft)
        #expect(pr.baseRefName == "staging")
        #expect(pr.headRefOid == "05607a786696852a82b5e51da9e1f8fca4e63161")
        #expect(pr.url == "https://github.com/Ginger-Labs/Notability/pull/61730")
        #expect(pr.title == "Read every selected Google calendar, not only the primary")
    }

    /// REVIEW_REQUIRED means nobody has weighed in, which is the same to a
    /// reader as no decision at all.
    @Test func reviewRequiredShowsNoMarker() throws {
        #expect(try decodeFixture().reviewDecision == .none)
    }

    /// The capture's 50 contexts carry 27 names: label-triggered workflows
    /// ran the same checks up to five times on one commit.
    @Test func everyRollupContextDecodesOncePerName() throws {
        let pr = try decodeFixture()
        #expect(pr.checkContexts.count == 27)
        #expect(Set(pr.checkContexts.map(\.name)).count == 27)
        #expect(pr.checkContexts.allSatisfy { !$0.name.isEmpty })
        #expect(pr.checkContexts.allSatisfy { !$0.status.isEmpty })
    }

    @Test func bothUnionMembersDecode() throws {
        let contexts = try decodeFixture().checkContexts
        // A CheckRun, named and concluded.
        #expect(contexts.contains(CheckContext(name: "check-do-not-merge", status: "SUCCESS")))
        // A StatusContext, whose name comes from `context` and status from `state`.
        #expect(contexts.contains(
            CheckContext(name: "ci/circleci: lint_backend", status: "PENDING")
        ))
    }

    @Test func anInProgressRunKeepsItsStatus() throws {
        let contexts = try decodeFixture().checkContexts
        #expect(contexts.contains(
            CheckContext(name: "web-preview-deploy (notability-staging)", status: "IN_PROGRESS")
        ))
    }

    @Test func theCapturedResponseFoldsToPending() throws {
        #expect(try decodeFixture().checkRollup() == .pending)
    }

    /// Ignoring every unsettled check in the capture leaves only successes,
    /// skips and neutrals — the asymmetry working on real data.
    @Test func ignoringTheUnsettledChecksFoldsToSuccess() throws {
        let pr = try decodeFixture()
        let unsettled = Set(
            pr.checkContexts
                .filter { !["SUCCESS", "NEUTRAL", "SKIPPED", "CANCELLED"].contains($0.status) }
                .map(\.name)
        )
        #expect(!unsettled.isEmpty)
        #expect(pr.checkRollup(ignoredWhenPending: unsettled) == .success)
    }

    @Test func aRerunReplacesTheRunBeforeIt() throws {
        let json = """
        {"data":{"repository":{"owner":{"login":"me"},"b0":{"nodes":[
        {"number":7,"state":"OPEN","isDraft":false,
         "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
          {"__typename":"CheckRun","name":"build","conclusion":"SUCCESS","status":"COMPLETED","startedAt":"2026-11-10T10:05:00Z"},
          {"__typename":"CheckRun","name":"build","conclusion":"FAILURE","status":"COMPLETED","startedAt":"2026-11-10T10:00:00Z"},
          {"__typename":"StatusContext","context":"ci/lint","state":"SUCCESS","createdAt":"2026-11-10T10:00:00Z"}
         ]}}}}]}}]}}}}
        """
        let decoded = try GitHubQuery.decode(Data(json.utf8), aliasToBranch: ["b0": "main"])
        let pr = try #require(decoded["main"] ?? nil)
        #expect(pr.checkContexts.map(\.name) == ["build", "ci/lint"])
        #expect(pr.checkContexts.first?.status == "SUCCESS")
        #expect(pr.checkContexts.last?.startedAt != nil)
        #expect(pr.checkRollup() == .success)
    }

    // MARK: - Null shapes

    @Test func aNullRollupDecodesAsNoChecks() throws {
        let json = """
        {"data":{"repository":{"owner":{"login":"me"},"b0":{"nodes":[
        {"number":7,"state":"OPEN","isDraft":false,"baseRefName":"main",
         "url":"u","title":"t","headRefOid":"abc","reviewDecision":null,
         "headRepositoryOwner":{"login":"me"},
         "commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}]}}}}
        """
        let decoded = try GitHubQuery.decode(Data(json.utf8), aliasToBranch: ["b0": "main"])
        let pr = try #require(decoded["main"] ?? nil)
        #expect(pr.checkContexts.isEmpty)
        #expect(pr.checkRollup() == .none)
        #expect(pr.reviewDecision == .none)
    }

    @Test func eachUnionMemberCarriesItsPageURL() throws {
        let json = """
        {"data":{"repository":{"owner":{"login":"me"},"b0":{"nodes":[
        {"number":7,"state":"OPEN","isDraft":false,
         "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
           {"__typename":"CheckRun","name":"build","conclusion":"SUCCESS","detailsUrl":"https://example.com/run"},
           {"__typename":"StatusContext","context":"ci/lint","state":"PENDING","targetUrl":"https://example.com/status"},
           {"__typename":"CheckRun","name":"bare","conclusion":"SUCCESS"}
         ]}}}}]}}]}}}}
        """
        let decoded = try GitHubQuery.decode(Data(json.utf8), aliasToBranch: ["b0": "main"])
        let contexts = try #require(decoded["main"] ?? nil).checkContexts
        let urls = Dictionary(uniqueKeysWithValues: contexts.map { ($0.name, $0.url) })
        #expect(urls["build"] == URL(string: "https://example.com/run"))
        #expect(urls["ci/lint"] == URL(string: "https://example.com/status"))
        #expect(urls["bare"] == .some(nil))
    }

    @Test func aRequestedOrPastReviewerCountsAsAssigned() throws {
        func decode(requests: Int, reviews: Int) throws -> Bool {
            let json = """
            {"data":{"repository":{"owner":{"login":"me"},"b0":{"nodes":[
            {"number":7,"state":"OPEN","isDraft":false,
             "reviewRequests":{"totalCount":\(requests)},"latestReviews":{"totalCount":\(reviews)}}]}}}}
            """
            let decoded = try GitHubQuery.decode(Data(json.utf8), aliasToBranch: ["b0": "main"])
            return try #require(decoded["main"] ?? nil).hasReviewers
        }
        #expect(try decode(requests: 1, reviews: 0))
        #expect(try decode(requests: 0, reviews: 2))
        #expect(try !decode(requests: 0, reviews: 0))
    }

    @Test func aBranchWithNoPullRequestMapsToNil() throws {
        let json = """
        {"data":{"repository":{"owner":{"login":"me"},"b0":{"nodes":[]}}}}
        """
        let decoded = try GitHubQuery.decode(Data(json.utf8), aliasToBranch: ["b0": "main"])
        #expect(decoded.keys.contains("main"))
        #expect((decoded["main"] ?? nil) == nil)
    }

    /// Every requested branch appears in the result, even one the response
    /// omits entirely.
    @Test func anAbsentAliasStillMapsToNil() throws {
        let json = """
        {"data":{"repository":{"owner":{"login":"me"}}}}
        """
        let decoded = try GitHubQuery.decode(Data(json.utf8), aliasToBranch: ["b0": "main"])
        #expect(decoded.count == 1)
        #expect((decoded["main"] ?? nil) == nil)
    }

    @Test(arguments: [("MERGED", PullRequestState.merged), ("CLOSED", .closed)])
    func nonOpenStatesDecode(_ raw: String, _ expected: PullRequestState) throws {
        let json = """
        {"data":{"repository":{"owner":{"login":"me"},"b0":{"nodes":[
        {"number":7,"state":"\(raw)","isDraft":false,"headRepositoryOwner":{"login":"me"}}]}}}}
        """
        let decoded = try GitHubQuery.decode(Data(json.utf8), aliasToBranch: ["b0": "main"])
        #expect((decoded["main"] ?? nil)?.state == expected)
    }

    @Test(arguments: [
        ("APPROVED", ReviewDecision.approved),
        ("CHANGES_REQUESTED", .changesRequested),
        ("REVIEW_REQUIRED", .none),
    ])
    func reviewDecisionsMap(_ raw: String, _ expected: ReviewDecision) {
        #expect(ReviewDecision(rawValue: raw) == expected)
    }
}
