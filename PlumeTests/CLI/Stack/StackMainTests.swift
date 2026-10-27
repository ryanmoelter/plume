import Foundation
import Testing
@testable import Plume

/// Records `settings.open` for `stack setup`.
nonisolated final class SettingsRecordingApp: PlumeAppClient {
    let opens: Bool
    private(set) var sections: [String?] = []

    init(opens: Bool) {
        self.opens = opens
    }

    func openTab(directory: String, caller: PlumeCaller) -> Bool { false }
    func openTask(worktreePath: String, caller: PlumeCaller) -> Bool { false }

    func openSettings(section: String?) -> Bool {
        sections.append(section)
        return opens
    }
}

/// The entry point: what answers without a repository, and the order of
/// its refusals.
struct StackMainTests {
    let outside: String
    let console = BufferConsole()

    init() throws {
        outside = try makeScratchDirectory()
    }

    func main(_ arguments: [String], in directory: String? = nil) -> Int32 {
        Stack.main(
            arguments,
            environment: [:],
            console: console,
            version: "1.2.3",
            workingDirectory: directory ?? outside,
            settingsSource: StaticSettingsSource()
        )
    }

    @Test func versionPrintsTheProgramName() {
        #expect(main(["--version"]) == CLIExitCode.success)
        #expect(console.stdout == "stack 1.2.3\n")
    }

    @Test func helpWorksOutsideARepository() {
        #expect(main(["help"]) == CLIExitCode.success)
        #expect(console.stdout.contains("stack create <name>"))
        #expect(!console.stdout.contains("Current config"))
    }

    @Test func noArgumentsPrintsTheHelp() {
        #expect(main([]) == CLIExitCode.success)
        #expect(console.stdout.contains("stack restack"))
    }

    /// Checked before the repository is, so a typo isn't blamed on the
    /// directory.
    @Test func anUnknownCommandIsNamed() {
        #expect(main(["bogus"]) == CLIExitCode.failure)
        #expect(console.stderr == "stack: unknown command: bogus (see `stack help`)\n")
    }

    @Test func aKnownCommandOutsideARepositoryFails() {
        #expect(main(["list"]) == CLIExitCode.failure)
        #expect(console.stderr == "stack: not inside a git repo\n")
    }

    @Test func completionOutsideARepositoryIsSilent() {
        #expect(main(["__complete", "stack-branches"]) == CLIExitCode.success)
        #expect(console.stdout.isEmpty)
        #expect(console.stderr.isEmpty)
    }

    @Test func initPointsAtPlume() {
        #expect(main(["init", "zsh"]) == CLIExitCode.failure)
        #expect(console.stderr == "stack: shell integration moved to plume: eval \"$(plume init zsh)\"\n")
    }

    @Test func helpInsideARepositoryShowsTheResolvedConfig() throws {
        let repo = try StackScratchRepo()
        #expect(main(["help"], in: repo.work) == CLIExitCode.success)
        #expect(console.stdout.contains("Current config"))
    }

    @Test func listRunsInsideARepository() throws {
        let repo = try StackScratchRepo()
        #expect(main(["list"], in: repo.work) == CLIExitCode.failure)
        #expect(console.stderr == "stack: no stacks tracked yet — `stack create <name>` or `stack track`\n")
    }
}

/// The commands that shape the stack: create, track, untrack, split.
struct StackShapeTests {
    let repo: StackScratchRepo
    let console = BufferConsole()

    init() throws {
        repo = try StackScratchRepo()
        try repo.commit("trunk-one")
        try repo.pushTrunk()
    }

    func ctx(branchPrefix: String = "", app: (any PlumeAppClient)? = nil) -> StackContext {
        StackContext(
            git: ProcessStackGit(workingDirectory: repo.work),
            console: console,
            trunk: "main",
            branchPrefix: branchPrefix,
            stateDirectory: repo.stateDirectory,
            app: app
        )
    }

    func current() throws -> String {
        try repo.git("symbolic-ref", "--short", "HEAD")
    }

    @Test func createStacksOnTheCurrentBranch() throws {
        try Stack.create(ctx(), ["a"])
        try repo.commit("a-one")
        try Stack.create(ctx(), ["b"])
        #expect(try current() == "b")
        let state = try repo.loadState()
        #expect(state["a"]?.parent == "main")
        #expect(state["b"] == entry("a", try repo.rev("a")))
        #expect(console.stdout == "created 'a' on 'main'\ncreated 'b' on 'a'\n")
    }

    @Test func createAppliesThePrefixOnce() throws {
        try Stack.create(ctx(branchPrefix: "me/"), ["a"])
        try Stack.create(ctx(branchPrefix: "me/"), ["me/b"])
        #expect(Set(try repo.loadState().keys) == ["me/a", "me/b"])
    }

    @Test func createInsertMovesTheChildren() throws {
        try Stack.create(ctx(), ["a"])
        try repo.commit("a-one")
        try Stack.create(ctx(), ["b"])
        try repo.git("switch", "-q", "a")
        try Stack.create(ctx(), ["mid", "--insert"])
        let state = try repo.loadState()
        #expect(state["mid"]?.parent == "a")
        #expect(state["b"]?.parent == "mid")
        #expect(console.stdout.hasSuffix("created 'mid' on 'a' (children moved onto it)\n"))
    }

    @Test func createRefusals() throws {
        #expect(stackFailure { try Stack.create(ctx(), []) }?.message == "usage: stack create <name> [--insert]")
        #expect(stackFailure { try Stack.create(ctx(), ["a", "b"]) }?.message == "too many arguments (usage: stack create <name> [--insert])")
        #expect(stackFailure { try Stack.create(ctx(), ["--bogus"]) }?.message == "unknown flag: --bogus")
        #expect(stackFailure { try Stack.create(ctx(), ["main"]) }?.message == "branch 'main' already exists — `stack track main` to track it")
        #expect(stackFailure { try Stack.create(ctx(), ["x", "--insert"]) }?.message == "--insert requires the current branch to be in a stack")
        try repo.git("switch", "-qc", "loose")
        #expect(stackFailure { try Stack.create(ctx(), ["x"]) }?.message == "'loose' is not in a stack — run `stack track` first")
    }

    /// Every branch between the trunk and the named one joins, in order.
    @Test func trackFindsTheChain() throws {
        try repo.git("switch", "-qc", "a")
        try repo.commit("a-one")
        try repo.git("switch", "-qc", "b")
        try repo.commit("b-one")
        try Stack.track(ctx(), [])
        let state = try repo.loadState()
        #expect(state["a"] == entry("main", try repo.rev("main")))
        #expect(state["b"] == entry("a", try repo.rev("a")))
        #expect(console.stdout == "tracking: a (parent: main), b (parent: a)\n")
    }

    @Test func trackAnAlreadyTrackedBranchSaysSo() throws {
        try Stack.create(ctx(), ["a"])
        try Stack.track(ctx(), [])
        #expect(console.stdout.hasSuffix("'a' is already tracked (parent: main) — use --parent to move it\n"))
    }

    @Test func trackWithAParentMovesTheBranch() throws {
        try Stack.create(ctx(), ["a"])
        try repo.commit("a-one")
        try repo.git("switch", "-q", "main")
        try Stack.create(ctx(), ["b"])
        try Stack.track(ctx(), ["b", "--parent", "a"])
        #expect(try repo.loadState()["b"]?.parent == "a")
        #expect(console.stdout.hasSuffix("tracking 'b' (parent: a)\n"))
        #expect(stackFailure { try Stack.track(ctx(), ["a", "--parent", "b"]) }?.message
            == "'b' is stacked on top of 'a' — that would be a cycle")
    }

    @Test func trackRefusals() throws {
        #expect(stackFailure { try Stack.track(ctx(), ["main"]) }?.message == "'main' is the trunk — it can't be part of a stack")
        #expect(stackFailure { try Stack.track(ctx(), ["nope"]) }?.message == "no local branch 'nope'")
        #expect(stackFailure { try Stack.track(ctx(), ["--parent"]) }?.message == "--parent needs a value")
        try repo.git("switch", "-qc", "a")
        #expect(stackFailure { try Stack.track(ctx(), ["--parent", "a"]) }?.message == "a branch cannot be its own parent")
    }

    @Test func untrackReparentsTheChildren() throws {
        try Stack.create(ctx(), ["a"])
        try repo.commit("a-one")
        let aTip = try repo.rev("a")
        try Stack.create(ctx(), ["b"])
        try Stack.untrack(ctx(), ["a"])
        #expect(try repo.loadState() == ["b": entry("main", aTip)])
        #expect(try repo.localBranches().contains("a"))
        #expect(console.stdout.hasSuffix("untracked 'a' (git branch left intact)\n"))
        try Stack.untrack(ctx(), ["a"])
        #expect(console.stdout.hasSuffix("'a' is not tracked — nothing to do\n"))
    }

    @Test func splitCutsTheBranchAtTheNamedCommits() throws {
        try Stack.create(ctx(), ["feat"])
        let one = try repo.commit("one")
        let two = try repo.commit("two")
        try repo.commit("three")
        try Stack.split(ctx(), ["first:\(one)", "second:\(two)"])
        let state = try repo.loadState()
        let base = try repo.rev("main")
        #expect(state["first"] == entry("main", base))
        #expect(state["second"] == entry("first", one))
        #expect(state["feat"] == entry("second", two))
        #expect(try repo.rev("first") == one)
        #expect(try repo.rev("second") == two)
        #expect(console.stdout.contains("split 'feat' into: first, second ← feat\n"))
    }

    @Test func splitRefusals() throws {
        try Stack.create(ctx(), ["feat"])
        let one = try repo.commit("one")
        let two = try repo.commit("two")
        #expect(stackFailure { try Stack.split(ctx(), ["first"]) }?.message == "expected <name>:<commit>, got 'first'")
        #expect(stackFailure { try Stack.split(ctx(), ["first:\(two)"]) }?.message
            == "\(two) is the branch tip — the current branch keeps the last commits")
        #expect(stackFailure { try Stack.split(ctx(), ["first:main"]) }?.message
            == "main (\(try repo.rev("main").prefix(12))) is not one of this branch's own commits")
        #expect(stackFailure { try Stack.split(ctx(), ["a:\(one)", "b:\(one)"]) }?.message
            == "boundaries must be in ascending (oldest-first) order and distinct")
    }

    @Test func splitNeedsTwoCommits() throws {
        try Stack.create(ctx(), ["feat"])
        try repo.commit("one")
        #expect(stackFailure { try Stack.split(ctx(), ["x:HEAD"]) }?.message == "'feat' has 1 commit(s) on 'main' — nothing to split")
    }

    @Test func setupOpensSettingsWhenPlumeRuns() throws {
        let app = SettingsRecordingApp(opens: true)
        try Stack.setup(ctx(app: app), [])
        #expect(app.sections == ["projects"])
        #expect(console.stdout == "stack: opened Plume's Settings ▸ Projects\n")
    }

    @Test func setupSaysWhereSettingsLiveOtherwise() throws {
        try Stack.setup(ctx(app: SettingsRecordingApp(opens: false)), [])
        #expect(console.stdout.contains("Settings ▸ Projects"))
        #expect(stackFailure { try Stack.setup(ctx(), ["x"]) }?.message == "setup takes no arguments")
    }

    @Test func completeListsCommandsAndBranches() throws {
        try Stack.create(ctx(), ["a"])
        try repo.git("switch", "-qc", "loose", "main")
        let commands = BufferConsole()
        try Stack.complete(StackContext(git: ProcessStackGit(workingDirectory: repo.work), console: commands, stateDirectory: repo.stateDirectory), ["commands"])
        #expect(commands.stdout == Stack.commands.joined(separator: "\n") + "\n")
        let all = BufferConsole()
        try Stack.complete(StackContext(git: ProcessStackGit(workingDirectory: repo.work), console: all, stateDirectory: repo.stateDirectory), ["all-branches"])
        #expect(all.stdout == "a\nloose\nmain\n")
    }
}

/// prev, next, first, last and checkout over main ← a ← b, plus a second
/// child of `a` when a test needs a fork.
struct StackNavigationTests {
    let repo: StackScratchRepo
    let console = BufferConsole()

    init() throws {
        repo = try StackScratchRepo()
        try repo.pushTrunk()
        let ctx = self.ctx
        try Stack.create(ctx, ["a"])
        try repo.commit("a-one")
        try Stack.create(ctx, ["b"])
        try repo.commit("b-one")
    }

    var ctx: StackContext {
        StackContext(git: ProcessStackGit(workingDirectory: repo.work), console: console, stateDirectory: repo.stateDirectory)
    }

    func current() throws -> String {
        try repo.git("symbolic-ref", "--short", "HEAD")
    }

    func go(_ which: StackNavigation) throws -> String {
        try Stack.navigate(ctx, which, [])
        return try current()
    }

    @Test func walksTheChain() throws {
        #expect(try go(.prev) == "a")
        #expect(try go(.prev) == "main")
        #expect(try go(.next) == "a")
        #expect(try go(.last) == "b")
        #expect(try go(.first) == "a")
    }

    @Test func refusals() throws {
        #expect(stackFailure { try Stack.navigate(ctx, .next, []) }?.message == "'b' has no child — it's the tip")
        #expect(stackFailure { try Stack.navigate(ctx, .next, ["x"]) }?.message == "stack next takes no arguments")
        try repo.git("switch", "-q", "main")
        #expect(stackFailure { try Stack.navigate(ctx, .prev, []) }?.message == "'main' is not in a stack")
    }

    @Test func aForkAsksWhichChild() throws {
        try repo.git("switch", "-q", "a")
        try Stack.create(ctx, ["c"])
        try repo.git("switch", "-q", "a")
        #expect(stackFailure { try Stack.navigate(ctx, .next, []) }?.message == "multiple children: b, c — use `stack co <branch>`")
        #expect(stackFailure { try Stack.navigate(ctx, .last, []) }?.message == "multiple tips: b, c — use `stack co <branch>`")
    }

    @Test func checkoutByName() throws {
        try Stack.checkout(ctx, ["a"])
        #expect(try current() == "a")
        #expect(stackFailure { try Stack.checkout(ctx, ["nope"]) }?.message == "no local branch 'nope'")
    }

    /// Without a terminal the picker lists the candidates so a script can
    /// pass one.
    @Test func checkoutWithoutATerminalListsTheCandidates() throws {
        #expect(stackFailure { try Stack.checkout(ctx, []) }?.message == "no TTY — pass the branch as an argument. Candidates:\n  a\n  b")
    }

    @Test func checkoutPicksFromANumberedPrompt() throws {
        let console = BufferConsole(replies: ["1"], stdoutIsTerminal: true, stdinIsTerminal: true)
        let ctx = StackContext(git: ProcessStackGit(workingDirectory: repo.work), console: console, stateDirectory: repo.stateDirectory)
        try Stack.checkout(ctx, [])
        #expect(try current() == "a")
        #expect(console.stdout.hasPrefix("pick a branch:\n   1) a\n   2)   b  ← current\n"))
    }
}
