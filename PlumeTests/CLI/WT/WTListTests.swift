import Foundation
import Testing
@testable import Plume

/// `wt list`: the exact table text (column alignment, the `→` marker, the
/// `↗ ↑ ↓ +` cluster, detached rows, the PR column in each state), its
/// `--json` twin, the two-frame live print, and the row and cluster helpers.
/// Ported from `test_wt_list.py`.
struct WTListTests {
    private let rows = WTFixtures.rows
    private let gh = WTFixtures.githubIcon
    private let netOff = "∅"
    private let loading = "…"
    private let notConnected = "not connected"
    private let ansi = TerminalUI(palette: .ansi)

    private func render(
        rows: [WorktreeRow]? = nil,
        cwd: String? = "dotfiles",
        _ state: PRState,
        _ prs: PullRequestMap = [:],
        prefix: String = "#",
        icon: String? = nil,
        trunk: Set<String> = [],
        dirs: [String]? = nil,
        ui: TerminalUI = .plain
    ) -> String {
        WT.renderList(
            rows ?? self.rows, cwdName: cwd, prState: state, prs: prs, numberPrefix: prefix,
            forgeIcon: icon, trunkBranches: trunk, dirs: dirs, ui: ui
        )
    }

    // MARK: render

    @Test func offStateOmitsThePRColumn() {
        #expect(render(.off) == [
            "→ dotfiles  main  ↗4 ↑2 ↓1 +   ",
            "  scratch   ryanm/scratch      ",
            "  det       abc123 (detached)  ",
        ].joined(separator: "\n"))
    }

    @Test func pathsColumnAppendsEachDirectory() {
        let dirs = [".", ".plume/worktrees", "/elsewhere"]
        #expect(render(.off, dirs: dirs) == [
            "→ dotfiles  main  ↗4 ↑2 ↓1 +  .",
            "  scratch   ryanm/scratch  .plume/worktrees",
            "  det       abc123 (detached)  /elsewhere",
        ].joined(separator: "\n"))
    }

    @Test func noPathsColumnByDefault() {
        #expect(!render(.off).contains(".plume/worktrees"))
    }

    @Test(arguments: [PRState.wait, .error])
    func anUnreachableForgeShowsTheNetOffChip(_ state: PRState) {
        #expect(render(state, icon: gh) == [
            "→ dotfiles  main  ↗4 ↑2 ↓1 +   \(gh) \(netOff) \(notConnected)",
            "  scratch   ryanm/scratch      \(gh) \(netOff) \(notConnected)",
            "  det       abc123 (detached)  \(netOff)",
        ].joined(separator: "\n"))
    }

    @Test func loadingStateShowsTheLoadingChip() {
        #expect(render(.loading, icon: gh) == [
            "→ dotfiles  main  ↗4 ↑2 ↓1 +   \(gh) \(loading)",
            "  scratch   ryanm/scratch      \(gh) \(loading)",
            "  det       abc123 (detached)  \(netOff)",
        ].joined(separator: "\n"))
    }

    /// No upstream means the forge can't have a PR for it, so the fetch's
    /// state is irrelevant.
    @Test(arguments: [PRState.on, .loading, .wait, .error])
    func aLocalOnlyBranchRendersLocalInEveryState(_ state: PRState) {
        let solo = [wtRow("solo", "ryanm/solo", "2", hasUpstream: false)]
        #expect(render(rows: solo, cwd: nil, state, icon: gh) == "  solo  ryanm/solo  ↗2  \(netOff)")
    }

    @Test func aPushedBranchStillReflectsTheFetchState() {
        let solo = [wtRow("solo", "ryanm/solo", "2")]
        #expect(render(rows: solo, cwd: nil, .loading, icon: gh) == "  solo  ryanm/solo  ↗2  \(gh) \(loading)")
    }

    /// A fetch that times out redraws loading → wait, so the two must differ
    /// or the redraw is invisible.
    @Test func theLoadingChipDiffersFromTheWaitChip() {
        #expect(render(.loading, icon: gh) != render(.wait, icon: gh))
    }

    @Test func onlyErrorIsRedWhileWaitAndLoadingAreDim() {
        let error = render(.error, icon: gh, ui: ansi)
        let wait = render(.wait, icon: gh, ui: ansi)
        let loading = render(.loading, icon: gh, ui: ansi)
        #expect(error.contains(ANSI.red))
        #expect(!wait.contains(ANSI.red))
        #expect(wait.contains(ANSI.dim))
        #expect(!loading.contains(ANSI.red))
        #expect(loading.contains(ANSI.dim))
    }

    @Test func onStateChipsLeadWithTheForgeIcon() {
        #expect(render(.on, ["main": WTFixtures.openPR], icon: gh) == [
            "→ dotfiles  main  ↗4 ↑2 ↓1 +   \(gh) #7 ◉",
            "  scratch   ryanm/scratch      \(gh) –",
            "  det       abc123 (detached)  \(netOff)",
        ].joined(separator: "\n"))
    }

    @Test func gitlabUsesItsNumberPrefix() {
        let gl = WTFixtures.gitlabIcon
        let out = render(.on, ["main": WTFixtures.openPR], prefix: "!", icon: gl)
        #expect(out.contains("\(gl) !7 ◉"))
        #expect(!out.contains("#7"))
    }

    @Test func aTrunkBranchRendersAsNoPR() throws {
        let out = render(.on, ["main": WTFixtures.closedPR], icon: gh, trunk: ["main"])
        let lines = out.components(separatedBy: "\n")
        try #require(lines.count == 3)
        #expect(lines[0].contains("\(gh) –"))
        #expect(!out.contains("#3"))
    }

    @Test func aTrunkBranchWithoutUpstreamFallsBackToNetOff() {
        let trunk = [wtRow("dotfiles", "main", "", hasUpstream: false)]
        let out = render(rows: trunk, cwd: nil, .on, ["main": WTFixtures.closedPR], icon: gh, trunk: ["main"])
        #expect(out == "  dotfiles  main  \(netOff)")
    }

    @Test func aNonTrunkBranchKeepsItsClosedChip() throws {
        let out = render(.on, ["ryanm/scratch": WTFixtures.closedPR], icon: gh, trunk: ["main"])
        let lines = out.components(separatedBy: "\n")
        try #require(lines.count == 3)
        #expect(lines[1].contains("\(gh) #3 ⊘"))
    }

    @Test func everyTrunkBranchIsSuppressed() {
        let trunkRows = [wtRow("staging", "staging", ""), wtRow("main", "main", "")]
        let prs = ["staging": WTFixtures.closedPR, "main": WTFixtures.openPR]
        #expect(render(rows: trunkRows, cwd: nil, .on, prs, icon: gh, trunk: ["staging", "main"]) == [
            "  staging  staging  \(gh) –",
            "  main     main     \(gh) –",
        ].joined(separator: "\n"))
    }

    @Test func noMarkerWhenTheWorkingDirectoryIsOutsideEveryWorktree() {
        #expect(render(cwd: nil, .off).split(separator: "\n").allSatisfy { $0.hasPrefix("  ") })
    }

    @Test func aDirtyOnlyCluster() {
        #expect(render(rows: [wtRow("a", "b", "", dirty: true)], cwd: nil, .off) == "  a  b  +  ")
    }

    @Test func zeroAheadRendersNoArrow() {
        #expect(render(rows: [wtRow("a", "b", "0")], cwd: nil, .off) == "  a  b  ")
    }

    @Test func remoteAheadAndBehindCluster() {
        #expect(render(rows: [wtRow("a", "b", "3", remoteAhead: 2, remoteBehind: 1)], cwd: nil, .off) == "  a  b  ↗3 ↑2 ↓1  ")
    }

    /// The current row is bold-wrapped and re-arms bold after each interior
    /// reset, so no bare reset survives but the final one.
    @Test func theCurrentRowIsBold() throws {
        let lines = render(.on, ["main": WTFixtures.openPR], icon: gh, ui: ansi).components(separatedBy: "\n")
        try #require(lines.count == 3)
        let current = lines[0]
        #expect(current.hasPrefix(ANSI.bold))
        #expect(current.hasSuffix(ANSI.reset))
        let interior = String(current.dropLast(ANSI.reset.count))
        #expect(!interior.replacingOccurrences(of: ANSI.reset + ANSI.bold, with: "").contains(ANSI.reset))
        #expect(!lines[1].contains(ANSI.bold))
        #expect(!lines[2].contains(ANSI.bold))
    }

    // MARK: plain glyphs

    /// With no Nerd Font the forge icon collapses away, so every chip loses
    /// its two-column lead and the table stays aligned.
    @Test func plainChipsHaveNoForgeIconLead() {
        #expect(render(.on, ["main": WTFixtures.openPR], icon: "") == [
            "→ dotfiles  main  ↗4 ↑2 ↓1 +   #7 ◉",
            "  scratch   ryanm/scratch      –",
            "  det       abc123 (detached)  \(netOff)",
        ].joined(separator: "\n"))
    }

    @Test func plainNetOffAndLoadingLoseTheLead() {
        #expect(render(.wait, icon: "") == [
            "→ dotfiles  main  ↗4 ↑2 ↓1 +   \(netOff) \(notConnected)",
            "  scratch   ryanm/scratch      \(netOff) \(notConnected)",
            "  det       abc123 (detached)  \(netOff)",
        ].joined(separator: "\n"))
        #expect(render(.loading, icon: "") == [
            "→ dotfiles  main  ↗4 ↑2 ↓1 +   \(loading)",
            "  scratch   ryanm/scratch      \(loading)",
            "  det       abc123 (detached)  \(netOff)",
        ].joined(separator: "\n"))
    }

    // MARK: --json

    private func payload(
        cwd: String? = "dotfiles",
        state: PRState = .off,
        prs: PullRequestMap = [:],
        trunk: Set<String> = []
    ) -> NSDictionary? {
        let built = WT.buildListJSON(rows, cwdName: cwd, prState: state, prs: prs, paths: WTFixtures.paths, trunkBranches: trunk)
        return jsonObject(built.jsonString())
    }

    private func worktrees(_ payload: NSDictionary?) -> [NSDictionary] {
        payload?["worktrees"] as? [NSDictionary] ?? []
    }

    @Test func jsonShapeAndFields() throws {
        let got = try #require(payload())
        #expect(got["pr_state"] as? String == "off")
        #expect(worktrees(got).compactMap { $0["name"] as? String } == ["dotfiles", "scratch", "det"])
        let expected: NSDictionary = [
            "name": "dotfiles", "path": "/repo", "branch": "main", "current": true,
            "ahead": 4, "dirty": true, "remote_ahead": 2, "remote_behind": 1,
            "has_upstream": true, "pr": NSNull(),
        ]
        #expect(worktrees(got).first == expected)
    }

    @Test func jsonMarksOnlyTheWorkingDirectorysRowCurrent() {
        #expect(worktrees(payload()).compactMap { $0["current"] as? Bool } == [true, false, false])
    }

    @Test func jsonHasNoCurrentRowOutsideEveryWorktree() {
        let rows = worktrees(payload(cwd: nil))
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0["current"] as? Bool == false })
    }

    /// `buildRows` blanks the base branch's ahead count; JSON keeps it a
    /// number.
    @Test func aBlankAheadBecomesZero() {
        #expect(worktrees(payload()).dropFirst().first?["ahead"] as? Int == 0)
    }

    @Test func thePRIsIncludedWhenTheStateIsOn() {
        let rows = worktrees(payload(state: .on, prs: ["main": WTFixtures.openPR]))
        let expected: NSDictionary = ["number": 7, "state": "OPEN", "is_draft": false, "url": NSNull(), "title": NSNull()]
        #expect(rows.first?["pr"] as? NSDictionary == expected)
        #expect(rows.dropFirst().first?["pr"] is NSNull)
    }

    @Test func trunkBranchesReportNoPR() {
        let rows = worktrees(payload(state: .on, prs: ["main": WTFixtures.openPR], trunk: ["main"]))
        #expect(rows.first?["pr"] is NSNull)
    }

    /// A consumer tells "no PR" from "unavailable" by `pr_state`, so these
    /// states must not leak a stale PR onto a row.
    @Test(arguments: [PRState.off, .wait, .error])
    func thePRIsOmittedInEveryOtherState(_ state: PRState) {
        let got = payload(state: state, prs: ["main": WTFixtures.openPR])
        #expect(got?["pr_state"] as? String == state.rawValue)
        #expect(worktrees(got).first?["pr"] is NSNull)
    }

    // MARK: live print

    private func printLive(_ completion: ScriptedFetchCompletion?, live: Bool = true) -> String {
        let console = BufferConsole()
        let session = completion.map { PRFetchSession(completion: $0, numberPrefix: "#", forgeIcon: gh) }
        WT.printListLive(rows, cwdName: "dotfiles", fetch: session, trunkBranches: [], live: live, console: console)
        return console.stdout
    }

    @Test func withNoForgeTheLocalTableprintsOnce() {
        let out = printLive(nil)
        #expect(out == render(.off) + "\n")
        #expect(!out.contains("\u{1B}["))
    }

    /// The local table never waits on the forge, so a terminal always gets
    /// the loading frame and a redraw.
    @Test func aTerminalPrintsLoadingThenRedrawsResolved() {
        let prs = ["main": WTFixtures.openPR]
        let done = ScriptedFetchCompletion(true, result: prs)
        let out = printLive(done)
        let loadingFrame = render(.loading, icon: gh)
        let resolved = render(.on, prs, icon: gh)
        #expect(out == "\(loadingFrame)\n\u{1B}[3A\u{1B}[J\(resolved)\n")
        #expect(done.waits == [WT.listPRTotal])
    }

    @Test func aFailedFetchRedrawsTheErrorState() {
        let out = printLive(ScriptedFetchCompletion(true, result: nil))
        #expect(out.hasSuffix(render(.error, icon: gh) + "\n"))
    }

    @Test func aFetchThatNeverLandsEndsInWaitNotLoading() {
        let done = ScriptedFetchCompletion(false, result: nil)
        let out = printLive(done)
        #expect(out.hasSuffix(render(.wait, icon: gh) + "\n"))
        #expect(done.waits == [WT.listPRTotal])
    }

    @Test func offATerminalItPrintsOnceWithNoCursorCodes() {
        let prs = ["main": WTFixtures.openPR]
        let done = ScriptedFetchCompletion(true, result: prs)
        let out = printLive(done, live: false)
        #expect(out == render(.on, prs, icon: gh) + "\n")
        #expect(!out.contains("\u{1B}["))
        #expect(done.waits == [WT.listPRTotal])
    }

    // MARK: name cap

    private let longBranch = "ryanm/a-very-long-feature-branch-name-that-overflows"
    private let longWorktree = "a-very-long-worktree-directory-name-that-overflows"

    @Test func aLongBranchIsCutToTheCapWithAnEllipsis() {
        let out = render(rows: [wtRow("wt", longBranch, "")], cwd: nil, .off)
        #expect(out.contains(String(longBranch.prefix(WT.nameMax - 1)) + "…"))
        #expect(!out.contains(longBranch))
    }

    @Test func aLongWorktreeNameIsCutToTheCapWithAnEllipsis() {
        let out = render(rows: [wtRow(longWorktree, "ryanm/feat", "")], cwd: nil, .off)
        #expect(out.contains(String(longWorktree.prefix(WT.nameMax - 1)) + "…"))
        #expect(!out.contains(longWorktree))
    }

    @Test func aLongWorktreeNameDoesNotWidenTheColumn() throws {
        let out = render(rows: [wtRow(longWorktree, "b", ""), wtRow("short", "c", "")], cwd: nil, .off)
        let lines = out.components(separatedBy: "\n")
        try #require(lines.count == 2)
        #expect(lines[0].count == lines[1].count)
        #expect(lines[0].count < 2 + longWorktree.count + 5)
    }

    @Test func shortNamesAreNotCut() {
        let out = render(rows: [wtRow("wt", "ryanm/feat", "")], cwd: nil, .off)
        #expect(out.contains("ryanm/feat"))
        #expect(!out.contains("…"))
    }

    @Test func thePRLookupUsesTheFullNameDespiteTheCut() {
        let out = render(rows: [wtRow("wt", longBranch, "")], cwd: nil, .on, [longBranch: WTFixtures.openPR], icon: gh)
        #expect(out.contains("\(gh) #7 ◉"))
    }

    @Test func theMarkerUsesTheFullNameDespiteTheCut() {
        let out = render(rows: [wtRow(longWorktree, "ryanm/feat", "")], cwd: longWorktree, .off, ui: ansi)
        #expect(out.contains("→"))
        #expect(out.hasPrefix(ANSI.bold))
    }
}
