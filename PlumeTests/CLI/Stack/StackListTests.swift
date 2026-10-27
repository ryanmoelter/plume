import Foundation
import Testing
@testable import Plume

/// `stack list`'s graph: glyphs, connectors, column alignment, PR chips and
/// the needs-restack and behind-trunk notes, against an in-memory commit
/// graph, so a change that shifts a column or swaps a symbol fails here.
struct StackRenderTests {
    func render(
        _ git: FakeStackGit,
        _ branches: StackBranches,
        current: String?,
        prs: PullRequestMap = [:],
        state: PRState = .off,
        ui: TerminalUI = .plain,
        branchPrefix: String = "",
        forgeIcon: String? = nil,
        numberPrefix: String = "#"
    ) throws -> String {
        let ctx = stackContext(git, ui: ui, branchPrefix: branchPrefix)
        return try Stack.render(
            ctx, branches, roots: StackGraph.roots(branches), current: current,
            prs: prs, prState: state, forgeIcon: forgeIcon, numberPrefix: numberPrefix
        )
    }

    // main(m0) → feat-a (a1, a2) → feat-b (b1)
    let linearGit = FakeStackGit(
        tips: ["main": "m0", "feat-a": "a2", "feat-b": "b1"],
        ancestors: linearHistory("m0", "a1", "a2", "b1")
    )
    let linear: StackBranches = ["feat-a": entry("main", "m0"), "feat-b": entry("feat-a", "a2")]

    @Test func linearWithTheCurrentBranchAtTheTip() throws {
        #expect(try render(linearGit, linear, current: "feat-b") == """
            │ ➜ feat-b
            │ │ ↗1 commit
            │ ● feat-a
            ├─╯ ↗2 commits
            ● main
            """)
    }

    @Test func theCurrentMarkerMovesToTheRoot() throws {
        #expect(try render(linearGit, linear, current: "feat-a") == """
            │ ● feat-b
            │ │ ↗1 commit
            │ ➜ feat-a
            ├─╯ ↗2 commits
            ● main
            """)
    }

    /// Children sort alphabetically: `feat-c` continues the spine above,
    /// and `feat-b` tees off into the inner column below it.
    @Test func aForkTeesIntoTheInnerColumn() throws {
        let git = FakeStackGit(
            tips: ["main": "m0", "feat-a": "a1", "feat-b": "b1", "feat-c": "c1"],
            ancestors: ["m0": [], "a1": ["m0"], "b1": ["a1", "m0"], "c1": ["a1", "m0"]]
        )
        let branches: StackBranches = [
            "feat-a": entry("main", "m0"),
            "feat-b": entry("feat-a", "a1"),
            "feat-c": entry("feat-a", "a1"),
        ]
        #expect(try render(git, branches, current: "feat-a") == """
            │ ● feat-c
            │ │ ↗1 commit
            │ │ ● feat-b
            │ ├─╯ ↗1 commit
            │ ➜ feat-a
            ├─╯ ↗1 commit
            ● main
            """)
    }

    @Test func multipleChildrenAndNesting() throws {
        let git = FakeStackGit(
            tips: ["main": "m0", "base": "x1", "c-a": "ca", "c-b": "cb", "c-c": "cc", "leaf": "lf"],
            ancestors: [
                "m0": [], "x1": ["m0"],
                "ca": ["x1", "m0"], "cb": ["x1", "m0"], "cc": ["x1", "m0"],
                "lf": ["cc", "x1", "m0"],
            ]
        )
        let branches: StackBranches = [
            "base": entry("main", "m0"),
            "c-a": entry("base", "x1"),
            "c-b": entry("base", "x1"),
            "c-c": entry("base", "x1"),
            "leaf": entry("c-c", "cc"),
        ]
        #expect(try render(git, branches, current: "base") == """
            │ ● leaf
            │ │ ↗1 commit
            │ ● c-c
            │ │ ↗1 commit
            │ │ ● c-a
            │ ├─╯ ↗1 commit
            │ │ ● c-b
            │ ├─╯ ↗1 commit
            │ ➜ base
            ├─╯ ↗1 commit
            ● main
            """)
    }

    /// A root that forked before the trunk head renders below it, after a
    /// row counting the trunk commits between.
    @Test func aRootBelowTheTrunkHead() throws {
        let git = FakeStackGit(
            tips: ["main": "t2", "feat": "f1"],
            ancestors: ["t0": [], "t1": ["t0"], "t2": ["t1", "t0"], "f1": ["t0"]]
        )
        #expect(try render(git, ["feat": entry("main", "t0")], current: "feat") == """
            ● main
            ┆2
            │ ➜ feat
            ├─╯ ↗1 commit  ↻ behind main
            ●
            """)
    }

    /// Roots order nearest fork first, the gap rows counting from the root
    /// above, and a tie keeps alphabetical order.
    @Test func rootsBelowTheHeadOrderByForkDistance() throws {
        let git = FakeStackGit(
            tips: ["main": "t3", "near": "n1", "far": "f1", "tied": "d1"],
            ancestors: [
                "t0": [], "t1": ["t0"], "t2": ["t1", "t0"], "t3": ["t2", "t1", "t0"],
                "n1": ["t2", "t1", "t0"], "f1": ["t0"], "d1": ["t2", "t1", "t0"],
            ]
        )
        let branches: StackBranches = [
            "far": entry("main", "t0"),
            "near": entry("main", "t2"),
            "tied": entry("main", "t2"),
        ]
        #expect(try render(git, branches, current: nil) == """
            ● main
            ┆1
            │ ● near
            ├─╯ ↗1 commit  ↻ behind main
            ┆0
            │ ● tied
            ├─╯ ↗1 commit  ↻ behind main
            ┆2
            │ ● far
            ├─╯ ↗1 commit  ↻ behind main
            ●
            """)
    }

    @Test func needsRestackSitsOnTheChildsLabelRow() throws {
        // feat-a moved to a2, but feat-b still sits on a1.
        let git = FakeStackGit(
            tips: ["main": "m0", "feat-a": "a2", "feat-b": "b1"],
            ancestors: ["m0": [], "a1": ["m0"], "a2": ["a1", "m0"], "b1": ["a1", "m0"]]
        )
        let branches: StackBranches = ["feat-a": entry("main", "m0"), "feat-b": entry("feat-a", "a1")]
        let out = try render(git, branches, current: "feat-b")
        #expect(out.components(separatedBy: "\n").contains { $0.hasSuffix("↻ needs restack") && $0.contains("commit") })
    }

    /// A root behind a moved trunk is informational, never a restack.
    @Test func behindTrunkIsNotNeedsRestack() throws {
        let git = FakeStackGit(tips: ["main": "t1", "feat": "f1"], ancestors: ["t0": [], "t1": ["t0"], "f1": ["t0"]])
        let out = try render(git, ["feat": entry("main", "t0")], current: "feat")
        #expect(out.contains("↻ behind main"))
        #expect(!out.contains("needs restack"))
    }

    @Test func originAheadAndBehindRideTheCountRow() throws {
        let git = FakeStackGit(
            tips: ["main": "m0", "feat": "a1"],
            ancestors: linearHistory("m0", "a1"),
            origin: ["feat": (2, 1)]
        )
        let out = try render(git, ["feat": entry("main", "m0")], current: "feat")
        #expect(out.contains("↗1 commit ↑2 ↓1"))
        #expect(!out.contains("feat ↑"))
    }

    @Test func theBranchPrefixIsDimmedButKept() throws {
        let git = FakeStackGit(tips: ["main": "m0", "ryanm/feat": "a1", "ryanm/other": "b1"], ancestors: linearHistory("m0", "a1", "b1"))
        let branches: StackBranches = ["ryanm/feat": entry("main", "m0"), "ryanm/other": entry("ryanm/feat", "a1")]
        let ui = TerminalUI(palette: .ansi)
        let out = try render(git, branches, current: "ryanm/feat", ui: ui, branchPrefix: "ryanm/")
        #expect(out.contains("\(ANSI.dim)ryanm/\(ANSI.reset)other"))
        #expect(out.contains("\(ANSI.bold)ryanm/feat\(ANSI.reset)"))
        #expect(ANSI.strip(out).contains("ryanm/feat"))
    }

    @Test func namesAndChipsAlign() throws {
        let git = FakeStackGit(
            tips: ["main": "m0", "a": "a1", "longer-name": "b1"],
            ancestors: linearHistory("m0", "a1", "b1"),
            origin: ["a": (0, 0), "longer-name": (0, 0)]
        )
        let branches: StackBranches = ["a": entry("main", "m0"), "longer-name": entry("a", "a1")]
        let out = try render(git, branches, current: nil, prs: ["a": stackPR(7)], state: .on)
        #expect(out == """
            │ ● longer-name  –
            │ │ ↗1 commit
            │ ● a            #7 ◉
            ├─╯ ↗1 commit
            ● main
            """)
    }

    // MARK: PR column

    func oneBranch(_ pr: PullRequest?, pushed: Bool = true, ui: TerminalUI = nerdUI) throws -> String {
        let git = FakeStackGit(
            tips: ["main": "m0", "feat": "a1"],
            ancestors: linearHistory("m0", "a1"),
            origin: pushed ? ["feat": (0, 0)] : [:]
        )
        return try render(git, ["feat": entry("main", "m0")], current: "feat", prs: pr.map { ["feat": $0] } ?? [:], state: .on, ui: ui)
    }

    @Test func pushedWithNoPRShowsADimDash() throws {
        let out = try oneBranch(nil)
        #expect(out.contains("–"))
        #expect(!out.contains("(no PR)"))
    }

    @Test func localOnlyWithNoPRShowsNetOff() throws {
        let out = try oneBranch(nil, pushed: false)
        #expect(out.contains(nerdUI.netOff))
        #expect(!out.contains("(no PR)"))
    }

    @Test func theChipLeadsWithTheForgeIcon() throws {
        #expect(try oneBranch(stackPR(7)).contains("\(nerdUI.github) #7 \(TerminalUI.open)"))
    }

    @Test func chipStates() throws {
        #expect(try oneBranch(stackPR(7, state: .merged)).contains("#7 \(nerdUI.merged)"))
        #expect(try oneBranch(stackPR(7, state: .closed)).contains("#7 \(TerminalUI.closed)"))
        #expect(try oneBranch(stackPR(7, checks: [CheckContext(name: "ci", status: "SUCCESS")])).contains(nerdUI.checksPass))
        #expect(try oneBranch(stackPR(7, reviewDecision: .approved)).contains(TerminalUI.approved))
        #expect(try oneBranch(stackPR(7, reviewDecision: .changesRequested)).contains(TerminalUI.changesRequested))
        #expect(try oneBranch(stackPR(7, isDraft: true, checks: [CheckContext(name: "ci", status: "SUCCESS")]))
            .contains("\(TerminalUI.draft) \(nerdUI.checksPass)"))
    }

    @Test func anIgnoredPendingCheckDoesNotMaskSuccess() throws {
        let ignored = "ci/slow-integration-suite"
        let ui = TerminalUI(glyphSet: .nerd, ignoredPendingChecks: [ignored])
        let pr = stackPR(7, checks: [CheckContext(name: "ci", status: "SUCCESS"), CheckContext(name: ignored, status: "IN_PROGRESS")])
        let out = try oneBranch(pr, ui: ui)
        #expect(out.contains(nerdUI.checksPass))
        #expect(!out.contains(nerdUI.checksPending))
    }

    @Test func gitLabChipsUseTheIconAndBangNumber() throws {
        let git = FakeStackGit(tips: ["main": "m0", "feat": "a1"], ancestors: linearHistory("m0", "a1"), origin: ["feat": (0, 0)])
        let out = try render(
            git, ["feat": entry("main", "m0")], current: "feat", prs: ["feat": stackPR(7)], state: .on,
            ui: nerdUI, forgeIcon: nerdUI.gitlab, numberPrefix: "!"
        )
        #expect(out.contains("\(nerdUI.gitlab) !7 \(TerminalUI.open)"))
        #expect(!out.contains("#7"))
    }

    @Test func offOmitsTheChipColumnEvenWithPRs() throws {
        let git = FakeStackGit(tips: ["main": "m0", "feat": "a1"], ancestors: linearHistory("m0", "a1"))
        let out = try render(git, ["feat": entry("main", "m0")], current: "feat", prs: ["feat": stackPR(9)], state: .off)
        #expect(!out.contains("#9"))
        #expect(!out.contains("(no PR)"))
    }

    // MARK: Forge unreachable

    func twoBranches(state: PRState, ui: TerminalUI = nerdUI) throws -> String {
        let git = FakeStackGit(tips: ["main": "m0", "feat-a": "a1", "feat-b": "a2"], ancestors: linearHistory("m0", "a1", "a2"))
        let branches: StackBranches = ["feat-a": entry("main", "m0"), "feat-b": entry("feat-a", "a1")]
        return try render(git, branches, current: "feat-b", state: state, ui: ui)
    }

    @Test func aFailedFetchShowsNetOffOnEveryNode() throws {
        let out = try twoBranches(state: .error)
        #expect(out.components(separatedBy: nerdUI.netOff).count - 1 == 2)
        #expect(out.contains("\(nerdUI.github) \(nerdUI.netOff)"))
        #expect(!out.contains("(no PR)"))
    }

    @Test func aFailedFetchIsRed() throws {
        #expect(try twoBranches(state: .error, ui: TerminalUI(palette: .ansi, glyphSet: .nerd)).contains(ANSI.red))
    }

    @Test func loadingIsADimEllipsis() throws {
        let out = try twoBranches(state: .loading, ui: TerminalUI(palette: .ansi, glyphSet: .nerd))
        #expect(out.contains(TerminalUI.loading))
        #expect(!out.contains(nerdUI.netOff))
        #expect(out.contains(ANSI.dim))
        #expect(!out.contains(ANSI.red))
    }

    @Test func aTimedOutFetchIsDimNotRed() throws {
        let out = try twoBranches(state: .wait, ui: TerminalUI(palette: .ansi, glyphSet: .nerd))
        #expect(out.contains(nerdUI.netOff))
        #expect(!out.contains(ANSI.red))
    }

    // MARK: GitHub stacks

    func githubStack(_ prs: PullRequestMap, ui: TerminalUI = nerdUI) throws -> String {
        let git = FakeStackGit(
            tips: ["main": "m0", "feat-a": "a2", "feat-b": "b1"],
            ancestors: linearHistory("m0", "a1", "a2", "b1"),
            origin: ["feat-a": (0, 0), "feat-b": (0, 0)]
        )
        return try render(git, linear, current: "feat-b", prs: prs, state: .on, ui: ui)
    }

    @Test func theChipShowsTheStackNumber() throws {
        let out = try githubStack([
            "feat-a": stackPR(1, githubStack: GitHubStackMembership(number: 58215, size: 2, position: 1)),
            "feat-b": stackPR(2, githubStack: GitHubStackMembership(number: 58215, size: 2, position: 2)),
        ])
        #expect(out.contains("\u{F51E}58215"))
    }

    @Test func thePlainGlyphSetMarksAStackToo() throws {
        let out = try githubStack(["feat-a": stackPR(1, githubStack: GitHubStackMembership(number: 5, size: 1, position: 1))], ui: .plain)
        #expect(out.contains("≡5"))
    }

    @Test func noMarkerOutsideAStack() throws {
        #expect(!(try githubStack(["feat-a": stackPR(1), "feat-b": stackPR(2)])).contains("\u{F51E}"))
    }

    @Test func driftShowsOnTheCountRow() throws {
        let out = try githubStack([
            "feat-a": stackPR(1, githubStack: GitHubStackMembership(number: 5, size: 1, position: 1)),
            "feat-b": stackPR(2, githubStack: GitHubStackMembership(number: 9, size: 1, position: 1)),
        ])
        #expect(out.contains("│ │ ↗1 commit  \u{F51E} in stack #9, parent in #5"))
    }
}

/// The pure decisions behind the graph and the GitHub stack sync.
struct StackGraphTests {
    let scoped: StackBranches = [
        "a": entry("main", "m0"),
        "b": entry("a", "a1"),
        "c": entry("a", "a1"),
        "d": entry("b", "b1"),
    ]

    /// `path` scopes restack and sync to the current branch and its
    /// ancestors, leaving out the siblings and descendants that usually live
    /// in other worktrees.
    @Test func pathIsTheAncestorsParentsFirst() {
        #expect(StackGraph.path(scoped, to: "b") == ["a", "b"])
        #expect(StackGraph.path(scoped, to: "d") == ["a", "b", "d"])
        #expect(StackGraph.path(scoped, to: "a") == ["a"])
    }

    @Test func subtreeCoversTheWholeTreeBreadthFirst() {
        #expect(StackGraph.subtree(scoped, of: "a") == ["a", "b", "c", "d"])
    }

    @Test func graphBasics() {
        #expect(StackGraph.roots(scoped) == ["a"])
        #expect(StackGraph.children(scoped, of: "a") == ["b", "c"])
        #expect(StackGraph.root(scoped, of: "d") == "a")
        #expect(StackGraph.depths(scoped) == ["a": 1, "b": 2, "c": 2, "d": 3])
        #expect(StackGraph.topologicalOrder(scoped) == ["a", "b", "c", "d"])
        #expect(StackGraph.stack(scoped, of: "c") == scoped)
        #expect(StackGraph.parentIsTrunk(scoped, "a"))
        #expect(!StackGraph.parentIsTrunk(scoped, "b"))
    }

    let pair: StackBranches = ["a": entry("main", "m0"), "b": entry("a", "a1")]

    func membership(_ number: Int, _ position: Int) -> GitHubStackMembership {
        GitHubStackMembership(number: number, size: 2, position: position)
    }

    @Test func driftNeedsADisagreement() {
        #expect(StackGraph.githubStackDrift(pair, ["a": stackPR(1, githubStack: membership(5, 1)), "b": stackPR(2, githubStack: membership(5, 2))]).isEmpty)
        #expect(StackGraph.githubStackDrift(pair, ["a": stackPR(1, githubStack: membership(5, 1)), "b": stackPR(2, githubStack: membership(9, 1))])
            == ["b": "in stack #9, parent in #5"])
        #expect(StackGraph.githubStackDrift(pair, ["a": stackPR(1, githubStack: membership(5, 2)), "b": stackPR(2, githubStack: membership(5, 1))])
            == ["b": "ordered below its parent in stack #5"])
        // Only part of a chain being registered is normal.
        #expect(StackGraph.githubStackDrift(pair, ["a": stackPR(1), "b": stackPR(2, githubStack: membership(5, 1))]).isEmpty)
        #expect(StackGraph.githubStackDrift(pair, ["a": stackPR(1), "b": stackPR(2)]).isEmpty)
    }

    @Test func planStackUpdate() {
        #expect(StackGraph.planStackUpdate(existing: [], desired: [1, 2]) == .create([1, 2]))
        #expect(StackGraph.planStackUpdate(existing: [], desired: [1]) == .noop)
        #expect(StackGraph.planStackUpdate(existing: [1, 2], desired: [1, 2]) == .noop)
        #expect(StackGraph.planStackUpdate(existing: [1, 2], desired: [1, 2, 3]) == .add([3]))
        // GitHub keeps merged PRs in a stack, so a partly landed chain is
        // still a prefix.
        #expect(StackGraph.planStackUpdate(existing: [1, 2], desired: [1, 2, 3, 4]) == .add([3, 4]))
        #expect(StackGraph.planStackUpdate(existing: [1, 2], desired: [2, 1]) == .drift("GitHub has [1, 2], local chain is [2, 1]"))
        if case .drift = StackGraph.planStackUpdate(existing: [1, 2, 3], desired: [1, 3]) {} else { Issue.record("removal is drift") }
        if case .drift = StackGraph.planStackUpdate(existing: [1, 2], desired: [1, 9, 3]) {} else { Issue.record("divergent prefix is drift") }
    }
}

/// Registering a submitted chain as a GitHub native stack.
struct StackSyncGitHubStackTests {
    let console = BufferConsole()
    var ctx: StackContext {
        stackContext(FakeStackGit(tips: [:], ancestors: [:]), console: console)
    }

    let order = ["a", "b"]
    let prs: PullRequestMap = ["a": stackPR(10), "b": stackPR(11)]

    @Test func createsWhenNoStackExists() {
        let stacks = FakeNativeStacks()
        Stack.syncGitHubStack(ctx, stacks, order: order, prs: prs, dryRun: false)
        #expect(stacks.created == [[10, 11]])
        #expect(console.stdout == "  registered GitHub stack #77\n")
    }

    @Test func aDryRunSendsNothing() {
        let stacks = FakeNativeStacks()
        Stack.syncGitHubStack(ctx, stacks, order: order, prs: prs, dryRun: true)
        #expect(stacks.created.isEmpty)
        #expect(stacks.added.isEmpty)
        #expect(console.stdout == "  would register GitHub stack for 2 PRs\n")
    }

    @Test func appendsOnlyTheNewTip() {
        let stacks = FakeNativeStacks(existing: GitHubNativeStack(number: 5, pullRequestNumbers: [10]))
        Stack.syncGitHubStack(ctx, stacks, order: ["a", "b", "c"], prs: ["a": stackPR(10), "b": stackPR(11), "c": stackPR(12)], dryRun: false)
        #expect(stacks.added.map(\.stack) == [5])
        #expect(stacks.added.map(\.pullRequests) == [[11, 12]])
        #expect(stacks.created.isEmpty)
    }

    @Test func aSinglePRChainIsLeftAlone() {
        let stacks = FakeNativeStacks()
        Stack.syncGitHubStack(ctx, stacks, order: ["a"], prs: ["a": stackPR(10)], dryRun: false)
        #expect(stacks.created.isEmpty)
    }

    @Test func driftIsNeverDestructive() {
        let stacks = FakeNativeStacks(existing: GitHubNativeStack(number: 5, pullRequestNumbers: [11, 10]))
        Stack.syncGitHubStack(ctx, stacks, order: order, prs: prs, dryRun: false)
        #expect(stacks.created.isEmpty)
        #expect(stacks.added.isEmpty)
        #expect(console.stderr.contains("GitHub stack #5 doesn't match this chain"))
    }

    @Test func aFailedCreateMarksTheFeatureUnavailable() {
        let stacks = FakeNativeStacks(createSucceeds: false)
        Stack.syncGitHubStack(ctx, stacks, order: order, prs: prs, dryRun: false)
        #expect(stacks.markedUnavailable)
        #expect(console.stderr == "stack: could not update the GitHub stack (PRs are unaffected)\n")
    }

    @Test func branchesWithoutPRsAreSkipped() {
        let stacks = FakeNativeStacks()
        Stack.syncGitHubStack(ctx, stacks, order: ["a", "b", "c"], prs: ["a": stackPR(10), "c": stackPR(12)], dryRun: false)
        #expect(stacks.created == [[10, 12]])
    }
}

/// The two-frame print: the graph paints before the forge answers, then the
/// PR column redraws in place.
struct StackPrintLiveTests {
    let git = FakeStackGit(tips: ["main": "m0", "feat": "a1"], ancestors: linearHistory("m0", "a1"))
    let branches: StackBranches = ["feat": entry("main", "m0")]
    let console = BufferConsole()
    let cursorUp = "\u{1B}["

    var ctx: StackContext { stackContext(git, console: console, ui: nerdUI) }

    func graph(_ state: PRState, _ prs: PullRequestMap = [:]) throws -> String {
        try Stack.render(ctx, branches, roots: ["feat"], current: "feat", prs: prs, prState: state, forgeIcon: nerdUI.github, numberPrefix: "#")
    }

    func printLive(_ fetch: (any PRFetchCompletion)?, live: Bool = true) throws -> String {
        try Stack.printLive(ctx, branches, roots: ["feat"], current: "feat", fetch: fetch, forgeIcon: nerdUI.github, numberPrefix: "#", live: live)
        return console.stdout
    }

    @Test func noForgePrintsTheGraphOnce() throws {
        let out = try printLive(nil)
        #expect(out == (try graph(.off)) + "\n")
        #expect(!out.contains(cursorUp))
    }

    @Test func aTerminalPrintsLoadingThenRedrawsResolved() throws {
        let fetch = ScriptedFetchCompletion(true, result: [:])
        let out = try printLive(fetch)
        let loading = try graph(.loading)
        let lines = loading.components(separatedBy: "\n").count
        #expect(out == "\(loading)\n\(TerminalUI.redrawPrefix(lines: lines))\(try graph(.on))\n")
        #expect(fetch.waits == [Stack.listPRBudget])
    }

    @Test func aFailedFetchRedrawsTheErrorState() throws {
        #expect(try printLive(ScriptedFetchCompletion(true, result: nil)).hasSuffix((try graph(.error)) + "\n"))
    }

    @Test func aFetchThatNeverLandsEndsInWait() throws {
        let out = try printLive(ScriptedFetchCompletion(false, result: nil))
        #expect(out.hasSuffix((try graph(.wait)) + "\n"))
        #expect(out.contains(cursorUp))
    }

    @Test func offATerminalPrintsOnceWithNoCursorCodes() throws {
        let out = try printLive(ScriptedFetchCompletion(true, result: [:]), live: false)
        #expect(out == (try graph(.on)) + "\n")
        #expect(!out.contains(cursorUp))
    }

    /// The blocking collector the mutating commands use degrades to "no PR
    /// here" rather than stopping a half-done submit.
    @Test func collectPRsDegradesToNone() {
        #expect(Stack.collectPRs(ScriptedFetchCompletion(true, result: ["a": stackPR(1)])) == ["a": stackPR(1)])
        #expect(Stack.collectPRs(ScriptedFetchCompletion(true, result: nil)).isEmpty)
        let timedOut = ScriptedFetchCompletion(false, result: ["a": stackPR(1)])
        #expect(Stack.collectPRs(timedOut).isEmpty)
        #expect(timedOut.waits == [Stack.blockingPRBudget])
    }
}

/// `stack list` end to end over a state file, including the `--json` shape
/// agents read.
struct StackListCommandTests {
    let directory: String
    let console = BufferConsole()
    let git = FakeStackGit(
        tips: ["main": "m0", "a": "a1", "b": "b1"],
        ancestors: linearHistory("m0", "a1", "b1"),
        current: "b"
    )

    init() throws {
        directory = try makeScratchDirectory() + "/stack"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try StackStateCodec.encode(["a": entry("main", "m0"), "b": entry("a", "a1")])
            .write(toFile: "\(directory)/branches.json", atomically: true, encoding: .utf8)
    }

    func ctx(forge: (any StackForge)? = nil) -> StackContext {
        stackContext(git, console: console, stateDirectory: directory, forge: forge)
    }

    @Test func printsTheCurrentStack() throws {
        try Stack.list(ctx(), ["--no-pr"])
        #expect(console.stdout == """
            │ ➜ b
            │ │ ↗1 commit
            │ ● a
            ├─╯ ↗1 commit
            ● main

            """)
    }

    @Test func jsonMatchesTheDocumentedShape() throws {
        let forge = RecordingStackForge([
            "a": stackPR(4, base: "main", githubStack: GitHubStackMembership(number: 3, size: 2, position: 1)),
        ])
        try Stack.list(ctx(forge: forge), ["--json"])
        #expect(console.stdout == """
            {
              "trunk": "main",
              "current": "b",
              "branches": [
                {
                  "name": "a",
                  "parent": "main",
                  "depth": 1,
                  "current": false,
                  "needs_restack": false,
                  "behind_trunk": false,
                  "pr": {
                    "number": 4,
                    "state": "OPEN",
                    "is_draft": false,
                    "base": "main",
                    "url": "u"
                  },
                  "github_stack": {
                    "number": 3,
                    "size": 2,
                    "position": 1
                  }
                },
                {
                  "name": "b",
                  "parent": "a",
                  "depth": 2,
                  "current": true,
                  "needs_restack": false,
                  "behind_trunk": false,
                  "pr": null,
                  "github_stack": null
                }
              ]
            }

            """)
    }

    @Test func unknownArgumentsFail() {
        #expect(stackFailure { try Stack.list(ctx(), ["--bogus"]) }?.message == "unknown argument: --bogus")
    }

    @Test func noStateFails() throws {
        try FileManager.default.removeItem(atPath: "\(directory)/branches.json")
        #expect(stackFailure { try Stack.list(ctx(), []) }?.message == "no stacks tracked yet — `stack create <name>` or `stack track`")
    }

    @Test func offAStackWithSeveralRootsFails() throws {
        try StackStateCodec.encode(["a": entry("main", "m0"), "b": entry("main", "m0")])
            .write(toFile: "\(directory)/branches.json", atomically: true, encoding: .utf8)
        git.current = "main"
        #expect(stackFailure { try Stack.list(ctx(), ["--no-pr"]) }?.message == "current branch is not in a stack — try `stack list --all`")
        try Stack.list(ctx(), ["--all", "--no-pr"])
        #expect(console.stdout.contains("● a"))
        #expect(console.stdout.contains("● b"))
    }
}
