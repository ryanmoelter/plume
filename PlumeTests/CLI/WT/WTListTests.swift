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
            rows ?? self.rows, currentIndex: index(of: cwd, in: rows ?? self.rows), prState: state, prs: prs, numberPrefix: prefix,
            forgeIcon: icon, trunkBranches: trunk, dirs: dirs, ui: ui
        )
    }

    private func index(of name: String?, in rows: [WorktreeRow]) -> Int? {
        name.flatMap { name in rows.firstIndex { $0.name == name } }
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
        let built = WT.buildListJSON(rows, currentIndex: index(of: cwd, in: rows), prState: state, prs: prs, paths: WTFixtures.paths, trunkBranches: trunk)
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

    /// Two worktrees named `feature`, in different directories; the working
    /// directory is the second.
    @Test func onlyTheWorkingDirectorysRowIsCurrentWhenNamesRepeat() throws {
        let rows = [wtRow("feature", "ryanm/a", ""), wtRow("feature", "ryanm/b", "")]
        let ctx = FakeWTContext(
            worktrees: rows,
            paths: ["/repo/.plume/worktrees/feature", "/elsewhere/feature"],
            currentPath: "/elsewhere/feature"
        )

        try WT.list(ctx, [])
        #expect(ctx.buffer.stdout.split(separator: "\n").map { $0.hasPrefix("→") } == [false, true])

        let json = FakeWTContext(
            worktrees: rows,
            paths: ["/repo/.plume/worktrees/feature", "/elsewhere/feature"],
            currentPath: "/elsewhere/feature"
        )
        try WT.list(json, ["--json"])
        let payload = try #require(jsonObject(json.buffer.stdout))
        #expect(worktrees(payload).compactMap { $0["current"] as? Bool } == [false, true])
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

    private func printLive(
        _ completion: ScriptedFetchCompletion?,
        rows: [WorktreeRow]? = nil,
        live: Bool = true,
        size: TerminalSize? = nil
    ) -> String {
        let console = BufferConsole()
        let session = completion.map { PRFetchSession(completion: $0, numberPrefix: "#", forgeIcon: gh) }
        WT.printListLive(rows ?? self.rows, currentIndex: 0, fetch: session, trunkBranches: [], live: live, terminalSize: size, console: console)
        return console.stdout
    }

    @Test func displayWidthCountsWideGlyphsAsTwoColumns() {
        #expect(TerminalUI.displayWidth("abc") == 3)
        #expect(TerminalUI.displayWidth("日本語") == 6)
        #expect(TerminalUI.displayWidth("한글") == 4)
        #expect(TerminalUI.displayWidth("🚀") == 2)
        #expect(TerminalUI.displayWidth("a🚀b") == 4)
    }

    @Test(arguments: ["日本語-fix", "rocket-🚀"])
    func lineWidthsMatchTheVisibleText(_ branch: String) {
        let wide = [WorktreeRow(name: "wide", branch: branch, ahead: "", dirty: false, remoteAhead: 0, remoteBehind: 0, hasUpstream: true)]
        let lines = WT.renderListLines(rows + wide, currentIndex: 0, prState: .off, prs: [:], numberPrefix: "#")
        let plain = lines.map { TerminalUI.displayWidth($0.text) }
        #expect(lines.map(\.width) == plain)
    }

    @Test func aHyperlinkAddsNoColumns() throws {
        let pr = PullRequest(number: 7, state: .open, isDraft: false, url: "https://example.com/pull/7")
        let prs = ["main": pr]
        let plain = WT.renderListLines(rows, currentIndex: 0, prState: .on, prs: prs, numberPrefix: "#", forgeIcon: gh)
        let linked = WT.renderListLines(rows, currentIndex: 0, prState: .on, prs: prs, numberPrefix: "#", forgeIcon: gh, ui: ansi)
        try #require(linked[0].text.contains("\u{1B}]8;;"))
        #expect(linked.map(\.width) == plain.map(\.width))
    }

    @Test func onlyATerminalWithRoomToSpareRedrawsInPlace() {
        #expect(WT.redrawsInPlace(isTerminal: true, frameRows: 3, terminalRows: nil))
        #expect(WT.redrawsInPlace(isTerminal: true, frameRows: 23, terminalRows: 24))
        #expect(!WT.redrawsInPlace(isTerminal: true, frameRows: 24, terminalRows: 24))
        #expect(!WT.redrawsInPlace(isTerminal: false, frameRows: 3, terminalRows: 24))
    }

    @Test func aNarrowTerminalRewindsOneRowPerLine() throws {
        let out = printLive(ScriptedFetchCompletion(true, result: [:]), rows: longRows, size: TerminalSize(columns: 60, rows: 100))
        let frames = out.components(separatedBy: TerminalUI.redrawPrefix(lines: longRows.count))
        try #require(frames.count == 2)
        let loadingLines = frames[0].split(separator: "\n")
        #expect(loadingLines.count == longRows.count)
        #expect(loadingLines.allSatisfy { TerminalUI.displayWidth(String($0)) <= 60 })
    }

    @Test func aFrameTallerThanTheTerminalPrintsBelowTheLoadingFrame() {
        let prs = ["main": WTFixtures.openPR]
        let done = ScriptedFetchCompletion(true, result: prs)
        let out = printLive(done, size: TerminalSize(columns: 200, rows: 3))
        #expect(out == render(.loading, icon: gh) + "\n" + render(.on, prs, icon: gh) + "\n")
        #expect(done.waits == [WT.listPRTotal])
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

    // MARK: terminal width

    private let longRows = [
        wtRow("a-thirty-column-worktree-name-", "ryanm/a-forty-column-branch-name-to-test", "4", dirty: true, remoteAhead: 2, remoteBehind: 1),
        wtRow("short", "ryanm/another-fairly-long-branch-name", ""),
        wtRow("det", "abc123 (detached)", "0", hasUpstream: false),
    ]

    private func fitted(
        _ rows: [WorktreeRow],
        _ state: PRState,
        _ prs: PullRequestMap = [:],
        columns: Int?,
        dirs: [String]? = nil,
        ui: TerminalUI = .plain
    ) -> [Chip] {
        WT.renderListLines(
            rows, currentIndex: 0, prState: state, prs: prs, numberPrefix: "#", forgeIcon: gh,
            dirs: dirs, columns: columns, ui: ui
        )
    }

    /// The `wait` chip is as wide as the PR column the fit reserves, so its
    /// lines fill the terminal to the last column.
    @Test func aTableFitsANarrowTerminalWithItsFixedColumnsIntact() {
        let lines = fitted(longRows, .wait, columns: 60)
        let widths = lines.map { TerminalUI.displayWidth($0.text) }
        #expect(widths.max() == 60)
        #expect(lines.map(\.width) == widths)
        #expect(lines[0].text.contains("↗4 ↑2 ↓1 +"))
        #expect(lines.prefix(2).allSatisfy { $0.text.hasSuffix("\(gh) \(netOff) \(notConnected)") })
        #expect(lines[2].text.hasSuffix("  \(netOff)"))
        #expect(lines[0].text.contains("…"))
    }

    @Test func aColoredTableFitsByItsVisibleColumns() {
        let prs = [longRows[0].branch: WTFixtures.openPR]
        let lines = fitted(longRows, .on, prs, columns: 60, ui: ansi)
        #expect(lines.allSatisfy { TerminalUI.visibleWidth($0.text) <= 60 })
        #expect(lines.map(\.width) == lines.map { TerminalUI.visibleWidth($0.text) })
        #expect(ANSI.strip(lines[0].text).contains("#7 ◉"))
    }

    @Test func theWiderColumnShrinksFirst() throws {
        let rows = [wtRow("twelve-chars", "ryanm/a-forty-column-branch-name-to-test", "")]
        let natural = try #require(fitted(rows, .wait, columns: nil).first)
        let line = try #require(fitted(rows, .wait, columns: natural.width - 10).first)
        #expect(line.text.contains("twelve-chars  ryanm/a-forty-column-branch-n…  "))
        #expect(line.width == natural.width - 10)
    }

    @Test func theFloorsGiveWayToCuttingTheLineTail() {
        let lines = fitted(longRows, .wait, columns: 30)
        #expect(lines.allSatisfy { TerminalUI.displayWidth($0.text) <= 30 })
        #expect(lines[0].text.hasPrefix("→ a-thirt…  ryanm/a…  ↗4 ↑2 ↓…"))
        #expect(lines[0].text.hasSuffix("…"))
    }

    @Test func aLongPathColumnIsCutAtTheTerminalWidth() {
        let dirs = [".", ".plume/worktrees/short", "/a/very/long/path/that/runs/well/past/the/edge/of/the/screen"]
        let lines = fitted(longRows, .wait, columns: 80, dirs: dirs)
        #expect(lines.allSatisfy { TerminalUI.displayWidth($0.text) <= 80 })
        #expect(lines[2].text.hasSuffix("…"))
    }

    @Test func theLoadingAndResolvedFramesShareColumnWidths() {
        let prs = [longRows[0].branch: WTFixtures.openPR]
        func beforePRColumn(_ chips: [Chip]) -> [String] {
            chips.map { String($0.text.prefix { $0 != Character(gh) && $0 != Character(netOff) }) }
        }
        let loading = beforePRColumn(fitted(longRows, .loading, columns: 60))
        #expect(loading == beforePRColumn(fitted(longRows, .on, prs, columns: 60)))
        #expect(loading == beforePRColumn(fitted(longRows, .wait, columns: 60)))
    }

    @Test func pipedOutputIsNeverCut() {
        let out = printLive(ScriptedFetchCompletion(true, result: [:]), rows: longRows, live: false, size: TerminalSize(columns: 60, rows: 100))
        #expect(out.contains(longRows[0].name))
        #expect(out.contains(longRows[0].branch))
    }

    @Test func aTerminalWithNoForgeStillFits() {
        let out = printLive(nil, rows: longRows, size: TerminalSize(columns: 50, rows: 100))
        #expect(out.split(separator: "\n").allSatisfy { TerminalUI.displayWidth(String($0)) <= 50 })
        #expect(out.contains("…"))
    }

    @Test func jsonIsNeverCutOnANarrowTerminal() throws {
        let ctx = FakeWTContext(worktrees: longRows, current: "short")
        ctx.buffer.stdoutIsTerminal = true
        ctx.buffer.terminalSize = TerminalSize(columns: 40, rows: 100)
        try WT.list(ctx, ["--json"])
        let payload = try #require(jsonObject(ctx.buffer.stdout))
        #expect(worktrees(payload).compactMap { $0["name"] as? String } == longRows.map(\.name))
        #expect(worktrees(payload).compactMap { $0["branch"] as? String } == longRows.map(\.branch))
    }
}
