import Foundation

/// Merges the reply the stream is writing into the transcript's messages, so
/// the chat draws one list whichever source a message came from.
///
/// A turn's text arrives twice: first as stream deltas, then as transcript
/// lines the file watcher re-reads on a 250ms debounce. Both carry the API
/// message id, and the transcript keys an assistant message by it, so the live
/// reply is simply that message before the transcript has caught up —
/// `HeadlessSession` retains the finished text until it has.
enum ChatStreamHandoff {
    /// The message the stream is writing.
    struct LiveMessage: Equatable {
        var id: String?
        var thinking: String = ""
        var text: String = ""

        var isEmpty: Bool { thinking.isEmpty && text.isEmpty }
    }

    /// Stands in for a stream that never said which message it is writing.
    static let unidentifiedLiveID = "live"

    static func merge(_ messages: [ChatMessage], live: LiveMessage) -> [ChatMessage] {
        guard !live.isEmpty else { return messages }
        var messages = messages

        if let id = live.id,
           let index = messages.lastIndex(where: { $0.id == id && $0.role == .assistant }) {
            messages[index] = merged(messages[index], live: live)
            return messages
        }

        // The transcript wrote the message under an id the stream never
        // named — an older CLI, say. Match by content instead.
        if let last = messages.indices.last, messages[last].role == .assistant,
           covers(messages[last].blocks, text: live.text),
           live.thinking.isEmpty || messages[last].blocks.contains(where: \.isThinking) {
            return messages
        }

        var blocks: [ChatBlock] = []
        if !live.thinking.isEmpty { blocks.append(.thinking(live.thinking)) }
        if !live.text.isEmpty { blocks.append(.markdown(live.text)) }
        messages.append(ChatMessage(
            id: live.id ?? unidentifiedLiveID,
            role: .assistant,
            blocks: blocks,
            timestamp: nil,
            isLive: true
        ))
        return messages
    }

    /// The transcript's copy of the message with whatever the stream has that
    /// it does not yet. Claude Code writes a line per finished content block,
    /// so the transcript can hold the thinking while the text still streams.
    private static func merged(_ message: ChatMessage, live: LiveMessage) -> ChatMessage {
        var message = message
        let textIsCovered = covers(message.blocks, text: live.text)
        if !live.thinking.isEmpty, !message.blocks.contains(where: \.isThinking) {
            message.blocks.insert(.thinking(live.thinking), at: 0)
        }
        if !textIsCovered {
            // Text comes after the thinking and before any tool call.
            let index = message.blocks.firstIndex(where: \.isToolCall) ?? message.blocks.endIndex
            message.blocks.insert(.markdown(live.text), at: index)
            message.isLive = true
        }
        return message
    }

    /// Whether the transcript already carries this streamed text.
    ///
    /// A prefix match rather than equality: the transcript's own block may
    /// carry trailing whitespace the stream did not, and a turn that ended
    /// early leaves the stream holding a prefix of what was written.
    static func covers(_ blocks: [ChatBlock], text streamedText: String) -> Bool {
        let streamed = normalize(streamedText)
        guard !streamed.isEmpty else { return true }
        return blocks.contains { block in
            guard case .markdown(let markdown) = block else { return false }
            let text = normalize(markdown)
            guard !text.isEmpty else { return false }
            return text.hasPrefix(streamed) || streamed.hasPrefix(text)
        }
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension ChatBlock {
    var isThinking: Bool {
        if case .thinking = self { return true }
        return false
    }

    var isToolCall: Bool {
        if case .toolCall = self { return true }
        return false
    }
}
