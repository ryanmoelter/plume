import Foundation
import Testing

@testable import Plume

/// The rule that keeps an optimistic first message from double-rendering: it
/// shows until the transcript carries the same user prose, and never after.
struct OptimisticFirstMessageTests {
    private func userMessage(_ text: String, id: String = UUID().uuidString) -> ChatMessage {
        ChatMessage(id: id, role: .user, blocks: [.markdown(text)], timestamp: nil)
    }

    private func assistantMessage(_ text: String) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, role: .assistant, blocks: [.markdown(text)], timestamp: nil)
    }

    @Test func pendingMessageRendersWhileTranscriptIsEmpty() {
        let pending = OptimisticFirstMessage(text: "hello there")
        let rendered = OptimisticChatReconciler.messages(transcript: [], pending: pending)

        #expect(rendered.count == 1)
        #expect(rendered.first?.role == .user)
        #expect(rendered.first?.prose == "hello there")
    }

    @Test func transcriptAloneRendersWithoutAPendingMessage() {
        let transcript = [userMessage("hello there"), assistantMessage("hi")]
        let rendered = OptimisticChatReconciler.messages(transcript: transcript, pending: nil)

        #expect(rendered.map(\.id) == transcript.map(\.id))
    }

    @Test func theRealLineReplacesThePendingCopyRatherThanJoiningIt() {
        let pending = OptimisticFirstMessage(text: "hello there")
        let transcript = [userMessage("hello there")]
        let rendered = OptimisticChatReconciler.messages(transcript: transcript, pending: pending)

        #expect(rendered.count == 1)
        #expect(rendered.first?.id == transcript[0].id)
        #expect(!rendered.contains { $0.id == OptimisticFirstMessage.messageID })
    }

    @Test func whitespaceDifferencesStillCountAsTheSameLine() {
        let pending = OptimisticFirstMessage(text: "  hello there\n")
        let rendered = OptimisticChatReconciler.messages(
            transcript: [userMessage("hello there")],
            pending: pending
        )

        #expect(rendered.count == 1)
    }

    @Test func anAssistantEchoDoesNotRetireThePendingMessage() {
        let pending = OptimisticFirstMessage(text: "hello there")
        let rendered = OptimisticChatReconciler.messages(
            transcript: [assistantMessage("hello there")],
            pending: pending
        )

        #expect(rendered.count == 2)
        #expect(rendered.last?.id == OptimisticFirstMessage.messageID)
    }

    @Test func thePendingMessageTrailsATranscriptThatHasNotCaughtUp() {
        let pending = OptimisticFirstMessage(text: "second question")
        let transcript = [userMessage("first question"), assistantMessage("an answer")]
        let rendered = OptimisticChatReconciler.messages(transcript: transcript, pending: pending)

        #expect(rendered.count == 3)
        #expect(rendered.last?.prose == "second question")
    }

    @Test func aFailureRendersAsANoticeBesideTheMessage() {
        let pending = OptimisticFirstMessage(
            text: "hello there",
            failure: ChatStartFailure(title: "claude not found", detail: "PATH", remedy: .installCLI)
        )
        let rendered = OptimisticChatReconciler.messages(transcript: [], pending: pending)

        #expect(rendered.count == 2)
        #expect(rendered.first?.role == .user)
        #expect(rendered.last?.role == .notice)
    }

    @Test func aFailedStartKeepsItsMessageEvenOnceTheTranscriptArrives() {
        let pending = OptimisticFirstMessage(
            text: "hello there",
            failure: ChatStartFailure(title: "claude not found", detail: nil, remedy: .installCLI)
        )

        #expect(!OptimisticChatReconciler.isSettled(
            transcript: [userMessage("hello there")],
            pending: pending
        ))
    }

    @Test func settlingReportsOnlyOnceTheLineLands() {
        let pending = OptimisticFirstMessage(text: "hello there")

        #expect(!OptimisticChatReconciler.isSettled(transcript: [], pending: pending))
        #expect(OptimisticChatReconciler.isSettled(
            transcript: [userMessage("hello there")],
            pending: pending
        ))
        #expect(!OptimisticChatReconciler.isSettled(transcript: [], pending: nil))
    }

    @Test func proseIgnoresNonMarkdownBlocks() {
        let message = ChatMessage(
            id: "x",
            role: .user,
            blocks: [.injected(.userMessage, text: "injected"), .markdown("typed")],
            timestamp: nil
        )

        #expect(message.prose == "typed")
    }
}
