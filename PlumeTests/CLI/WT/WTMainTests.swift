import Foundation
import Testing
@testable import Plume

/// `wt`'s entry point: the version, which is the app's, help outside a
/// repository, the dispatcher's own failures, and the `path` and
/// `__complete` lookups.
struct WTMainTests {
    @Test(arguments: ["--version", "-V", "version"])
    func versionPrintsTheAppsVersion(_ spelling: String) {
        let console = BufferConsole()
        #expect(WT.main([spelling], environment: [:], console: console, version: "1.4 (12)") == 0)
        #expect(console.stdout == "wt 1.4 (12)\n")
    }

    @Test func versionOutsideTheAppSaysSo() {
        let console = BufferConsole()
        #expect(WT.main(["--version"], environment: [:], console: console, version: nil) == 0)
        #expect(console.stdout == "wt (not inside Plume.app)\n")
    }

    @Test(arguments: [["help"], ["-h"], ["--help"], []])
    func helpWorksOutsideARepository(_ arguments: [String]) throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let console = BufferConsole()

        let status = WT.main(
            arguments, environment: ["PLUME_BUNDLE_ID": "plume-wt-help-\(UUID().uuidString)"], console: console,
            version: nil, git: ProcessWorktreeGit(workingDirectory: directory)
        )

        #expect(status == (arguments.isEmpty ? 1 : 0))
        #expect(console.stdout.contains("usage: wt <command> [args]"))
        #expect(!console.stdout.contains("Current config"))
        #expect(console.stderr.isEmpty)
    }

    @Test func otherCommandsStillNeedARepository() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let console = BufferConsole()

        let status = WT.main(["list"], environment: [:], console: console, version: nil, git: ProcessWorktreeGit(workingDirectory: directory))

        #expect(status == 1)
        #expect(console.stderr == "wt: not inside a git repo\n")
    }

    @Test func currentJSONOutsideARepositoryPrintsNullsAndSucceeds() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let console = BufferConsole()

        let status = WT.main(["current", "--json"], environment: [:], console: console, version: nil, git: ProcessWorktreeGit(workingDirectory: directory))

        #expect(status == 0)
        let expected: NSDictionary = ["worktree": NSNull(), "branch": NSNull(), "path": NSNull(), "root": NSNull(), "layout": NSNull()]
        #expect(jsonObject(console.stdout) == expected)
        #expect(console.stderr.isEmpty)
    }

    @Test func currentWithoutJSONOutsideARepositoryStillFails() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let console = BufferConsole()

        let status = WT.main(["current"], environment: [:], console: console, version: nil, git: ProcessWorktreeGit(workingDirectory: directory))

        #expect(status == 1)
        #expect(console.stderr == "wt: not inside a git repo\n")
    }

    @Test func completeOutsideARepositoryPrintsNothingAndSucceeds() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let console = BufferConsole()

        let status = WT.main(["__complete", "worktrees"], environment: [:], console: console, version: nil, git: ProcessWorktreeGit(workingDirectory: directory))

        #expect(status == 0)
        #expect(console.stdout.isEmpty)
        #expect(console.stderr.isEmpty)
    }

    @Test func anUnknownSubcommandFailsNamingIt() {
        #expect(cliFailure { try WT.run(FakeWTContext(), ["bogus"]) }?.message == "unknown subcommand: bogus (try -h)")
    }

    @Test func noSubcommandFails() {
        #expect(cliFailure { try WT.run(FakeWTContext(), []) }?.code == 1)
    }

    // MARK: path

    private func pathContext() -> FakeWTContext {
        let ctx = FakeWTContext(worktrees: [wtRow("foo", "ryanm/foo", "")])
        ctx.fakeGit.entries = [
            WorktreeEntry(path: "/repo", branch: "main"),
            WorktreeEntry(path: "/repo/.plume/worktrees/foo", branch: "ryanm/foo"),
        ]
        return ctx
    }

    @Test func pathPrefersAWorktreeName() throws {
        let ctx = pathContext()
        try WT.path(ctx, ["foo"])
        #expect(ctx.buffer.stdout == "/repo/.plume/worktrees/foo\n")
    }

    @Test func pathFallsBackToACheckedOutBranch() throws {
        let ctx = pathContext()
        try WT.path(ctx, ["main"])
        #expect(ctx.buffer.stdout == "/repo\n")
    }

    @Test func pathFailsWithNoMatch() {
        #expect(cliFailure { try WT.path(pathContext(), ["nope"]) }?.message == "no worktree or checked-out branch matching: nope")
    }

    @Test func pathNeedsAName() {
        #expect(cliFailure { try WT.path(pathContext(), []) } != nil)
    }

    // MARK: completion

    @Test func completeListsWorktrees() throws {
        let ctx = FakeWTContext(worktrees: [wtRow("repo", "main", ""), wtRow("foo", "ryanm/foo", "")])
        try WT.complete(ctx, ["worktrees"])
        #expect(ctx.buffer.stdout == "repo\nfoo\n")
    }

    @Test func completeListsCheckedOutBranches() throws {
        let ctx = pathContext()
        try WT.complete(ctx, ["branches"])
        #expect(ctx.buffer.stdout == "main\nryanm/foo\n")
    }

    /// The branches `wt co` accepts: local, and not already checked out.
    @Test func completeListsCheckoutableBranches() throws {
        let ctx = pathContext()
        ctx.fakeGit.branches = ["main", "ryanm/foo", "ryanm/free"]
        try WT.complete(ctx, ["checkoutable"])
        #expect(ctx.buffer.stdout == "ryanm/free\n")
    }
}
