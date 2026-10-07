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

    @Test func sectionsRunFromWhatIsHappeningToWhereItRuns() {
        let facts = InfoPaneFacts(
            tabID: UUID(),
            liveSubagents: [subagent("a")],
            backgroundTasks: [.init(id: "t", kind: .monitor, startedAt: Date(), expiresAt: nil)],
            planTitle: "Plan",
            folder: "Plume",
            branch: .init(name: "main", isWorktree: false, ahead: nil, behind: nil, isDirty: false),
            pullRequest: .init(state: .noPR, checkRollup: nil)
        )
        #expect(facts.sections == [.subagents, .backgroundTasks, .plan, .folder, .branch, .pullRequest])
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
            showsCompleted: true,
            hasSettled: { $0.id == "settled" }
        )
        #expect(split.live.map(\.id) == ["lingering", "working"])
        #expect(split.completed.map(\.id) == ["settled"])
    }

    @Test func hiddenCompletedSubagentsAreDroppedNotMovedToLive() {
        let split = InfoPaneFacts.splitSubagents(
            [subagent("settled", .done), subagent("working")],
            showsCompleted: false,
            hasSettled: { $0.id == "settled" }
        )
        #expect(split.live.map(\.id) == ["working"])
        #expect(split.completed.isEmpty)
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
    @Test func thePaneSitsBesideOnlyWhileTheChatKeepsMostOfItsColumn() {
        let needed = InfoPaneLayout.paneWidth + 20 + 640 * InfoPaneLayout.minimumChatShare
        #expect(InfoPaneLayout.fitsBeside(width: needed, contentWidth: 640, inset: 20))
        #expect(!InfoPaneLayout.fitsBeside(width: needed - 1, contentWidth: 640, inset: 20))
    }
}
