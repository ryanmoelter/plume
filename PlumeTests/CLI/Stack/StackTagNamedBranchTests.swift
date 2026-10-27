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
}
