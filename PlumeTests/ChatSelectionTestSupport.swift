import Foundation
@testable import Plume

@MainActor
enum ChatSelectionFixtures {
    static func pieces(_ markdown: String, messageID: String = "m", role: ChatMessage.Role = .assistant) -> [ChatPiece] {
        ChatPieceSplitter.pieces(
            for: [ChatMessage(id: messageID, role: role, blocks: [.markdown(markdown)], timestamp: nil, isLive: false)],
            status: .awaitingReply,
            hiddenToolUseIDs: [],
            dimensions: Dimensions(bodySize: 13)
        )
    }

    static func selection(
        _ piece: ChatPiece,
        _ range: Range<Int>
    ) -> ChatSelection {
        ChatSelection(
            anchor: ChatTextPosition(pieceID: piece.id, offset: range.lowerBound),
            focus: ChatTextPosition(pieceID: piece.id, offset: range.upperBound)
        )
    }

    static func selection(
        from start: (ChatPiece, Int),
        to end: (ChatPiece, Int)
    ) -> ChatSelection {
        ChatSelection(
            anchor: ChatTextPosition(pieceID: start.0.id, offset: start.1),
            focus: ChatTextPosition(pieceID: end.0.id, offset: end.1)
        )
    }

    static func everything(_ pieces: [ChatPiece]) -> ChatSelection {
        selection(from: (pieces[0], 0), to: (pieces[pieces.count - 1], ChatSelectableText.length(of: pieces[pieces.count - 1])))
    }

    /// The UTF-16 range of `needle` in the piece's plain text.
    static func range(of needle: String, in piece: ChatPiece) -> Range<Int> {
        let text = ChatSelectableText(piece: piece).plainText as NSString
        let found = text.range(of: needle)
        return found.location..<(found.location + found.length)
    }
}
