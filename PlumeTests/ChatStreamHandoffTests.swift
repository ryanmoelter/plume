import Foundation
import Testing

@testable import Plume

/// The seam between the live stream and the transcript that replaces it.
/// Both a gap (nothing rendered) and a duplicate (both rendered) are bugs, so
/// each case here pins one side of that.
struct ChatStreamHandoffTests {
    private func message(
        _ id: String,
        _ blocks: [ChatBlock],
        role: ChatMessage.Role = .assistant
    ) -> ChatMessage {
        ChatMessage(id: id, role: role, blocks: blocks, timestamp: nil)
    }

    @Test func emptyLiveMessageLeavesTheTranscriptUnchanged() {
        let messages = [message("a", [.markdown("hi")])]
        #expect(ChatStreamHandoff.merge(messages, live: .init()) == messages)
    }

    @Test func liveTextMatchingAnIDMergesIntoThatMessage() {
        // The transcript has caught the thinking but not yet a markdown
        // block, which is the ordinary shape mid-turn.
        let messages = [message("a", [.thinking("Considering.")])]
        let merged = ChatStreamHandoff.merge(
            messages,
            live: .init(id: "a", text: "Here is the answer.")
        )
        #expect(merged.count == 1)
        #expect(merged[0].blocks == [.thinking("Considering."), .markdown("Here is the answer.")])
        #expect(merged[0].isLive)
    }

    /// Text is inserted before the first tool call, since that is where the
    /// stream's own reply belongs relative to what already followed it.
    @Test func liveTextIsInsertedBeforeTheFirstToolCall() {
        let call = ToolCall(id: "t1", name: "Bash", summary: ToolCallSummary(name: "Bash", detail: "ls"), input: .json("{}"))
        let messages = [message("a", [.toolCall(call)])]
        let merged = ChatStreamHandoff.merge(messages, live: .init(id: "a", text: "Reasoning first."))
        #expect(merged[0].blocks == [.markdown("Reasoning first."), .toolCall(call)])
    }

    @Test func liveThinkingIsInsertedAtTheStartWhenMissing() {
        let messages = [message("a", [.markdown("Here.")])]
        let merged = ChatStreamHandoff.merge(
            messages,
            live: .init(id: "a", thinking: "Considering…", text: "Here.")
        )
        #expect(merged[0].blocks == [.thinking("Considering…"), .markdown("Here.")])
    }

    @Test func existingThinkingIsNotDuplicated() {
        let messages = [message("a", [.thinking("Considering…"), .markdown("Here.")])]
        let merged = ChatStreamHandoff.merge(
            messages,
            live: .init(id: "a", thinking: "Considering…", text: "Here.")
        )
        #expect(merged[0].blocks == [.thinking("Considering…"), .markdown("Here.")])
    }

    /// The transcript's own block may carry trailing whitespace the stream
    /// did not, or the transcript already has the whole text while the
    /// stream holds a prefix of it.
    @Test func textAlreadyCoveredByTheTranscriptIsLeftUntouchedAndNotLive() {
        let messages = [message("a", [.markdown("Here is the answer.\n")])]
        let merged = ChatStreamHandoff.merge(
            messages,
            live: .init(id: "a", text: "Here is the ans")
        )
        #expect(merged == messages)
        #expect(!merged[0].isLive)
    }

    @Test func noMatchingIDAppendsANewAssistantMessage() {
        let messages = [message("a", [.markdown("done")])]
        let merged = ChatStreamHandoff.merge(
            messages,
            live: .init(id: "b", thinking: "hm", text: "On it.")
        )
        #expect(merged.count == 2)
        let appended = merged[1]
        #expect(appended.id == "b")
        #expect(appended.role == .assistant)
        #expect(appended.isLive)
        #expect(appended.blocks == [.thinking("hm"), .markdown("On it.")])
    }

    @Test func aLiveMessageWithNoIDUsesTheUnidentifiedID() {
        let merged = ChatStreamHandoff.merge([], live: .init(text: "On it."))
        #expect(merged.map(\.id) == [ChatStreamHandoff.unidentifiedLiveID])
    }

    /// An older CLI's stream names no message id at all, so it is matched by
    /// content against the trailing assistant message instead.
    @Test func unidentifiedLiveTextCoveredByTheTrailingAssistantMessageIsNotAppended() {
        let messages = [message("a", [.markdown("Here is the answer.")])]
        let merged = ChatStreamHandoff.merge(
            messages,
            live: .init(text: "Here is the ans")
        )
        #expect(merged == messages)
    }

    @Test func coversIgnoresTrailingWhitespace() {
        #expect(ChatStreamHandoff.covers([.markdown("Done.\n\n")], text: "Done."))
    }

    @Test func coversMatchesAStreamedPrefixAgainstTheFullText() {
        #expect(ChatStreamHandoff.covers([.markdown("Here is the answer.")], text: "Here is the ans"))
    }

    @Test func emptyStreamedTextIsAlwaysCovered() {
        #expect(ChatStreamHandoff.covers([], text: ""))
        #expect(ChatStreamHandoff.covers([], text: "   \n"))
    }

    @Test func anEmptyMarkdownBlockDoesNotCover() {
        #expect(!ChatStreamHandoff.covers([.markdown(""), .markdown("   ")], text: "Real text"))
    }
}
