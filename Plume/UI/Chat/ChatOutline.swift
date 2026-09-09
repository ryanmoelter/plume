import Foundation

/// The conversation reduced to what a minimap draws: the things the user
/// said or was asked, legible, with everything the agent produced between
/// them collapsed into de-emphasized mass.
///
/// The reader anchors on their own input — there is far less of it than agent
/// output — so those entries keep their text and a whole run of replies
/// between two of them becomes one weighted area.
struct ChatOutline: Equatable {
    var entries: [Entry] = []

    struct Entry: Equatable, Identifiable {
        /// The id of the piece to scroll to, which is the first of whatever
        /// this entry covers.
        var id: String
        /// The message this entry starts in, so a prompt long enough to split
        /// across pieces stays one landmark.
        var messageID: String
        var kind: Kind
        /// How much room this entry takes in the conversation, relative to
        /// the other entries. Never a measured layout height.
        var weight: CGFloat
        /// Every piece this entry stands for, so the panel can tell whether
        /// any of it is on screen.
        var pieceIDs: Set<String> = []
    }

    enum Kind: Equatable {
        /// Something the user typed, carrying its first line.
        case prompt(String)
        /// A question the agent asked, which is the user's turn to answer.
        case question(String)
        /// Everything the agent produced between two pieces of user input.
        case response

        /// Whether the user said this or was asked it, as opposed to the
        /// agent's own output.
        var isUserInput: Bool { self != .response }
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Guarded against zero so a caller can always divide by it.
    var totalWeight: CGFloat {
        max(1, entries.reduce(0) { $0 + $1.weight })
    }
}

/// Builds the outline from the same pieces the list renders.
///
/// Weight is a crude estimate — character count, plus a flat allowance for
/// the things that take room without carrying much text. It follows
/// `ChatPieceMetrics`' rule: nothing here may be fed by a measured layout
/// height, which is the feedback loop `docs/chat-list-hang.md` exists to
/// remove. The constants are meant to be tuned by eye.
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

    /// The floor for any entry, so a brief one is still clickable.
    static let minimumWeight: CGFloat = 20

    /// How much of a run's real size survives compression. Raising it makes
    /// the map more literal, lowering it more even.
    static let compressionScale: CGFloat = 60

    /// Compresses a raw weight logarithmically.
    ///
    /// Response lengths run to orders of magnitude — a one-line answer
    /// against a turn with forty tool calls — and at true scale the longest
    /// runs own the map while everything else is too small to read or click.
    /// Growth stays monotonic, so a longer run is always taller than a
    /// shorter one; it simply stops being proportional.
    static func compress(_ weight: CGFloat) -> CGFloat {
        guard weight > minimumWeight else { return minimumWeight }
        let excess = weight - minimumWeight
        return minimumWeight + compressionScale * log2(1 + excess / compressionScale)
    }

    static func outline(from pieces: [ChatPiece]) -> ChatOutline {
        var entries: [ChatOutline.Entry] = []

        for piece in pieces {
            // The stream stands in for a message the transcript has yet to
            // take over, and its pieces carry no real message id.
            guard !piece.isStreaming, piece.messageID != "stream" else { continue }
            let weight = self.weight(of: piece)

            if let kind = userInputKind(of: piece) {
                // A prompt long enough to split across pieces is still one
                // thing the user said, so the later pieces join the entry
                // rather than repeating it down the map. Its text and its
                // scroll target stay the first piece's, which is where the
                // prompt starts.
                if let last = entries.last, last.kind.isUserInput, last.messageID == piece.messageID {
                    entries[entries.count - 1].pieceIDs.insert(piece.id)
                    continue
                }
                entries.append(
                    ChatOutline.Entry(
                        id: piece.id,
                        messageID: piece.messageID,
                        kind: kind,
                        weight: weight,
                        pieceIDs: [piece.id]
                    )
                )
                continue
            }

            // Everything else is the agent working. A run of it between two
            // pieces of user input reads as one area, however many messages
            // the transcript split it into.
            if entries.last?.kind == .response {
                entries[entries.count - 1].weight += weight
                entries[entries.count - 1].pieceIDs.insert(piece.id)
            } else {
                entries.append(
                    ChatOutline.Entry(
                        id: piece.id,
                        messageID: piece.messageID,
                        kind: .response,
                        weight: weight,
                        pieceIDs: [piece.id]
                    )
                )
            }
        }

        for index in entries.indices {
            entries[index].weight = compress(entries[index].weight)
        }
        return ChatOutline(entries: entries)
    }

    /// What the user said or was asked, or nil for the agent's own output.
    ///
    /// The user's role alone is not the test. A transcript records plenty
    /// under that role that the user never typed — an interruption marker, a
    /// slash command's caveat and output, a background task reporting back —
    /// and anchoring on those would put a landmark where nothing was said.
    /// `InjectedContent.isUserProse` already draws that line for the chat, so
    /// the map follows it rather than inventing a second rule.
    private static func userInputKind(of piece: ChatPiece) -> ChatOutline.Kind? {
        if case .toolCall(let call, _) = piece.content,
           case .questions(let questions)? = call.interactive {
            // A question is the agent's message but the user's turn, so it
            // anchors like a prompt.
            return .question(questions.first?.question ?? "Question")
        }
        guard piece.role == .user else { return nil }
        switch piece.content {
        case .injected(let content, let text):
            return content.isUserProse ? .prompt(firstLine(of: text)) : nil
        case .markdown, .codeSegment, .listSegment, .image:
            return .prompt(firstLine(of: promptText(of: piece)))
        default:
            return nil
        }
    }

    /// The opening line, which is all the panel has room for.
    private static func firstLine(of text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private static func promptText(of piece: ChatPiece) -> String {
        switch piece.content {
        case .markdown(let block, _): text(of: block)
        case .codeSegment(let segment): segment.code
        case .listSegment(let segment): segment.items.first ?? ""
        case .injected(_, let text): text
        default: ""
        }
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
        let wrapped = CGFloat(text.count) / charactersPerLine
        let explicit = CGFloat(text.split(separator: "\n").count)
        return max(wrapped, explicit) * 24
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
