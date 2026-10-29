import Foundation
import Testing
@testable import Plume

/// Every subcommand and alias reaches its command. These run the commands
/// themselves, so they pass only once every command is ported.
struct WTDispatchTests {
    /// Every alias reaches the same command, shown by the same failure on
    /// the same arguments.
    @Test(arguments: [
        ("co", "checkout", ["--bogus"]),
        ("o", "open", ["foo", "--bogus"]),
        ("bg", "background", ["--bogus"]),
        ("fg", "foreground", []),
        ("r", "rename", ["--bogus"]),
        ("cm", "commit", []),
        ("d", "delete", ["--bogus"]),
        ("p", "prune", ["--bogus"]),
        ("l", "list", ["--bogus"]),
        ("s", "switch", ["foo"]),
    ] as [(String, String, [String])])
    func aliasesReachTheirCommand(_ alias: String, _ name: String, _ arguments: [String]) throws {
        let viaAlias = try #require(cliFailure { try WT.run(FakeWTContext(canOpenTabs: false), [alias] + arguments) })
        let viaName = try #require(cliFailure { try WT.run(FakeWTContext(canOpenTabs: false), [name] + arguments) })
        #expect(viaAlias == viaName)
    }

    @Test func cobCreatesABranch() throws {
        let ctx = FakeWTContext(prefix: "ryanm/", baseBranch: "main")
        try WT.run(ctx, ["cob", "x", "--no-tab"])
        #expect(ctx.fakeGit.added.map(\.branch) == ["ryanm/x"])
        #expect(ctx.fakeGit.added.map(\.new) == [true])
    }

    @Test(arguments: ["help", "-h", "--help"])
    func helpSucceeds(_ spelling: String) throws {
        let ctx = FakeWTContext()
        try WT.run(ctx, [spelling])
        #expect(ctx.buffer.stdout.contains("wt"))
    }

    @Test func currentDispatches() throws {
        let ctx = FakeWTContext(worktrees: [wtRow("repo", "main", "")], current: "repo", branchByPath: ["/repo": "main"])
        try WT.run(ctx, ["current"])
        #expect(ctx.buffer.stdout == "repo  main\n")
    }
}
