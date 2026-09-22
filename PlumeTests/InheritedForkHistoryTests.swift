import Foundation
import Testing
@testable import Plume

/// A forked tab opens on the conversation it was cut from, because the CLI
/// writes the fork's own transcript only once its first turn produces content.
/// The inherited copy has to be retired exactly when that transcript carries
/// it — early blanks the conversation, late renders it twice.
@MainActor
struct InheritedForkHistoryTests {
    private func message(_ id: String, _ role: ChatMessage.Role = .user) -> ChatMessage {
        ChatMessage(id: id, role: role, blocks: [.markdown(id)], timestamp: nil)
    }

    private func transcript() -> Transcript {
        var transcript = Transcript()
        transcript.messages = [
            message("u1"), message("a1", .assistant),
            message("u2"), message("a2", .assistant),
        ]
        return transcript
    }

    private func history() -> InheritedForkHistory { InheritedForkHistory() }

    @Test func theConversationIsKeptThroughTheCutAndNoFurther() {
        let history = history()
        let tabID = UUID()
        history.adopt(from: transcript(), cutAfter: "a1", tabID: tabID)
        #expect(history.messages(forTab: tabID).map(\.id) == ["u1", "a1"])
    }

    /// The fork cuts at the target's parent, so the whole conversation being
    /// carried over is a legitimate cut, not a failure to cut.
    @Test func cuttingAtTheLastMessageKeepsEverything() {
        let history = history()
        let tabID = UUID()
        history.adopt(from: transcript(), cutAfter: "a2", tabID: tabID)
        #expect(history.messages(forTab: tabID).count == 4)
    }

    /// A cut point the transcript does not contain would otherwise silently
    /// inherit the whole conversation, which is not what was forked.
    @Test func anUnknownCutPointInheritsNothing() {
        let history = history()
        let tabID = UUID()
        history.adopt(from: transcript(), cutAfter: "nonexistent", tabID: tabID)
        #expect(history.messages(forTab: tabID).isEmpty)
    }

    /// `--fork-session` copies history with uuids preserved, so the last
    /// inherited id reappearing is what proves the fork's own file has caught
    /// up.
    @Test func theCopyRetiresOnceTheForkWritesTheSameMessages() {
        let history = history()
        let tabID = UUID()
        history.adopt(from: transcript(), cutAfter: "a1", tabID: tabID)
        history.settleIfCarried(by: [message("u1"), message("a1", .assistant)], tabID: tabID)
        #expect(history.messages(forTab: tabID).isEmpty)
    }

    /// The bug this guards: retiring on a partial first read would blank the
    /// conversation the tab just opened on.
    @Test func aPartiallyWrittenTranscriptKeepsTheCopy() {
        let history = history()
        let tabID = UUID()
        history.adopt(from: transcript(), cutAfter: "a1", tabID: tabID)
        history.settleIfCarried(by: [message("u1")], tabID: tabID)
        #expect(history.messages(forTab: tabID).map(\.id) == ["u1", "a1"])
    }

    @Test func aForgottenTabKeepsNothing() {
        let history = history()
        let tabID = UUID()
        history.adopt(from: transcript(), cutAfter: "a1", tabID: tabID)
        history.forget(tabID: tabID)
        #expect(history.messages(forTab: tabID).isEmpty)
    }

    @Test func oneTabsHistoryIsNotAnothers() {
        let history = history()
        let forked = UUID()
        history.adopt(from: transcript(), cutAfter: "a1", tabID: forked)
        #expect(history.messages(forTab: UUID()).isEmpty)
        #expect(!history.messages(forTab: forked).isEmpty)
    }
}
