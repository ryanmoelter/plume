import Foundation
import Testing
@testable import Plume

/// `wt current` and the flags `list` and `current` share. `current` backs the
/// Sublime status bar, which polls it for arbitrary files, so outside a
/// worktree `--json` reports nulls and succeeds. Ported from
/// `test_wt_current.py`.
struct WTCurrentTests {
    private func context(current: String?) -> FakeWTContext {
        FakeWTContext(worktrees: [wtRow("repo", "main", "")], current: current, branchByPath: ["/repo": "main"])
    }

    @Test func jsonInsideAWorktree() throws {
        let ctx = context(current: "repo")
        try WT.current(ctx, ["--json"])
        let expected: NSDictionary = [
            "worktree": "repo", "branch": "main", "path": "/repo", "root": "/repo", "layout": "standard",
        ]
        #expect(jsonObject(ctx.buffer.stdout) == expected)
    }

    /// "Not a worktree" is a normal answer the status bar shouldn't have to
    /// parse off stderr.
    @Test func jsonOutsideAWorktreeReportsNullsAndSucceeds() throws {
        let ctx = context(current: nil)
        try WT.current(ctx, ["--json"])
        let expected: NSDictionary = [
            "worktree": NSNull(), "branch": NSNull(), "path": NSNull(), "root": "/repo", "layout": "standard",
        ]
        #expect(jsonObject(ctx.buffer.stdout) == expected)
    }

    @Test func humanOutputInsideAWorktree() throws {
        let ctx = context(current: "repo")
        try WT.current(ctx, [])
        #expect(ctx.buffer.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "repo  main")
    }

    @Test func humanOutputOutsideAWorktreeFails() {
        let ctx = context(current: nil)
        #expect(cliFailure { try WT.current(ctx, []) }?.code == 1)
        #expect(ctx.buffer.stdout == "")
    }

    @Test func currentRejectsAnUnknownFlag() {
        #expect(cliFailure { try WT.current(context(current: "repo"), ["--bogus"]) }?.code == 1)
    }

    @Test func listJSONOnAnEmptyRepositoryIsStillValidJSON() throws {
        let ctx = FakeWTContext()
        try WT.list(ctx, ["--json"])
        let expected: NSDictionary = ["pr_state": "off", "worktrees": [Any]()]
        #expect(jsonObject(ctx.buffer.stdout) == expected)
    }

    @Test func plainListOnAnEmptyRepositoryStaysHuman() throws {
        let ctx = FakeWTContext()
        try WT.list(ctx, [])
        #expect(ctx.buffer.stdout.contains("no worktrees"))
    }

    @Test func listRejectsAnUnknownFlag() {
        #expect(cliFailure { try WT.list(FakeWTContext(), ["--bogus"]) }?.code == 1)
    }

    @Test func listJSONReportsEveryWorktree() throws {
        let ctx = FakeWTContext(worktrees: WTFixtures.rows, current: "dotfiles")
        try WT.list(ctx, ["--json"])
        let payload = try #require(jsonObject(ctx.buffer.stdout))
        let names = (payload["worktrees"] as? [NSDictionary])?.compactMap { $0["name"] as? String }
        #expect(names == ["dotfiles", "scratch", "det"])
        #expect(payload["pr_state"] as? String == "off")
    }
}
