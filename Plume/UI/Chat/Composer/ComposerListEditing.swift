import Foundation

/// Key-driven transforms for list items, headings, quotes, and code blocks
/// in the composer — Return, Tab, Shift-Tab, and Backspace at a paragraph's
/// start.
///
/// Pure `ComposerBlockKind` in, action out — no `NSTextView`, no mutation.
/// The integration layer supplies the current paragraph (and, for Tab, the
/// previous one) and carries out whatever action comes back.
nonisolated enum ComposerListEditing {
    struct Paragraph: Equatable {
        let kind: ComposerBlockKind
        /// Whether the paragraph has no non-whitespace text.
        let isEmpty: Bool
    }

    enum NewlineAction: Equatable {
        /// Enter mid-item or at the end of a non-empty item: a new paragraph
        /// with this kind (a numbered item's kind carries `number + 1`).
        case splitContinuing(kind: ComposerBlockKind)
        /// Enter on an empty item at depth 0: this paragraph becomes `.paragraph`, no split.
        case exitToParagraph
        /// Enter on an empty nested item: same paragraph, depth - 1.
        case outdent(kind: ComposerBlockKind)
        /// Enter inside a code block: a literal newline, same kind and blockID.
        case insertNewlineInBlock
        /// Enter on a heading, or on a non-empty quote line: a new `.paragraph`.
        case splitToParagraph
    }

    /// `caretIsAtEnd` distinguishes nothing in the current rule set — a
    /// non-empty list item splits the same way whether Enter lands mid-item
    /// or at its end — but is part of the contract for a caller that may
    /// need it later.
    static func newline(in paragraph: Paragraph, at caretIsAtEnd: Bool) -> NewlineAction {
        switch paragraph.kind.kind {
        case .codeBlock:
            return .insertNewlineInBlock

        case .heading:
            return .splitToParagraph

        case .quote:
            return paragraph.isEmpty ? .exitToParagraph : .splitToParagraph

        case let .bullet(depth):
            if paragraph.isEmpty {
                return depth == 0 ? .exitToParagraph : .outdent(kind: .bullet(depth: depth - 1))
            }
            return .splitContinuing(kind: .bullet(depth: depth))

        case let .numbered(depth, number):
            if paragraph.isEmpty {
                return depth == 0 ? .exitToParagraph : .outdent(kind: .numbered(depth: depth - 1, number: number))
            }
            return .splitContinuing(kind: .numbered(depth: depth, number: number + 1))

        case .paragraph, .verbatim:
            return .splitContinuing(kind: paragraph.kind)
        }
    }

    enum IndentAction: Equatable {
        case indent(kind: ComposerBlockKind)
        case none
    }

    /// Depth may only grow to the previous list item's depth + 1 — a list
    /// item can never indent deeper than one level under the item above it —
    /// and Tab is a no-op for a non-list paragraph or a first item with no
    /// previous list item to nest under.
    static func tab(in paragraph: Paragraph, previous: Paragraph?) -> IndentAction {
        guard let previous, previous.kind.isList else { return .none }
        let maxDepth = previous.kind.depth + 1

        switch paragraph.kind.kind {
        case let .bullet(depth):
            guard depth < maxDepth else { return .none }
            return .indent(kind: .bullet(depth: depth + 1))

        case let .numbered(depth, number):
            guard depth < maxDepth else { return .none }
            return .indent(kind: .numbered(depth: depth + 1, number: number))

        default:
            return .none
        }
    }

    /// Depth - 1; at depth 0 it's a no-op, since Backspace is what removes
    /// the item entirely.
    static func backtab(in paragraph: Paragraph) -> IndentAction {
        switch paragraph.kind.kind {
        case let .bullet(depth):
            guard depth > 0 else { return .none }
            return .indent(kind: .bullet(depth: depth - 1))

        case let .numbered(depth, number):
            guard depth > 0 else { return .none }
            return .indent(kind: .numbered(depth: depth - 1, number: number))

        default:
            return .none
        }
    }

    enum BackspaceAction: Equatable {
        /// A list item at depth 0, or a heading/quote, becomes `.paragraph`;
        /// a nested list item just loses one depth.
        case removeMarker(kind: ComposerBlockKind)
        case none
    }

    /// A no-op for a plain paragraph or inside a code block — leaving a code
    /// block is a different, explicit gesture, not Backspace at its first line.
    static func backspaceAtStart(of paragraph: Paragraph) -> BackspaceAction {
        switch paragraph.kind.kind {
        case let .bullet(depth):
            return .removeMarker(kind: depth > 0 ? .bullet(depth: depth - 1) : .paragraph)

        case let .numbered(depth, number):
            return .removeMarker(kind: depth > 0 ? .numbered(depth: depth - 1, number: number) : .paragraph)

        case .heading, .quote:
            return .removeMarker(kind: .paragraph)

        default:
            return .none
        }
    }
}
