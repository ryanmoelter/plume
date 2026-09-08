import Testing
import Foundation
@testable import Plume

struct GitHubQueryTests {
    @Test func eachBranchGetsItsOwnAlias() {
        let (query, aliases) = GitHubQuery.build(branches: ["main", "ryanm/forge-core"])
        #expect(aliases == ["b0": "main", "b1": "ryanm/forge-core"])
        #expect(query.contains("b0: pullRequests(headRefName: \"main\""))
        #expect(query.contains("b1: pullRequests(headRefName: \"ryanm/forge-core\""))
    }

    /// A slash is legal unescaped, and escaping it (as `JSONSerialization`
    /// does) makes every prefixed branch name unmatchable.
    @Test func aSlashInABranchNameSurvivesUnescaped() {
        let (query, _) = GitHubQuery.build(branches: ["ryanm/forge-core"])
        #expect(query.contains("\"ryanm/forge-core\""))
        #expect(!query.contains("ryanm\\/forge-core"))
    }

    @Test func theQueryTakesOwnerAndNameAsVariables() {
        let (query, _) = GitHubQuery.build(branches: ["main"])
        #expect(query.hasPrefix("query($owner: String!, $name: String!)"))
        #expect(query.contains("repository(owner: $owner, name: $name)"))
    }

    /// Responses route by alias, so the owner login must come back too.
    @Test func theQueryAsksForTheRepositoryOwner() {
        let (query, _) = GitHubQuery.build(branches: ["main"])
        #expect(query.contains("owner { login }"))
        #expect(query.contains("headRepositoryOwner { login }"))
    }

    /// `headRefName` appears only as a filter argument, never as a requested
    /// field — routing a response by it is not an option that exists.
    @Test func headRefNameIsOnlyAFilterArgument() {
        let (query, _) = GitHubQuery.build(branches: ["main"])
        #expect(query.contains("headRefName: "))
        #expect(!query.contains("headRefName }"))
        #expect(!query.contains("headRefName "))
    }

    @Test func branchNamesAreJSONEscaped() {
        let (query, _) = GitHubQuery.build(branches: ["weird\"branch\\name"])
        #expect(query.contains("headRefName: \"weird\\\"branch\\\\name\""))
    }

    @Test func thirtyBranchesFitOneChunk() {
        let branches = (0..<30).map { "b\($0)" }
        #expect(GitHubQuery.chunks(of: branches).count == 1)
    }

    @Test func thirtyOneBranchesSplitAtThirty() {
        let branches = (0..<31).map { "branch\($0)" }
        let chunks = GitHubQuery.chunks(of: branches)
        #expect(chunks.map(\.count) == [30, 1])
        #expect(chunks[1] == ["branch30"])
    }

    @Test func noBranchesMakeNoChunks() {
        #expect(GitHubQuery.chunks(of: []).isEmpty)
    }

    /// Each chunk restarts its aliases at b0, so aliases only mean anything
    /// alongside their own query's map.
    @Test func aliasesRestartPerChunk() {
        let chunks = GitHubQuery.chunks(of: (0..<31).map { "branch\($0)" })
        let (_, aliases) = GitHubQuery.build(branches: chunks[1])
        #expect(aliases == ["b0": "branch30"])
    }
}
