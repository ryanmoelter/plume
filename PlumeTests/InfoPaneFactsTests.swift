import Foundation
import Testing
@testable import Plume

@MainActor
struct InfoPaneFactsTests {
    private func subagent(_ id: String, _ status: TaskStatus = .working) -> SubagentTranscript {
        SubagentTranscript(id: id, transcript: Transcript(), modifiedAt: nil, status: status)
    }

    @Test func aTabWithNothingToSayHasNoSections() {
        #expect(InfoPaneFacts(tabID: UUID()).sections.isEmpty)
    }

    @Test func whatNeedsAttentionComesBeforeWhereItRuns() {
        let facts = InfoPaneFacts(
            tabID: UUID(),
            liveSubagents: [subagent("a")],
            backgroundTasks: [.init(id: "t", kind: .monitor, startedAt: Date(), expiresAt: nil)],
            planTitle: "Plan",
            folder: "Plume",
            branch: .init(name: "main", isWorktree: false, ahead: nil, behind: nil, isDirty: false),
            pullRequest: .init(state: .pullRequest(PullRequest(number: 7, state: .open, isDraft: false)), checkRollup: nil)
        )
        #expect(facts.sections == [.subagents, .backgroundTasks, .pullRequest, .plan, .folder, .branch])
    }

    @Test func sideChatsShowOnceAQuestionIsAskedButNotWhenCollapsed() {
        let facts = InfoPaneFacts(tabID: UUID(), planTitle: "Plan", folder: "Plume", sideChatCount: 2)
        #expect(facts.sections == [.plan, .sideChat, .folder])
        #expect(facts.collapsedSections == [.plan])
        #expect(!InfoPaneFacts(tabID: UUID(), sideChatCount: 0).sections.contains(.sideChat))
    }

    @Test func onlyCompletedSubagentsStillShowTheSection() {
        let facts = InfoPaneFacts(tabID: UUID(), completedSubagents: [subagent("a", .done)])
        #expect(facts.sections == [.subagents])
    }

    @Test func aSubagentInsideItsLingerCountsAsLive() {
        let settled = subagent("settled", .done)
        let lingering = subagent("lingering", .done)
        let split = InfoPaneFacts.splitSubagents(
            [settled, lingering, subagent("working")],
            hasSettled: { $0.id == "settled" }
        )
        #expect(split.live.map(\.id) == ["lingering", "working"])
        #expect(split.completed.map(\.id) == ["settled"])
    }

    @Test func theCollapsedFormLeavesOutWhereItRunsAndSettledSubagents() {
        let facts = InfoPaneFacts(
            tabID: UUID(),
            completedSubagents: [subagent("a", .done)],
            planTitle: "Plan",
            folder: "Plume",
            branch: .init(name: "main", isWorktree: false, ahead: nil, behind: nil, isDirty: false),
            pullRequest: .init(state: .noPR, checkRollup: nil)
        )
        #expect(facts.collapsedSections == [.plan])
    }

    @Test func theCollapsedFormMarksAWorktree() {
        let facts = InfoPaneFacts(
            tabID: UUID(),
            branch: .init(name: "feature", isWorktree: true, ahead: nil, behind: nil, isDirty: false)
        )
        #expect(facts.collapsedSections == [.branch])
    }

    @Test func aPullRequestRowNeedsAPullRequest() {
        let open = PullRequest(number: 7, state: .open, isDraft: false)
        let withPR = InfoPaneFacts(tabID: UUID(), pullRequest: .init(state: .pullRequest(open), checkRollup: .success))
        #expect(withPR.collapsedSections == [.pullRequest])
        for state in [PullRequestFetchState.noPR, .localOnly, .loading] {
            let facts = InfoPaneFacts(tabID: UUID(), pullRequest: .init(state: state, checkRollup: nil))
            #expect(facts.sections.isEmpty)
        }
    }

    @Test func aHiddenPaneComesBackCollapsed() {
        #expect(InfoPaneState(rawValue: "hidden") == .collapsed)
        #expect(InfoPaneState(rawValue: "expanded") == .expanded)
    }

    @Test func aForgeThatCannotAnswerShowsNoPullRequestRow() {
        #expect(InfoPaneFacts.pullRequest(state: .forgeUnsupported) { $0.checkRollup() } == nil)
        #expect(InfoPaneFacts.pullRequest(state: nil) { $0.checkRollup() } == nil)
    }

    @Test func aPullRequestCarriesTheStoresRollup() {
        let pullRequest = PullRequest(number: 7, state: .open, isDraft: false)
        let facts = InfoPaneFacts.pullRequest(state: .pullRequest(pullRequest)) { _ in .pending }
        #expect(facts?.checkRollup == .pending)
    }
}

struct InfoPaneLayoutTests {
    private let chatColumn: CGFloat = 672
    private let rail: CGFloat = 30
    private let gap: CGFloat = 10

    private func side(width: CGFloat, state: InfoPaneState = .expanded) -> InfoPaneLayout.SideGeometry {
        InfoPaneLayout.side(
            width: width,
            railFootprint: rail,
            gap: gap,
            chatColumnWidth: chatColumn,
            state: state,
            collapsedHeight: 28
        )
    }

    @Test func thePanePinsOnlyWhileTheChatKeepsItsFullColumn() {
        let needed = chatColumn + InfoPaneLayout.paneWidth + gap + rail
        #expect(side(width: needed).isPinned)
        #expect(!side(width: needed - 1).isPinned)
        #expect(!side(width: needed - 1).fitsBeside)
    }

    /// Pinning never moves the chat vertically: that would slide every
    /// visible row while the pane animates.
    @Test func aPinnedPaneTakesRoomBesideTheChatAndKeepsTheTopInset() {
        let pinned = side(width: 2000)
        #expect(pinned.chatTrailingReserve == InfoPaneLayout.paneWidth + gap + rail)
        #expect(pinned.chatTopInset == side(width: 2000, state: .collapsed).chatTopInset)
    }

    @Test func aCollapsedPaneTakesRoomAboveTheChatAndNoneBesideIt() {
        let collapsed = side(width: 2000, state: .collapsed)
        #expect(collapsed.fitsBeside)
        #expect(!collapsed.isPinned)
        #expect(collapsed.chatTrailingReserve == 0)
        #expect(collapsed.chatTopInset == 28 + gap)
    }

    @Test func anUnmeasuredChatStartsPinned() {
        #expect(side(width: 0).isPinned)
    }

    @Test func aNarrowWindowNeverPinsEvenWhenExpanded() {
        let narrow = side(width: 800)
        #expect(!narrow.isPinned)
        #expect(narrow.chatTrailingReserve == 0)
        #expect(narrow.trailingInset == rail + gap)
    }
}
