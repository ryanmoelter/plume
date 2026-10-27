import Foundation
import Testing
@testable import Plume

/// The helpers commands are built on: `wt list`'s rows and status cluster,
/// and the branch and folder naming rules. Ported from `test_wt_list.py`.
struct WTHelperTests {
    private let rows = WTFixtures.rows

    // MARK: rows

    @Test func rowsFollowWorktreeOrderAndStatus() {
        let ctx = FakeWTContext(worktrees: rows)
        #expect(WT.buildRows(ctx) == rows)
    }

    /// Each status call blocks until every row's call has started, which
    /// only a parallel scan can satisfy. The timeout fails a serial one.
    @Test func rowsScanEveryWorktreeAtOnce() {
        let ctx = FakeWTContext(worktrees: rows)
        let arrived = DispatchGroup()
        for _ in rows { arrived.enter() }
        let allArrived = LockedList<Bool>()
        ctx.onWorktreeStatus = { _ in
            arrived.leave()
            allArrived.append(arrived.wait(timeout: .now() + 5) == .success)
        }
        #expect(WT.buildRows(ctx) == rows)
        #expect(allArrived.values == [true, true, true])
    }

    /// On the base branch, ahead-of-base re-counts the unpushed commits `↑`
    /// already shows, so it's dropped; `↑` and `↓` stay.
    @Test func theBaseBranchsRowDropsItsAheadCount() {
        let ctx = FakeWTContext(worktrees: rows, baseBranch: "main")
        let built = WT.buildRows(ctx)
        #expect(built == [wtRow("dotfiles", "main", "", dirty: true, remoteAhead: 2, remoteBehind: 1), rows[1], rows[2]])
    }

    @Test func clusterShapes() {
        #expect(WT.statusCluster(ahead: "4", dirty: true) == "↗4 +")
        #expect(WT.statusCluster(ahead: "4", dirty: false) == "↗4")
        #expect(WT.statusCluster(ahead: "", dirty: true) == "+")
        #expect(WT.statusCluster(ahead: "0", dirty: true) == "+")
        #expect(WT.statusCluster(ahead: "", dirty: false) == "")
        #expect(WT.statusCluster(ahead: "0", dirty: false) == "")
    }

    @Test func clusterRemoteAheadAndBehind() {
        #expect(WT.statusCluster(ahead: "4", dirty: true, remoteAhead: 2, remoteBehind: 1) == "↗4 ↑2 ↓1 +")
        #expect(WT.statusCluster(ahead: "", dirty: false, remoteAhead: 2) == "↑2")
        #expect(WT.statusCluster(ahead: "", dirty: false, remoteBehind: 3) == "↓3")
        #expect(WT.statusCluster(ahead: "4", dirty: false) == "↗4")
    }

    // MARK: naming helpers

    @Test func folderStripsTheFirstSegmentAndFlattens() {
        #expect(WT.folderForBranch("ryanm/foo") == "foo")
        #expect(WT.folderForBranch("cc/feature/thing") == "feature-thing")
        #expect(WT.folderForBranch("spike") == "spike")
    }

    @Test func aConfiguredPrefixIsAddedOnce() throws {
        let ctx = FakeWTContext(prefix: "ryanm/")
        #expect(try WT.branchFor(ctx, "foo") == "ryanm/foo")
        #expect(try WT.branchFor(ctx, "ryanm/foo") == "ryanm/foo")
    }

    @Test func anExplicitEmptyPrefixPassesThrough() throws {
        #expect(try WT.branchFor(FakeWTContext(prefix: "ryanm/"), "foo", prefix: "") == "foo")
    }

    @Test func anEmptyConfiguredPrefix() throws {
        #expect(try WT.branchFor(FakeWTContext(prefix: ""), "foo") == "foo")
    }

    @Test func anExactBranchWinsOverASuffix() throws {
        #expect(try WT.resolveBranch(FakeWTContext(branches: ["wt", "ryanm/wt"]), "wt") == "wt")
    }

    @Test func aUniqueSuffixMatches() throws {
        #expect(try WT.resolveBranch(FakeWTContext(branches: ["ryanm/wt", "ryanm/other"]), "wt") == "ryanm/wt")
    }

    /// `t` ends `wt` but isn't a whole `/`-delimited segment.
    @Test func aSuffixNeedsAWholeSegment() {
        #expect(cliFailure { _ = try WT.resolveBranch(FakeWTContext(branches: ["ryanm/wt"]), "t") } != nil)
    }

    @Test func noMatchFails() {
        #expect(cliFailure { _ = try WT.resolveBranch(FakeWTContext(branches: ["ryanm/other"]), "wt") } != nil)
    }

    @Test func anAmbiguousSuffixFails() {
        #expect(cliFailure { _ = try WT.resolveBranch(FakeWTContext(branches: ["ryanm/wt", "cc/wt"]), "wt") } != nil)
    }
}
