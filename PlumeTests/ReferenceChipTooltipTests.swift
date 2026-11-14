import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Plume

/// A chip's tooltip leads with the full title, then the facts the chip has
/// no room for; a file shows its full path.
struct ReferenceChipTooltipTests {
    private func issue(summary: String? = nil, assignee: String? = "Ryan", dueDate: String? = nil) -> LinearIssue {
        LinearIssue(
            identifier: "PLUME-330",
            title: "Tooltips on reference chips",
            url: "https://linear.app/p/issue/PLUME-330",
            stateName: "In Progress",
            stateType: .started,
            stateColor: "#f2c94c",
            assigneeName: assignee,
            teamKey: "PLUME",
            summary: summary,
            dueDate: dueDate
        )
    }

    @Test func aLinearIssueShowsTitleAndFactsWithoutItsDescription() {
        let text = ReferenceChipTooltip.text(
            for: .linear(identifier: "PLUME-330"),
            detail: .linear(issue(summary: "Hovering a chip shows more.", dueDate: "2026-11-05")),
            title: nil,
            directory: nil
        )
        let due = ReferenceChipTooltip.formattedDueDate("2026-11-05")!
        #expect(text == "Tooltips on reference chips\nPLUME-330 · In Progress · Ryan · Due \(due)")
    }

    @Test func anUnassignedIssueSaysSo() {
        let text = ReferenceChipTooltip.linear(issue(assignee: nil))
        #expect(text == "Tooltips on reference chips\nPLUME-330 · In Progress · Unassigned")
    }

    @Test func aDueDateStaysOnItsCalendarDay() {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = TimeZone(identifier: "UTC")!
        let newYear = Date(timeIntervalSince1970: 1_767_225_600)
        #expect(ReferenceChipTooltip.formattedDueDate("2026-01-01") == newYear.formatted(style))
        #expect(ReferenceChipTooltip.formattedDueDate("soon") == nil)
    }

    @Test func aPullRequestShowsRepoStateAuthorAndReview() {
        let entry = PullRequestLinkSource.Entry(
            number: 12, title: "Add chips", state: .open, isDraft: false, author: "octocat", reviewDecision: .approved
        )
        let text = ReferenceChipTooltip.text(
            for: .pullRequest(owner: "ryan", repo: "plume", number: 12),
            detail: .pullRequest(entry),
            title: nil,
            directory: nil
        )
        #expect(text == "Add chips\nryan/plume #12 · Open · by octocat · Approved")
    }

    @Test func aDraftShowsAsDraftAndASettledPullRequestDropsItsReview() {
        let draft = PullRequestLinkSource.Entry(number: 3, title: "T", state: .open, isDraft: true, reviewDecision: .changesRequested)
        #expect(ReferenceChipTooltip.pullRequest(draft, owner: "o", repo: "r") == "T\no/r #3 · Draft · Changes requested")
        let merged = PullRequestLinkSource.Entry(number: 3, title: "T", state: .merged, isDraft: false, reviewDecision: .approved)
        #expect(ReferenceChipTooltip.pullRequest(merged, owner: "o", repo: "r") == "T\no/r #3 · Merged")
    }

    @Test func aTargetWithNoDetailShowsWhatTheChipKnows() {
        #expect(ReferenceChipTooltip.text(for: .linear(identifier: "A-1"), detail: nil, title: "Title", directory: nil) == "Title\nA-1")
        #expect(ReferenceChipTooltip.text(for: .pullRequest(owner: "o", repo: "r", number: 4), detail: nil, title: nil, directory: nil) == "o/r #4")
    }

    @Test func anArtifactShowsItsLink() {
        let url = URL(string: "https://claude.ai/artifact/abc")!
        #expect(ReferenceChipTooltip.text(for: .artifact(id: "abc"), detail: nil, title: nil, directory: nil, url: url) == url.absoluteString)
    }

    @Test func aFileShowsItsFullPath() {
        let text = ReferenceChipTooltip.text(for: .file(path: "/repo/Plume/App/X.swift"), detail: nil, title: nil, directory: "/repo")
        #expect(text == "/repo/Plume/App/X.swift")
    }

    @Test func aSummaryTakesTheFirstProseLinesWithoutMarkers() {
        let description = """
        ## Goal

        - Show more detail
        > on hover
        Third line
        """
        #expect(LinearIssue.summary(ofDescription: description) == "Goal\nShow more detail")
        #expect(LinearIssue.summary(ofDescription: "```\ncode\n```") == "code")
        #expect(LinearIssue.summary(ofDescription: "  \n") == nil)
        #expect(LinearIssue.summary(ofDescription: nil) == nil)
        let long = String(repeating: "a", count: 500)
        #expect(LinearIssue.summary(ofDescription: long)?.count == LinearIssue.summaryLengthLimit + 1)
    }
}

/// A composer chip names its target for the tooltip, which reads it when the
/// tooltip shows.
@MainActor
struct ComposerReferenceToolTipTests {
    @Test func aPullRequestChipTakesItsTargetFromTheResolvedURL() {
        let resolved = ResolvedMention(
            target: "https://github.com/ryan/plume/pull/12",
            title: "Add chips",
            state: .pullRequest(.open, isDraft: true)
        )
        let toolTip = ComposerReferenceChip.toolTip(of: .pullRequest(number: 12), resolved, directory: "/repo")
        #expect(toolTip?.target == .pullRequest(owner: "ryan", repo: "plume", number: 12))
        #expect(toolTip?.fallback == .pullRequest(.init(number: 12, title: "Add chips", state: .open, isDraft: true)))
    }

    @Test func aRelativeFileChipResolvesAgainstTheTabDirectory() {
        let resolved = ResolvedMention(target: "Plume/App/X.swift", title: nil, state: .file(isDirectory: false))
        let toolTip = ComposerReferenceChip.toolTip(of: .file(path: "Plume/App/X.swift", isDirectory: false), resolved, directory: "/repo")
        #expect(toolTip?.target == .file(path: "/repo/Plume/App/X.swift"))
        #expect(toolTip?.text == "/repo/Plume/App/X.swift")
    }

    @Test func eachLineOfAChipGetsATooltipRect() {
        let owner = ComposerReferenceToolTips()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let toolTip = ComposerReferenceChip.ToolTip(target: .file(path: "/repo/a"), directory: "/repo")
        let chip = ComposerDecorations.ReferenceChip(
            rects: [NSRect(x: 0, y: 0, width: 40, height: 16), NSRect(x: 0, y: 16, width: 20, height: 16)],
            iconRect: .zero, glyph: .symbol("doc"), tint: .labelColor, wash: .clear, toolTip: toolTip
        )
        owner.update([chip], in: view)
        let first = UnsafeMutableRawPointer(bitPattern: 1)
        let second = UnsafeMutableRawPointer(bitPattern: 2)
        #expect(owner.view(view, stringForToolTip: 0, point: .zero, userData: first) == "/repo/a")
        #expect(owner.view(view, stringForToolTip: 0, point: .zero, userData: second) == "/repo/a")
        #expect(owner.view(view, stringForToolTip: 0, point: .zero, userData: UnsafeMutableRawPointer(bitPattern: 3)) == "")
    }
}
