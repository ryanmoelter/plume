import Foundation
import Testing
@testable import Plume

/// The forge pieces `wt` adds to the app's GitHub client: GitLab's query and
/// normalizer, the forge override and project path, the backends, and the
/// background fetch. Ported from `test_forge.py`; its GitHub query, pick-best
/// and decoding cases already live in `GitHubQueryTests`,
/// `GitHubPickBestTests` and `GitHubDecodingTests`, and its native-stack
/// cases belong to the `stack` port.
struct ForgeTests {
    // MARK: detection

    @Test func theOverrideWinsOverTheSniff() {
        #expect(ForgeKind.resolving(originURL: "git@git.corp:o/r.git", override: .gitlab) == .gitlab)
    }

    @Test func withoutAnOverrideTheOriginIsSniffed() {
        #expect(ForgeKind.resolving(originURL: "git@github.com:o/r.git", override: nil) == .github)
        #expect(ForgeKind.resolving(originURL: "https://gitlab.example.com/g/r", override: nil) == .gitlab)
        #expect(ForgeKind.resolving(originURL: nil, override: nil) == .none)
    }

    @Test func theForgeSettingDecodesFromItsName() throws {
        let decoded = try JSONDecoder().decode([ForgeKind].self, from: Data(#"["github","gitlab","none"]"#.utf8))
        #expect(decoded == [.github, .gitlab, .none])
    }

    @Test func gitlabFullPathFromSSHAndHTTPS() {
        #expect(GitLabQuery.fullPath(originURL: "git@gitlab.com:g/s/r.git") == "g/s/r")
        #expect(GitLabQuery.fullPath(originURL: "https://gitlab.com/g/r/") == "g/r")
    }

    @Test func gitlabFullPathUnresolvable() {
        #expect(GitLabQuery.fullPath(originURL: "") == nil)
        #expect(GitLabQuery.fullPath(originURL: nil) == nil)
    }

    // MARK: GitLab

    private static func node(
        _ iid: Int,
        _ state: String = "opened",
        branch: String = "feat",
        draft: Bool = false,
        approved: Bool = false,
        changesRequested: Bool = false,
        pipeline: String? = nil
    ) -> [String: Any] {
        [
            "iid": String(iid),
            "state": state,
            "draft": draft,
            "sourceBranch": branch,
            "targetBranch": "main",
            "webUrl": "https://gitlab.test/mr/\(iid)",
            "title": "MR \(iid)",
            "diffHeadSha": "sha\(iid)",
            "approvedBy": ["nodes": approved ? [["username": "rev"]] : []],
            "reviewers": ["nodes": changesRequested ? [["mergeRequestInteraction": ["reviewState": "REQUESTED_CHANGES"]]] : []],
            "headPipeline": pipeline.map { ["status": $0] as Any } ?? NSNull(),
        ]
    }

    private static func normalize(_ nodes: [String: Any]...) throws -> PullRequestMap {
        let response: [String: Any] = ["data": ["project": ["mergeRequests": ["nodes": nodes]]]]
        return try GitLabQuery.normalize(JSONSerialization.data(withJSONObject: response))
    }

    /// `"10" < "9"` as strings, so iids must compare as numbers.
    @Test func openedWinsThenTheHighestIIDNumerically() throws {
        let prs = try Self.normalize(Self.node(9), Self.node(10), Self.node(12, "closed"))
        #expect(prs["feat"]?.number == 10)
        #expect(prs["feat"]?.state == .open)
    }

    @Test func statesMap() throws {
        let prs = try Self.normalize(Self.node(1, "merged", branch: "a"), Self.node(2, "closed", branch: "b"))
        #expect(prs["a"]?.state == .merged)
        #expect(prs["b"]?.state == .closed)
    }

    @Test func fieldsMap() throws {
        let pr = try #require(try Self.normalize(Self.node(4, draft: true))["feat"])
        #expect(pr == PullRequest(
            number: 4, state: .open, isDraft: true, url: "https://gitlab.test/mr/4", title: "MR 4",
            baseRefName: "main", headRefOid: "sha4"
        ))
    }

    @Test func reviewDecisions() throws {
        let prs = try Self.normalize(
            Self.node(1, branch: "a", approved: true),
            Self.node(2, branch: "b", changesRequested: true),
            Self.node(3, branch: "c")
        )
        #expect(prs["a"]?.reviewDecision == .approved)
        #expect(prs["b"]?.reviewDecision == .changesRequested)
        #expect(prs["c"]?.reviewDecision == ReviewDecision.none)
    }

    @Test(arguments: [
        ("SUCCESS", CheckRollup.success),
        ("FAILED", .failure),
        ("RUNNING", .pending),
        ("CANCELED", .none),
        (nil, .none),
    ] as [(String?, CheckRollup)])
    func pipelinesFold(_ status: String?, _ expected: CheckRollup) throws {
        let pr = try #require(try Self.normalize(Self.node(1, pipeline: status))["feat"])
        #expect(pr.checkRollup() == expected)
    }

    /// GitLab's MergeRequest calls the head SHA `diffHeadSha`; a bare `sha`
    /// fails the whole query.
    @Test func theQueryInlinesAndEscapesBranches() {
        let query = GitLabQuery.build(fullPath: "group/proj", branches: [#"a"b"#])
        #expect(query.contains(#"sourceBranches: ["a\"b"]"#))
        #expect(query.contains(#"project(fullPath: "group/proj")"#))
        #expect(query.contains("diffHeadSha"))
    }

    // MARK: backends

    @Test func backendsNameTheirNumbersAndNouns() {
        let github = GitHubBackend(workingDirectory: nil)
        let gitlab = GitLabBackend(fullPath: "g/r", workingDirectory: nil)
        #expect((github.numberPrefix, github.noun) == ("#", "PR"))
        #expect((gitlab.numberPrefix, gitlab.noun) == ("!", "MR"))
    }

    @Test func theBackendFollowsTheKind() {
        #expect(ForgeBackends.backend(for: .github, originURL: "git@github.com:o/r.git", workingDirectory: nil)?.kind == .github)
        #expect(ForgeBackends.backend(for: .gitlab, originURL: "git@gitlab.com:g/r.git", workingDirectory: nil)?.kind == .gitlab)
        #expect(ForgeBackends.backend(for: .none, originURL: "git@github.com:o/r.git", workingDirectory: nil) == nil)
    }

    @Test func aGitLabOriginWithNoReadablePathHasNoBackend() {
        #expect(ForgeBackends.backend(for: .gitlab, originURL: nil, workingDirectory: nil) == nil)
    }

    // MARK: fetch

    @Test func aFinishedFetchIsOn() {
        let prs: PullRequestMap = ["main": PullRequest(number: 1, state: .open, isDraft: false)]
        let resolved = PRFetch.resolve(prs)
        #expect(resolved.state == .on)
        #expect(resolved.prs == prs)
    }

    @Test func aFailedFetchIsError() {
        let resolved = PRFetch.resolve(nil)
        #expect(resolved.state == .error)
        #expect(resolved.prs.isEmpty)
    }

    @Test func theFetchRunsInTheBackground() {
        let pr = PullRequest(number: 1, state: .open, isDraft: false)
        let fetch = PRFetch(branches: ["a"]) { branches in
            Dictionary(uniqueKeysWithValues: branches.map { ($0, pr) })
        }
        #expect(fetch.wait(timeout: 5))
        #expect(fetch.result == ["a": pr])
    }

    @Test func aFetchThatFailsFinishesWithNoResult() {
        let fetch = PRFetch(branches: ["a"]) { _ in nil }
        #expect(fetch.wait(timeout: 5))
        #expect(fetch.result == nil)
    }

    @Test func aHungFetchTimesOut() {
        let release = DispatchSemaphore(value: 0)
        let fetch = PRFetch(branches: ["a"]) { _ in
            release.wait()
            return [:]
        }
        #expect(!fetch.wait(timeout: 0.05))
        release.signal()
    }
}
