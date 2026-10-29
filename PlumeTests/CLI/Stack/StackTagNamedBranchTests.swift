import Foundation
import Testing
@testable import Plume

/// A branch named like a tag is still a local branch.
struct StackTagNamedBranchTests {
    @Test func aBranchSharingATagNameKeepsItsTracking() throws {
        let repo = try StackScratchRepo()
        try repo.git("switch", "-qc", "v2")
        try repo.commit("v2-one")
        try repo.git("tag", "v2")
        try repo.writeState(["v2": entry("main", try repo.rev("main"))])

        let branches = try repo.context().loadAndFlush()

        #expect(branches["v2"] != nil)
    }

    @Test func revResolvesTheBranchNotTheTag() throws {
        let repo = try StackScratchRepo()
        try repo.git("switch", "-qc", "v2")
        try repo.commit("v2-one")
        try repo.git("tag", "v2")
        let tip = try repo.commit("v2-two")

        #expect(try repo.context().rev("v2") == tip)
    }

    @Test func syncKeepsABranchWhoseTagMatchesTheMergedHead() throws {
        let repo = try StackScratchRepo()
        let base = try repo.rev("main")
        try repo.git("switch", "-qc", "v2")
        let mergedHead = try repo.commit("v2-one")
        try repo.git("tag", "v2")
        try repo.commit("v2-unpushed")
        try repo.git("switch", "-q", "main")
        try repo.pushTrunk()
        try repo.writeState(["v2": entry("main", base)])
        let forge = RecordingStackForge(["v2": stackPR(1, state: .merged, headRefOid: mergedHead)])

        let failure = stackFailure { try Stack.sync(repo.context(forge: forge), []) }

        #expect(failure?.code == 1)
        #expect(try repo.gitAllowingFailure("show-ref", "--verify", "--quiet", "refs/heads/v2").status == 0)
    }

    @Test func aTagSharingTheBranchNameDoesNotMoveItsAncestryChecks() throws {
        let repo = try StackScratchRepo()
        let base = try repo.rev("main")
        try repo.git("switch", "-qc", "v2")
        try repo.commit("v2-one")
        try repo.git("tag", "v2")
        try repo.commit("v2-two")
        try repo.git("switch", "-qc", "child")
        try repo.commit("child-one")
        let state = ["v2": entry("main", base), "child": entry("v2", try repo.rev("v2"))]
        try repo.writeState(state)
        let ctx = repo.context()

        #expect(try ctx.commitsOverParent(state, "v2") == 2)
        #expect(try ctx.needsRestack(state, "child") == false)
    }

    @Test func theCurrentBranchReadsAsItsNameDespiteTheTag() throws {
        let repo = try taggedRepo()

        #expect(repo.context().git.currentBranch() == "v2")
    }

    @Test func prevMovesToTheParentFromATagNamedBranch() throws {
        let repo = try taggedRepo()

        try Stack.navigate(repo.context(), .prev, [])

        #expect(repo.context().git.currentBranch() == "main")
    }

    @Test func listJSONMarksATagNamedBranchCurrent() throws {
        let repo = try taggedRepo()
        let console = BufferConsole()

        try Stack.list(repo.context(console: console), ["--json", "--no-pr"])

        #expect(console.stdout.contains("\"current\": \"v2\""))
        #expect(!console.stdout.contains("heads/"))
    }

    private func taggedRepo() throws -> StackScratchRepo {
        let repo = try StackScratchRepo()
        let base = try repo.rev("main")
        try repo.git("tag", "v2")
        try repo.git("switch", "-qc", "v2")
        try repo.commit("v2-one")
        try repo.writeState(["v2": entry("main", base)])
        return repo
    }
}
