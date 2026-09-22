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
        abandoned: [String: Int] = [:]
    ) -> MessageRedoContext {
        MessageRedoContext(
            tabID: Self.tabID,
            lastSeenUserMessageID: lastSeenUserMessageID,
            parentByMessageID: ["u2": "a1"],
            onFork: { _ in },
            abandonedCountByMessageID: abandoned
        )
    }

    private static let tabID = UUID()

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
