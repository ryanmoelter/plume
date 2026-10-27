import Foundation
import Testing
@testable import Plume

/// An error that is not a conflict leaves the checkout where `sync` started.
struct StackSyncErrorTests {
    @Test func aNonConflictErrorReturnsToTheStartingBranch() throws {
        let repo = try StackScratchRepo()
        try repo.git("switch", "-qc", "a")
        try repo.commit("a-one")
        try repo.git("switch", "-qc", "b")
        try repo.commit("b-one")
        try repo.git("switch", "-qc", "c")
        try repo.commit("c-one")
        let base = try repo.rev("main")
        try repo.git("switch", "-q", "main")
        try repo.commit("trunk-one")
        try repo.pushTrunk()
        try repo.git("switch", "-q", "c")
        let aTip = try repo.rev("a")
        let bTip = try repo.rev("b")
        try repo.writeState([
            "a": entry("main", base),
            "b": entry("a", aTip),
            "c": entry("b", bTip),
        ])
        let sibling = "\(repo.directory)/sibling"
        try repo.git("worktree", "add", "-q", sibling, "b")
        try repo.write("b-one", "dirty", in: sibling)

        let failure = stackFailure { try Stack.sync(repo.context(forge: RecordingStackForge([:])), ["--trunk"]) }

        #expect(failure?.code == 1)
        #expect(failure?.message?.contains("uncommitted changes") == true)
        #expect(try repo.git("branch", "--show-current") == "c")
        #expect(try repo.rev("a") != aTip)
    }
}
