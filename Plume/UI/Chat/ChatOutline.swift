import Foundation

/// The conversation reduced to what a minimap draws: the user's own messages,
/// legible, with the agent's replies as de-emphasized mass between them.
///
/// The reader anchors on their own prompts — there are far fewer of those than
/// agent responses — so a prompt keeps its text and everything else collapses
/// into a weight.
struct ChatOutline: Equatable {
    var entries: [Entry] = []

    struct Entry: Equatable, Identifiable {
        /// The id of the piece to scroll to, which is the message's first.
        var id: String
        var messageID: String
        var kind: Kind
        /// How much room this entry's message takes in the conversation,
        /// relative to the other entries. Never a measured layout height.
        var weight: CGFloat
    }

    enum Kind: Equatable {
        /// Carries the prompt's first line, which the minimap renders.
        case prompt(String)
        case response
        case notice
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Every entry's weight as a fraction of the whole conversation, so the
    /// panel can lay itself out without knowing the totals.
    var totalWeight: CGFloat {
        max(1, entries.reduce(0) { $0 + $1.weight })
    }
}

/// Builds the outline from the same pieces the list renders.
///
/// Weight is a crude estimate — character count, plus a flat allowance for the
/// things that take room without carrying much text. It follows
/// `ChatPieceMetrics`' rule: nothing here may be fed by a measured layout
/// height, which is the feedback loop `docs/chat-list-hang.md` exists to
/// remove. The constants are meant to be tuned by eye against a real
/// conversation.
enum ChatOutlineBuilder {
    /// Roughly the characters a line of the chat's reading measure holds,
    /// borrowed from `ChatPieceMetrics`' own estimate.
    static let charactersPerLine: CGFloat = 60

    /// What a collapsed tool call is worth. It draws one short row whatever
    /// it contains, so its text length says nothing about its height.
    static let toolCallWeight: CGFloat = 40

    /// A code block is denser and taller per character than prose, and a long
    /// one is bounded rather than growing without limit.
    static let codeBlockWeight: CGFloat = 120

    /// An image draws at a fixed size regardless of its payload, whose
    /// characters are base64 and would otherwise dwarf everything.
    static let imageWeight: CGFloat = 200

    /// The floor for any message, so a one-word reply is still clickable.
    static let minimumWeight: CGFloat = 20

    static func outline(from pieces: [ChatPiece]) -> ChatOutline {
        var entries: [ChatOutline.Entry] = []
        for piece in pieces {
            // The stream stands in for a message the transcript has yet to
            // take over, and its pieces carry no real message id.
            guard !piece.isStreaming, piece.messageID != "stream" else { continue }
            let weight = self.weight(of: piece)
            if entries.last?.messageID == piece.messageID {
                entries[entries.count - 1].weight += weight
            } else {
                entries.append(
                    ChatOutline.Entry(
                        id: piece.id,
                        messageID: piece.messageID,
                        kind: kind(of: piece),
                        weight: weight
                    )
                )
            }
        }
        for index in entries.indices {
            entries[index].weight = max(minimumWeight, entries[index].weight)
        }
        return ChatOutline(entries: entries)
    }

    private static func kind(of piece: ChatPiece) -> ChatOutline.Kind {
        switch piece.role {
        case .user: .prompt(firstLine(of: piece))
        case .assistant: .response
        case .notice: .notice
        }
    }

    /// The prompt's opening line, which is all the panel has room for. A
    /// prompt that opens with a heading or a list still reads as its text.
    private static func firstLine(of piece: ChatPiece) -> String {
        let text = switch piece.content {
        case .markdown(let block, _): self.text(of: block)
        case .codeSegment(let segment): segment.code
        case .listSegment(let segment): segment.items.first ?? ""
        case .injected(_, let text): text
        default: ""
        }
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func weight(of piece: ChatPiece) -> CGFloat {
        switch piece.content {
        case .markdown(let block, _):
            proseWeight(of: text(of: block), block: block)
        case .codeSegment:
            codeBlockWeight
        case .listSegment(let segment):
            proseWeight(of: segment.items.joined(separator: "\n"), block: nil)
        case .thinking(let text):
            proseWeight(of: text, block: nil)
        case .toolCall:
            toolCallWeight
        case .injected(_, let text):
            proseWeight(of: text, block: nil)
        case .notice(let notice):
            proseWeight(of: notice.title, block: nil)
        case .image:
            imageWeight
        case .streaming, .working:
            0
        }
    }

    /// Lines of reading measure, scaled so a weight reads as points of height
    /// rather than as a character count.
    private static func proseWeight(of text: String, block: MarkdownBlock?) -> CGFloat {
        if case .codeBlock = block { return codeBlockWeight }
        let lines = CGFloat(text.count) / charactersPerLine
        let explicit = CGFloat(text.split(separator: "\n").count)
        return max(lines, explicit) * 24
    }

    private static func text(of block: MarkdownBlock) -> String {
        switch block {
        case .heading(_, let text): text
        case .paragraph(let text): text
        case .bulletList(let items): items.joined(separator: "\n")
        case .numberedList(let items, _): items.joined(separator: "\n")
        case .codeBlock(_, let code): code
        case .quote(let text): text
        case .table(let header, _, let rows):
            (header + rows.flatMap { $0 }).joined(separator: " ")
        case .rule: ""
        }
    }
}
