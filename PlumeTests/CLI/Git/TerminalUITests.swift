import Foundation
import Testing
@testable import Plume

/// The terminal vocabulary `wt` and `stack` share: the two glyph sets, the
/// PR chips and their widths, and the help page's symbol key. Ported from
/// `test_shared_config.py` and the chip tests of `test_forge.py`.
struct TerminalUITests {
    private let plain = TerminalUI.plain
    private let nerd = TerminalUI(glyphSet: .nerd)
    private let ansi = TerminalUI(palette: .ansi)
    private let githubIcon = WTFixtures.githubIcon

    private static func pr(url: String? = "https://example.test/pr/7", checks: [CheckContext] = []) -> PullRequest {
        PullRequest(number: 7, state: .open, isDraft: false, url: url, title: "PR 7", checkContexts: checks)
    }

    // MARK: glyph sets

    /// Plain Unicode is the default so a fresh install never renders tofu.
    @Test func plainIsTheDefault() {
        #expect(TerminalUI().glyphSet == .plain)
        #expect(plain.checksPass == "✔")
        #expect(plain.checksFail == "✘")
        #expect(plain.checksPending == "•")
        #expect(plain.merged == "⑃")
        #expect(plain.netOff == "∅")
    }

    /// The number prefix (`#` or `!`) already names the forge.
    @Test func plainDropsTheForgeIcons() {
        #expect(plain.github == "")
        #expect(plain.gitlab == "")
        #expect(plain.forgeIcon(for: .github) == "")
    }

    @Test func nerdFontUsesPrivateUseCodepoints() {
        let glyphs = [nerd.checksPass, nerd.checksFail, nerd.checksPending, nerd.merged, nerd.github, nerd.gitlab, nerd.netOff]
        for glyph in glyphs {
            #expect(glyph.unicodeScalars.count == 1)
            #expect((glyph.unicodeScalars.first?.value ?? 0) >= 0xE000)
        }
    }

    @Test func nerdFontCodepoints() {
        #expect(nerd.checksPass == "\u{F058}")
        #expect(nerd.checksFail == "\u{F057}")
        #expect(nerd.checksPending == "\u{F111}")
        #expect(nerd.merged == "\u{F17F}")
        #expect(nerd.github == "\u{F09B}")
        #expect(nerd.gitlab == "\u{F296}")
        #expect(nerd.netOff == "\u{F0A8E}")
        #expect(nerd.forgeIcon(for: .gitlab) == "\u{F296}")
        #expect(nerd.forgeIcon(for: .none) == "")
    }

    /// Chip widths count each glyph as one column, so a multi-codepoint or
    /// wide glyph would break alignment.
    @Test func everyPlainGlyphIsOneScalar() {
        for glyph in [plain.checksPass, plain.checksFail, plain.checksPending, plain.merged, plain.netOff] {
            #expect(glyph.unicodeScalars.count == 1, "\(glyph)")
        }
    }

    // MARK: symbol key

    private func key(_ ui: TerminalUI = .plain, icon: String? = nil, prefix: String = "#", extra: [GlyphKeyEntry] = []) -> String {
        ui.glyphKey(forgeIcon: icon, numberPrefix: prefix, extra: extra).joined(separator: "\n")
    }

    @Test func theKeyListsThePlainGlyphs() {
        let out = key()
        for glyph in ["✔", "✘", "•", "⑃", "∅"] {
            #expect(out.contains(glyph))
        }
    }

    @Test func theKeyListsTheNerdGlyphs() {
        let out = key(nerd, icon: nerd.github)
        for glyph in [nerd.checksPass, nerd.merged, "\u{F09B}"] {
            #expect(out.contains(glyph))
        }
        #expect(!out.contains("✔"))
    }

    @Test func theForgeIconRowAppearsOnlyWithAnIcon() {
        #expect(!key(icon: "").contains("the forge the PR/MR lives on"))
        #expect(key(nerd, icon: "\u{F09B}").contains("the forge the PR/MR lives on"))
    }

    @Test func theNumberPrefixFollowsTheForge() {
        #expect(key(prefix: "#").contains("#12"))
        #expect(key(prefix: "!").contains("!12"))
    }

    @Test func theKeyExplainsBothMeaningsOfNetOff() {
        let out = key()
        #expect(out.contains("forge unreachable"))
        #expect(out.contains("local-only branch, never pushed"))
        #expect(out.contains(TerminalUI.netOffLabel))
    }

    @Test func extraEntriesGetTheirOwnSection() {
        let out = key(extra: [GlyphKeyEntry("●", "a node")])
        #expect(out.contains("stack graph"))
        #expect(out.contains("a node"))
        #expect(!key().contains("stack graph"))
    }

    @Test func glyphsCarryTheirRenderedColor() {
        let out = key(ansi)
        #expect(out.contains("\(ANSI.green)✔\(ANSI.reset)"))
        #expect(out.contains("\(ANSI.red)✘\(ANSI.reset)"))
        #expect(out.contains("\(ANSI.yellow)•\(ANSI.reset)"))
        #expect(out.contains("\(ANSI.magenta)⑃\(ANSI.reset)"))
    }

    /// Padding is computed on the bare glyph, so the zero-width escapes must
    /// not shift meanings out of their column.
    @Test func alignmentSurvivesColor() {
        let plainKey = plain.glyphKey()
        #expect(!plainKey.isEmpty)
        #expect(ansi.glyphKey().map(ANSI.strip) == plainKey)
    }

    /// Every bare-glyph row starts its meaning on one column; the net-off row
    /// may overhang rather than widen them all.
    @Test func meaningsAlignOnACommonColumn() throws {
        let pattern = try Regex(#"\S\s{2,}(\S)"#)
        var starts: Set<Int> = []
        for line in plain.glyphKey() where line.hasPrefix("    ") && !line.contains(TerminalUI.netOffLabel) {
            let match = try #require(line.firstMatch(of: pattern), "\(line)")
            starts.insert(line.distance(from: line.startIndex, to: match.output[1].range!.lowerBound))
        }
        #expect(starts.count == 1)
    }

    // MARK: chips

    /// An absent forge icon collapses its lead entirely rather than leaving
    /// a stray space.
    @Test func anEmptyIconCollapsesTheLead() {
        for chip in [plain.loadingChip(forgeIcon: ""), plain.branchPRChip(nil, hasUpstream: true, forgeIcon: "")] {
            #expect(chip.width == 1)
            #expect(!chip.text.isEmpty && !chip.text.hasPrefix(" "))
        }
    }

    /// This chip carries a trailing label, so its width is the glyph plus the
    /// label.
    @Test func anEmptyIconCollapsesTheNetOffChipsLead() {
        let chip = plain.netOffChip(forgeIcon: "", failed: false)
        #expect(chip.width == 1 + 1 + TerminalUI.netOffLabel.count)
        #expect(chip.text == "∅ not connected")
    }

    @Test func aPresentIconKeepsATwoColumnLead() {
        for chip in [plain.loadingChip(forgeIcon: githubIcon), plain.branchPRChip(nil, hasUpstream: true, forgeIcon: githubIcon)] {
            #expect(chip.width == 3)
            #expect(chip.text.contains("\(githubIcon) "))
        }
        let netOff = plain.netOffChip(forgeIcon: githubIcon, failed: false)
        #expect(netOff.width == 2 + 1 + 1 + TerminalUI.netOffLabel.count)
        #expect(netOff.text.contains("\(githubIcon) "))
    }

    /// Both render the net-off glyph, but an unreachable forge is labelled
    /// and a never-pushed branch isn't.
    @Test func theLabelMarksAFailedFetchNotALocalOnlyBranch() {
        #expect(plain.netOffChip(forgeIcon: "", failed: true).text.contains(TerminalUI.netOffLabel))
        let localOnly = plain.branchPRChip(nil, hasUpstream: false, forgeIcon: "").text
        #expect(localOnly.contains("∅"))
        #expect(!localOnly.contains(TerminalUI.netOffLabel))
    }

    @Test(arguments: [true, false])
    func theLabelShowsWhetherTheFetchFailedOrTimedOut(_ failed: Bool) {
        #expect(plain.netOffChip(forgeIcon: "", failed: failed).text.contains(TerminalUI.netOffLabel))
    }

    @Test func theIconAddsTwoColumnsToAPRChip() {
        let pr = Self.pr()
        #expect(plain.prChip(pr, numberPrefix: "#", forgeIcon: githubIcon).width - plain.prChip(pr, numberPrefix: "#", forgeIcon: "").width == 2)
    }

    /// The ignored set is a setting, never a hard-coded check name: empty by
    /// default, so a pending check shows as pending.
    @Test func ignoredPendingChecksDefaultToEmpty() {
        #expect(TerminalUI().ignoredPendingChecks.isEmpty)
        let pr = Self.pr(checks: [CheckContext(name: "a", status: "SUCCESS"), CheckContext(name: "slow", status: "IN_PROGRESS")])
        #expect(plain.prChip(pr).text == "#7 •")
    }

    @Test func anIgnoredPendingCheckFoldsToPass() {
        let ui = TerminalUI(ignoredPendingChecks: ["ci/slow-integration-suite"])
        let pr = Self.pr(checks: [
            CheckContext(name: "build", status: "SUCCESS"),
            CheckContext(name: "ci/slow-integration-suite", status: "IN_PROGRESS"),
        ])
        let chip = ui.prChip(pr)
        #expect(chip.text == "#7 ✔")
        #expect(chip.width == "#7 ".count + 1)
    }

    @Test func theGitLabPrefixRendersABang() {
        #expect(plain.prChip(Self.pr(), numberPrefix: "!").text.hasPrefix("!7 "))
    }

    @Test func aPRChipIsAHyperlinkWhenLinksAreOn() {
        let pr = Self.pr()
        let unlinked = plain.prChip(pr)
        let linked = ansi.prChip(pr)
        let url = "https://example.test/pr/7"
        #expect(linked.text.hasPrefix("\u{1B}]8;;\(url)\u{1B}\\"))
        #expect(linked.text.hasSuffix("\u{1B}]8;;\u{1B}\\"))
        #expect(linked.width == unlinked.width)
        #expect(!unlinked.text.contains("\u{1B}]8;;"))
        #expect(!unlinked.text.isEmpty)
    }

    @Test func aBranchWithAPRShowsThePRChip() {
        let pr = Self.pr()
        #expect(plain.branchPRChip(pr, hasUpstream: true, forgeIcon: githubIcon) == plain.prChip(pr, numberPrefix: "#", forgeIcon: githubIcon))
    }

    @Test func aPushedBranchWithNoPRIsADash() {
        #expect(plain.branchPRChip(nil, hasUpstream: true, forgeIcon: "") == Chip(text: "–", width: 1))
        #expect(plain.branchPRChip(nil, hasUpstream: true, forgeIcon: githubIcon) == Chip(text: "\(githubIcon) –", width: 3))
    }

    @Test func aLocalOnlyBranchIsNetOff() {
        #expect(plain.branchPRChip(nil, hasUpstream: false, forgeIcon: "") == Chip(text: "∅", width: 1))
    }

    @Test func aMissingPRChipSaysSo() {
        #expect(plain.prChip(nil).text == "(no PR)")
    }

    // MARK: redraw

    @Test func redrawMovesUpByTheLineCountAndClears() {
        #expect(TerminalUI.redrawPrefix(lines: 3) == "\u{1B}[3A\u{1B}[J")
    }
}
