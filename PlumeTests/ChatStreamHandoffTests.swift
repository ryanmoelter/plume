import Foundation
import Testing

@testable import Plume

/// The seam between the live stream and the transcript that replaces it.
/// Both a gap (nothing rendered) and a duplicate (both rendered) are bugs, so
/// each case here pins one side of that.
struct ChatStreamHandoffTests {
    private func message(_ blocks: [ChatBlock], role: ChatMessage.Role = .assistant) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, role: role, blocks: blocks, timestamp: nil)
    }

    @Test func liveTextRendersWhileTheTranscriptIsBehind() {
        let overlay = ChatStreamHandoff.overlay(
            streamedText: "Here is the ans",
            streamedThinking: "",
            transcriptTail: []
        )
        #expect(overlay.text == "Here is the ans")
    }

    /// The window that makes this hard: the turn has ended and the session
    /// still holds the text, but the debounced re-read has not happened.
    @Test func settledTextStillRendersUntilTheTranscriptCatchesUp() {
        let overlay = ChatStreamHandoff.overlay(
            streamedText: "Here is the answer.",
            streamedThinking: "",
            transcriptTail: ["An older paragraph."]
        )
        #expect(overlay.text == "Here is the answer.")
    }

    @Test func matchingTranscriptTextRetiresTheOverlay() {
        let overlay = ChatStreamHandoff.overlay(
            streamedText: "Here is the answer.",
            streamedThinking: "",
            transcriptTail: ["Here is the answer."]
        )
        #expect(overlay.text.isEmpty)
    }

    /// The transcript's own block often carries trailing whitespace the
    /// stream did not, which must not read as different text.
    @Test func trailingWhitespaceDoesNotBlockTheHandoff() {
        #expect(ChatStreamHandoff.isCoveredByTranscript("Done.", tail: ["Done.\n\n"]))
    }

    /// An interrupted turn leaves the stream holding a prefix of what Claude
    /// Code wrote to disk.
    @Test func aStreamedPrefixIsCoveredByTheFullTranscriptText() {
        #expect(ChatStreamHandoff.isCoveredByTranscript("Here is the ans", tail: ["Here is the answer."]))
    }

    @Test func emptyStreamedTextIsAlwaysCovered() {
        #expect(ChatStreamHandoff.isCoveredByTranscript("", tail: []))
        #expect(ChatStreamHandoff.isCoveredByTranscript("   \n", tail: []))
    }

    /// An empty transcript block must not swallow real streamed text.
    @Test func anEmptyTranscriptBlockDoesNotCover() {
        #expect(!ChatStreamHandoff.isCoveredByTranscript("Real text", tail: ["", "   "]))
    }

    @Test func aLaterBlockInTheSameMessageCovers() {
        #expect(ChatStreamHandoff.isCoveredByTranscript("Second.", tail: ["First.", "Second."]))
    }

    /// Thinking has no transcript counterpart to compare against while the
    /// turn runs, so it renders whenever the session holds it.
    @Test func thinkingPassesThroughUnfiltered() {
        let overlay = ChatStreamHandoff.overlay(
            streamedText: "done",
            streamedThinking: "Considering…",
            transcriptTail: ["done"]
        )
        #expect(overlay.thinking == "Considering…")
        #expect(overlay.text.isEmpty)
    }

    @Test func onlyATrailingAssistantMessageOffersTail() {
        let assistant = message([.markdown("hi")])
        let user = message([.markdown("hello")], role: .user)
        #expect(ChatStreamHandoff.trailingAssistantMarkdown([user, assistant]) == ["hi"])
        #expect(ChatStreamHandoff.trailingAssistantMarkdown([assistant, user]).isEmpty)
        #expect(ChatStreamHandoff.trailingAssistantMarkdown([]).isEmpty)
    }

    /// A notice appended after the reply must not hide the assistant text the
    /// overlay is being compared against — the tail is empty, so the overlay
    /// keeps rendering until the transcript's own assistant message is last
    /// again. Pinned because the alternative, searching back past notices,
    /// would double-render the reply above the notice.
    @Test func aTrailingNoticeYieldsNoTail() {
        let assistant = message([.markdown("hi")])
        let notice = message([.notice(ChatNotice(kind: .error, title: "API error", detail: nil))], role: .notice)
        #expect(ChatStreamHandoff.trailingAssistantMarkdown([assistant, notice]).isEmpty)
    }

    @Test func toolCallBlocksAreNotPartOfTheTail() {
        let call = ToolCall(id: "1", name: "Bash", summary: ToolCallSummary(name: "Bash", detail: "ls"), input: .json("{}"))
        #expect(ChatStreamHandoff.trailingAssistantMarkdown([message([.toolCall(call)])]).isEmpty)
    }
}
