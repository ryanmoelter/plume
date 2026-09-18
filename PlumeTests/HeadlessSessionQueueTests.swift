import Foundation
import Testing
@testable import Plume

/// Covers `HeadlessSession`'s message queue without starting a real process.
/// With no process to write to, `submit(text:)` keeps the text queued rather
/// than dropping it, so both messages land in the queue and
/// `removeQueuedMessage(at:)` can be exercised against it.
@MainActor
struct HeadlessSessionQueueTests {
    private func makeSession() -> HeadlessSession {
        HeadlessSession(tabID: UUID(), taskID: UUID())
    }

    @Test func removeQueuedMessageReturnsAndRemovesTheText() {
        let session = makeSession()
        session.submit(text: "first")
        session.submit(text: "second")
        #expect(session.queuedMessages.map(\.plainText) == ["first", "second"])

        let removed = session.removeQueuedMessage(at: 1)

        #expect(removed?.plainText == "second")
        #expect(session.queuedMessages.map(\.plainText) == ["first"])
    }

    /// An image alone is a turn worth keeping, and recalling it has to hand
    /// the image back or the attachment is lost on an edit.
    @Test func anImageOnlyTurnQueuesAndComesBackWhole() {
        let session = makeSession()
        let image = ChatImage(mediaType: "image/png", base64: "abc")

        session.submit(blocks: [.image(image)])

        #expect(session.queuedMessages.count == 1)
        #expect(session.removeQueuedMessage(at: 0) == [.image(image)])
    }

    @Test func anEmptyTurnIsNotQueued() {
        let session = makeSession()

        session.submit(blocks: [.text("   ")])

        #expect(session.queuedMessages.isEmpty)
    }

    @Test func removeQueuedMessageReturnsNilForOutOfRangeIndex() {
        let session = makeSession()
        session.submit(text: "first")
        session.submit(text: "second")

        let removed = session.removeQueuedMessage(at: 5)

        #expect(removed == nil)
        #expect(session.queuedMessages.map(\.plainText) == ["first", "second"])
    }
}

/// ⌥↩ in the plan footer approves and passes the typed note along. The note
/// travels as a user turn rather than on the permission response, because
/// `ExitPlanMode` declares no input fields and would drop it silently.
@MainActor
struct ApprovePlanWithFeedbackTests {
    private func planPermission() -> PendingPermission {
        PendingPermission(
            id: "req-1",
            toolName: "ExitPlanMode",
            displayName: "ExitPlanMode",
            input: [:],
            description: nil,
            decisionReason: nil,
            toolUseID: "toolu_1",
            agentID: nil,
            interactive: nil
        )
    }

    @Test func theFeedbackTravelsAsAUserTurnAndTheApprovalIsUnchanged() {
        let session = HeadlessSession(tabID: UUID(), taskID: UUID())

        session.approvePlan(planPermission(), feedback: "Keep the scope to the parser")

        #expect(session.queuedMessages.map(\.plainText) == ["Keep the scope to the parser"])
        #expect(session.pendingPermissions.isEmpty)
    }

    /// Approving must leave plan mode, or the session stays in `plan` and
    /// never starts work.
    @Test func approvingWithFeedbackStillSwitchesToAutoMode() {
        let session = HeadlessSession(tabID: UUID(), taskID: UUID())

        session.approvePlan(planPermission(), feedback: "Go ahead")

        #expect(session.permissionMode == .auto)
    }

    @Test func blankFeedbackSendsNoTurnAtAll() {
        let session = HeadlessSession(tabID: UUID(), taskID: UUID())

        session.approvePlan(planPermission(), feedback: "   ")

        #expect(session.queuedMessages.isEmpty)
    }
}

/// A send that cannot reach a process must keep the user's text and say so,
/// rather than reporting a turn that never started. Losing the message to a
/// silent drop is what made a dead session look like a hang.
@MainActor
struct HeadlessSessionDeadProcessTests {
    @Test func submittingWithNoProcessKeepsTheTextAndReportsIt() {
        let session = HeadlessSession(tabID: UUID(), taskID: UUID())

        session.submit(text: "hello")

        #expect(session.queuedMessages.map(\.plainText) == ["hello"])
        #expect(session.isWorking == false)
        #expect(session.lastError != nil)
    }
}
