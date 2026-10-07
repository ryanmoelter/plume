import Foundation
import Testing
@testable import Plume

/// `MessageRedoContext` carries a closure and so cannot be `Equatable`, but
/// the chat list needs to know when a row's rendering of it has changed.
/// `renderedState` is that comparison, and getting it wrong is silent: a fork
/// marker that never appears, or every row restaged on every transcript read.
@MainActor
struct MessageRedoContextTests {
    private func context(
        lastSeenUserMessageID: String = "u2",
        transcriptMessageIDs: Set<String> = ["u2"],
        canFork: Bool = true,
        abandoned: [String: Int] = [:]
    ) -> MessageRedoContext {
        MessageRedoContext(
            tabID: Self.tabID,
            lastSeenUserMessageID: lastSeenUserMessageID,
            parentByMessageID: ["u2": "a1"],
            transcriptMessageIDs: transcriptMessageIDs,
            canFork: canFork,
            onFork: { _ in },
            abandonedCountByMessageID: abandoned
        )
    }

    private static let tabID = UUID()

    /// The bug this guards: the chat renders an optimistic first message
    /// before the transcript exists, and its id is Plume's own string rather
    /// than a uuid the CLI has ever seen. Offering redo on it sends that
    /// string as `target_message_uuid`, which the CLI refuses.
    @Test func theOptimisticFirstMessageIsNeverARedoTarget() {
        let onlyOptimistic = context(transcriptMessageIDs: [])
        #expect(!onlyOptimistic.transcriptMessageIDs.contains(OptimisticFirstMessage.messageID))
        #expect(!context().transcriptMessageIDs.contains(OptimisticFirstMessage.messageID))
    }

    /// The transcript landing is what turns the buttons on, and it need not
    /// change any piece — so it has to restage rows on its own.
    @Test func theTranscriptArrivingChangesTheRenderedState() {
        #expect(context(transcriptMessageIDs: []).renderedState != context().renderedState)
    }

    @Test func twoContextsOverTheSameConversationCompareEqual() {
        #expect(context().renderedState == context().renderedState)
    }

    /// The case the comparison exists for: a fork appearing changes what a row
    /// draws without changing the row's own piece.
    @Test func aNewlyAbandonedBranchChangesTheRenderedState() {
        #expect(context().renderedState != context(abandoned: ["a1": 2]).renderedState)
    }

    @Test func aNewerLastSeenMessageChangesTheRenderedState() {
        #expect(context().renderedState != context(lastSeenUserMessageID: "u4").renderedState)
    }

    /// It gates whether the fork button draws enabled, so a session id
    /// arriving has to restage the row that was drawn without one.
    @Test func gainingASessionToForkFromChangesTheRenderedState() {
        #expect(context(canFork: false).renderedState != context().renderedState)
    }

    /// The fork closure is rebuilt on every `body`, and the parent map is read
    /// only when a button is pressed. Neither is drawn, so neither should
    /// restage a row.
    @Test func aRebuiltForkClosureAloneDoesNotChangeTheRenderedState() {
        var withOtherClosure = context()
        withOtherClosure.onFork = { _ in Issue.record("never called") }
        withOtherClosure.parentByMessageID = ["u2": "different"]
        #expect(context().renderedState == withOtherClosure.renderedState)
    }

    /// A rendered reply changing which message it rolls back to changes
    /// which rows show the buttons, so it has to restage.
    @Test func aNewRollbackTargetChangesTheRenderedState() {
        var withTarget = context()
        withTarget.rollbackTargetByReplyID = ["a1": "u2"]
        #expect(context().renderedState != withTarget.renderedState)
    }
}

/// Rolling back to a reply rewinds to the user message after it, since
/// `rewind_conversation` cuts before its target.
struct RollbackTargetTests {
    private func message(_ id: String, _ role: ChatMessage.Role) -> ChatMessage {
        ChatMessage(id: id, role: role, blocks: [], timestamp: nil)
    }

    @Test func eachReplyRollsBackToTheMessageAfterIt() {
        let targets = MessageRedoContext.rollbackTargets(in: [
            message("u1", .user), message("a1", .assistant),
            message("u2", .user), message("a2", .assistant),
            message("u3", .user), message("a3", .assistant)
        ])
        #expect(targets == ["a1": "u2", "a2": "u3"])
    }

    /// Only a turn's last reply gets the buttons: rolling back to an earlier
    /// one in the same turn would still cut at the same message.
    @Test func aTurnOfSeveralRepliesOffersOnlyItsLast() {
        let targets = MessageRedoContext.rollbackTargets(in: [
            message("u1", .user), message("a1", .assistant), message("a1b", .assistant),
            message("u2", .user)
        ])
        #expect(targets == ["a1b": "u2"])
    }

    /// A notice between a reply and the next message is the transcript's own
    /// aside, not a turn, so the reply still rolls back to that message.
    @Test func aNoticeBetweenAReplyAndTheNextMessageIsSkipped() {
        let targets = MessageRedoContext.rollbackTargets(in: [
            message("u1", .user), message("a1", .assistant), message("n1", .notice),
            message("u2", .user)
        ])
        #expect(targets == ["a1": "u2"])
    }

    @Test func theNewestReplyHasNothingToRollBack() {
        let targets = MessageRedoContext.rollbackTargets(in: [
            message("u1", .user), message("a1", .assistant)
        ])
        #expect(targets.isEmpty)
    }
}

/// The CLI writes no new tip after a rewind until the next turn, so the chat
/// applies the cut itself.
struct TranscriptRollbackTests {
    private func transcript(_ ids: [String]) -> Transcript {
        var transcript = Transcript()
        transcript.messages = ids.map { ChatMessage(id: $0, role: $0.hasPrefix("u") ? .user : .assistant, blocks: [], timestamp: nil) }
        return transcript
    }

    @Test func aRewindDropsTheCutMessageAndEverythingAfterIt() {
        let cut = transcript(["u1", "a1", "u2", "a2", "u3", "a3"]).rolledBack(before: "u2")
        #expect(cut.messages.map(\.id) == ["u1", "a1"])
    }

    /// The next turn appends under the rewind's tip, so the cut message
    /// leaves the live branch and the stale cut must stop applying.
    @Test func aCutMessageNoLongerOnTheBranchChangesNothing() {
        let next = transcript(["u1", "a1", "u4", "a4"])
        #expect(next.rolledBack(before: "u2") == next)
    }
}
