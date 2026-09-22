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
}
