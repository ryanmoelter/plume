import Foundation

/// Decides what live text the chat should draw beneath the transcript, and
/// when the transcript has taken over.
///
/// The hard part is the seam. A turn's text arrives twice: first as stream
/// deltas, then as transcript lines the file watcher re-reads on a 250ms
/// debounce. Drop the stream the moment the turn's `result` lands and the
/// reply blinks out until the file catches up; keep it and the same paragraph
/// renders twice. So `HeadlessSession` retains the finished text rather than
/// clearing it, and this decides — from content, not from timing — whether the
/// transcript already shows it.
enum ChatStreamHandoff {
    /// What to draw below the last transcript message.
    struct Overlay: Equatable {
        var thinking: String = ""
        var text: String = ""

        var isEmpty: Bool { thinking.isEmpty && text.isEmpty }
    }

    /// - Parameters:
    ///   - streamedText: the session's live or just-settled assistant text.
    ///   - streamedThinking: the same for thinking.
    ///   - transcriptTail: the markdown of the transcript's trailing assistant
    ///     message, in order. Empty when the last message is not the agent's.
    static func overlay(
        streamedText: String,
        streamedThinking: String,
        transcriptTail: [String]
    ) -> Overlay {
        Overlay(
            thinking: streamedThinking,
            text: isCoveredByTranscript(streamedText, tail: transcriptTail) ? "" : streamedText
        )
    }

    /// The stream's prose split into what has settled and what is still
    /// growing.
    ///
    /// Only the last block can still change, so everything above it is handed
    /// to the list as ordinary markdown pieces and only the tail keeps
    /// revealing. This is what stops a long reply from being one item over a
    /// thousand points tall while it arrives.
    struct SettledStream: Equatable {
        var blocks: [MarkdownBlock] = []
        /// The raw source of the block still arriving.
        var tail: String = ""
        var tailBlock: MarkdownBlock?
    }

    static func settledBlocks(in text: String) -> SettledStream {
        let parsed = MarkdownBlock.parseWithSources(text)
        guard let last = parsed.last else { return SettledStream() }
        return SettledStream(
            blocks: parsed.dropLast().map(\.block),
            tail: last.source,
            tailBlock: last.block
        )
    }

    /// Whether the transcript already carries this streamed text.
    ///
    /// A prefix match rather than equality: the transcript's own block may
    /// carry trailing whitespace the stream did not, and a turn that ended
    /// early leaves the stream holding a prefix of what was written. Matching
    /// either way round means the overlay retires as soon as the same words
    /// exist on disk.
    static func isCoveredByTranscript(_ streamedText: String, tail: [String]) -> Bool {
        let streamed = normalize(streamedText)
        guard !streamed.isEmpty else { return true }
        return tail.contains { block in
            let text = normalize(block)
            guard !text.isEmpty else { return false }
            return text.hasPrefix(streamed) || streamed.hasPrefix(text)
        }
    }

    /// The trailing assistant message's markdown blocks, or nothing when the
    /// transcript's last message is a user turn or a notice.
    static func trailingAssistantMarkdown(_ messages: [ChatMessage]) -> [String] {
        guard let last = messages.last, last.role == .assistant else { return [] }
        return last.blocks.compactMap { block in
            if case .markdown(let text) = block { return text }
            return nil
        }
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
