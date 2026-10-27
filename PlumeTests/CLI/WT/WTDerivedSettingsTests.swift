import Foundation
import Testing
@testable import Plume

/// The fallbacks `wt` applies where a project leaves a setting unset, and
/// the terminal vocabulary its settings select.
struct WTDerivedSettingsTests {
    @Test func theBranchPrefixFallsBackToTheEmailsLocalPart() {
        #expect(WTSettings.branchPrefix(configured: nil, userEmail: "ryan@example.com") == "ryan/")
    }

    @Test func aConfiguredPrefixWins() {
        #expect(WTSettings.branchPrefix(configured: "me/", userEmail: "ryan@example.com") == "me/")
    }

    /// An empty prefix is "no prefix", not "unset".
    @Test func anExplicitEmptyPrefixWins() {
        #expect(WTSettings.branchPrefix(configured: "", userEmail: "ryan@example.com") == "")
    }

    @Test func aConfiguredPrefixIsTrimmedAndEndsInASlash() {
        #expect(WTSettings.branchPrefix(configured: "  me ", userEmail: nil) == "me/")
        #expect(WTSettings.branchPrefix(configured: "me/\n", userEmail: nil) == "me/")
        #expect(WTSettings.normalizedBranchPrefix("team/me") == "team/me/")
    }

    @Test func aWhitespaceOnlyPrefixFallsBackToTheEmail() {
        #expect(WTSettings.branchPrefix(configured: "   ", userEmail: "ryan@example.com") == "ryan/")
    }

    @Test func aMissingOrMalformedEmailCannotSupplyAPrefix() {
        #expect(WTSettings.branchPrefix(configured: nil, userEmail: nil) == nil)
        #expect(WTSettings.branchPrefix(configured: nil, userEmail: "") == nil)
        #expect(WTSettings.branchPrefix(configured: nil, userEmail: "no-at-sign") == nil)
    }

    @Test func theBaseBranchPrefersTheSetting() {
        #expect(WTSettings.baseBranch(configured: "develop", originHead: "origin/main") == "develop")
    }

    @Test func theBaseBranchFallsBackToOriginHeadThenMain() {
        #expect(WTSettings.baseBranch(configured: nil, originHead: "origin/staging") == "staging")
        #expect(WTSettings.baseBranch(configured: "", originHead: "origin/staging") == "staging")
        #expect(WTSettings.baseBranch(configured: nil, originHead: nil) == "main")
    }

    @Test func trunkBranchesAreTheBaseAndOriginsDefault() {
        #expect(WTSettings.trunkBranches(baseBranch: "staging", originHead: "origin/main") == ["staging", "main"])
        #expect(WTSettings.trunkBranches(baseBranch: "main", originHead: nil) == ["main"])
    }

    @Test func theMainWorktreeIsAlwaysProtected() {
        #expect(WTSettings.protectedWorktrees(configured: ["keep"], layout: .standard, mainName: "repo") == ["keep", "repo"])
        #expect(WTSettings.protectedWorktrees(configured: nil, layout: .standard, mainName: "repo") == ["repo"])
    }

    @Test func theBareRepositoryIsAlwaysProtected() {
        #expect(WTSettings.protectedWorktrees(configured: ["keep"], layout: .bare, mainName: "") == ["keep", ".bare"])
    }

    @Test func colorNeedsATerminalAndNoNOCOLOR() {
        let settings = ProjectSettings()
        #expect(WTSettings.terminalUI(settings: settings, nerdFont: .automatic, stdoutIsTerminal: true, environment: [:]).palette == .ansi)
        #expect(WTSettings.terminalUI(settings: settings, nerdFont: .automatic, stdoutIsTerminal: false, environment: [:]).palette == .plain)
        #expect(WTSettings.terminalUI(settings: settings, nerdFont: .automatic, stdoutIsTerminal: true, environment: ["NO_COLOR": "1"]).palette == .plain)
    }

    @Test func nerdFontFollowsTheResolvedMode() {
        let insidePlume = ["PLUME_TAB_ID": UUID().uuidString]
        #expect(WTSettings.terminalUI(settings: ProjectSettings(), nerdFont: .automatic, stdoutIsTerminal: true, environment: [:]).glyphSet == .plain)
        #expect(WTSettings.terminalUI(settings: ProjectSettings(), nerdFont: .automatic, stdoutIsTerminal: true, environment: insidePlume).glyphSet == .nerd)
        #expect(WTSettings.terminalUI(settings: ProjectSettings(), nerdFont: .on, stdoutIsTerminal: true, environment: [:]).glyphSet == .nerd)
        #expect(WTSettings.terminalUI(settings: ProjectSettings(), nerdFont: .off, stdoutIsTerminal: true, environment: insidePlume).glyphSet == .plain)
    }

    @Test func ignoredPendingChecksComeFromTheSettings() {
        let ui = WTSettings.terminalUI(settings: ProjectSettings(ignoredPendingChecks: ["slow"]), nerdFont: .automatic, stdoutIsTerminal: false, environment: [:])
        #expect(ui.ignoredPendingChecks == ["slow"])
    }
}
