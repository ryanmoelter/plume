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

    @Test func completedSubagentsListNewestActivityFirst() {
        func dated(_ id: String, _ seconds: TimeInterval?) -> SubagentTranscript {
            SubagentTranscript(
                id: id, transcript: Transcript(),
                modifiedAt: seconds.map { Date(timeIntervalSince1970: $0) }, status: .done
            )
        }
        let ordered = InfoPaneFacts.newestFirst([
            dated("none1", nil), dated("old", 10), dated("tieA", 50), dated("new", 90), dated("tieB", 50), dated("none2", nil)
        ])
        #expect(ordered.map(\.id) == ["new", "tieA", "tieB", "old", "none1", "none2"])

        let split = InfoPaneFacts.splitSubagents(
            [dated("w2", nil), dated("old", 10), dated("w1", 99), dated("new", 90)],
            hasSettled: { $0.id == "old" || $0.id == "new" }
        )
        #expect(split.live.map(\.id) == ["w2", "w1"])
        #expect(split.completed.map(\.id) == ["new", "old"])
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

    // MARK: Linear

    private func link(
        _ identifier: String,
        _ role: LinearLinkRole = .working,
        sources: Set<LinearLinkSource> = [.branch],
        subagents: [String] = [],
        mainAgent: Bool = false
    ) -> LinkedLinearIssue {
        LinkedLinearIssue(
            identifier: identifier,
            role: role,
            sources: sources,
            subagents: subagents.map { LinearSubagentRef(id: $0, label: $0) },
            touchedByMainAgent: mainAgent
        )
    }

    private func linearIssue(_ identifier: String) -> LinearIssue {
        LinearIssue(
            identifier: identifier, title: "Title", url: "https://linear.app/x/issue/\(identifier)",
            stateName: "In Progress", stateType: .started, stateColor: "#f2c94c",
            assigneeName: "Ada", teamKey: "PLUME"
        )
    }

    @Test func linearSectionNeedsTheSettingAndAWorkspace() {
        func facts(enabled: Bool, configured: Bool) -> InfoPaneFacts {
            InfoPaneFacts(tabID: UUID(), linear: InfoPaneFacts.linear(
                isEnabled: enabled, isConfigured: configured, links: [], state: { _ in nil }
            ))
        }
        #expect(facts(enabled: false, configured: true).sections.isEmpty)
        #expect(facts(enabled: true, configured: false).sections.isEmpty)
        #expect(facts(enabled: true, configured: true).sections == [.linearIssues])
        #expect(facts(enabled: true, configured: true).collapsedSections.isEmpty)
    }

    @Test func collapsedFormMarksLinearOnlyWithIssues() {
        let issues = InfoPaneFacts.linearIssues(links: [link("PLUME-1")], state: { _ in nil })
        let facts = InfoPaneFacts(tabID: UUID(), linear: .init(issues: issues))
        #expect(facts.collapsedSections == [.linearIssues])
    }

    @Test func workingIssuesComeBeforeMentionedOnes() {
        let issues = InfoPaneFacts.linearIssues(
            links: [link("A-1", .mentioned), link("B-2"), link("C-3", .mentioned), link("D-4")],
            state: { _ in nil }
        )
        #expect(issues.map(\.identifier) == ["B-2", "D-4", "A-1", "C-3"])
    }

    @Test func attributionNamesSubagentsAndTheMainAgent() {
        #expect(InfoPaneFacts.attribution(of: link("A-1")) == nil)
        #expect(InfoPaneFacts.attribution(of: link("A-1", mainAgent: true)) == nil)
        #expect(InfoPaneFacts.attribution(of: link("A-1", subagents: ["Explore"])) == "via Explore")
        #expect(InfoPaneFacts.attribution(of: link("A-1", subagents: ["Explore", "Plan"])) == "via Explore, Plan")
        #expect(
            InfoPaneFacts.attribution(of: link("A-1", subagents: ["Explore"], mainAgent: true))
                == "via Explore and main agent"
        )
    }

    @Test func sourceHintsApplyToWorkingIssuesOnly() {
        #expect(InfoPaneFacts.sourceHint(of: link("A-1", sources: [.branch])) == "branch")
        #expect(InfoPaneFacts.sourceHint(of: link("A-1", sources: [.manual])) == "linked")
        #expect(InfoPaneFacts.sourceHint(of: link("A-1", sources: [.agentStarted])) == "agent started")
        #expect(InfoPaneFacts.sourceHint(of: link("A-1", sources: [.promoted])) == "marked working")
        #expect(InfoPaneFacts.sourceHint(of: link("A-1", sources: [.agent])) == nil)
        let issues = InfoPaneFacts.linearIssues(
            links: [link("A-1", .mentioned, sources: [.agent]), link("B-2", sources: [.branch, .manual])],
            state: { _ in nil }
        )
        #expect(issues.first { $0.identifier == "A-1" }?.sourceHint == nil)
        #expect(issues.first { $0.identifier == "B-2" }?.sourceHint == "linked, branch")
    }

    @Test func fetchStatesReadAsWordsNeverAsNoIssue() {
        let issue = linearIssue("A-1")
        #expect(InfoPaneFacts.statusWord(for: .issue(issue)) == nil)
        #expect(InfoPaneFacts.statusWord(for: .stale(issue, reason: "offline")) == nil)
        #expect(InfoPaneFacts.statusWord(for: nil) == "loading")
        #expect(InfoPaneFacts.statusWord(for: .loading) == "loading")
        #expect(InfoPaneFacts.statusWord(for: .notFound) == "not found")
        #expect(InfoPaneFacts.statusWord(for: .failed("x")) == "offline")
        #expect(InfoPaneFacts.statusWord(for: .unauthorized) == "key rejected")
        #expect(InfoPaneFacts.statusWord(for: .rateLimited(until: Date())) == "rate limited")
    }

    @Test func aStaleIssueKeepsItsLastGoodValues() {
        let issue = linearIssue("A-1")
        let facts = InfoPaneFacts.linearIssues(
            links: [link("A-1")], state: { _ in .stale(issue, reason: "offline") }
        )
        #expect(facts.first?.title == "Title")
        #expect(facts.first?.stateName == "In Progress")
        #expect(facts.first?.assignee == "Ada")
        #expect(facts.first?.url == URL(string: issue.url))
        #expect(facts.first?.statusWord == nil)
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
