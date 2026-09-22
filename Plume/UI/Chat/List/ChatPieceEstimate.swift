import Foundation

/// A first guess at a piece's height, used only until it measures.
///
/// Crude on purpose: it decides where an unrealized item sits until it is
/// realized, nothing more. Nothing here reads a layout result.
enum ChatPieceEstimate {
    static func height(of piece: ChatPiece, width: CGFloat) -> CGFloat {
        let base: CGFloat = switch piece.content {
        case let .markdown(block, _):
            switch block {
            case let .paragraph(text): prose(text, width: width)
            case .heading: 32
            case let .list(items): CGFloat(items.count) * 24
            case let .codeBlock(_, code): lines(in: code) * 17 + 56
            case let .quote(text, _): prose(text, width: width)
            case let .table(_, _, rows): CGFloat(rows.count + 1) * 26
            case .rule: 20
            }
        case let .codeSegment(segment):
            lines(in: segment.code) * 17 + 56
        case let .listSegment(segment):
            CGFloat(segment.items.count) * 24
        case .thinking, .toolCall, .injected, .working, .agentMessageTitle:
            27
        case .notice:
            30
        case .image:
            200
        case .streaming:
            60
        }
        return max(1, base) + (piece.wash == .none ? 0 : 20)
    }

    private static func prose(_ text: String, width: CGFloat) -> CGFloat {
        let charactersPerLine = max(20, width / 7)
        let lines = ceil(CGFloat(text.count) / charactersPerLine)
        return max(1, lines) * 22
    }

    private static func lines(in text: String) -> CGFloat {
        CGFloat(text.count(where: { $0 == "\n" }) + 1)
    }
}
