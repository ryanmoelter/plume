import SwiftUI

/// One lazy item of the chat list, in the roadmap's two treatments: a quiet,
/// indented wash for the user, full-width prose for Claude.
///
/// A message's wash is drawn per piece, with only the corners and edges that
/// piece owns, so several pieces read as one bubble — see `ChatPieceSplitter`
/// for why a message is more than one item.
struct ChatPieceView: View, ThemedView {
    @Environment(\.theme) var theme

    let piece: ChatPiece

    var body: some View {
        switch piece.wash {
        case .none:
            content
        case .bubble:
            bubble
        case .attention:
            attention
        }
    }

    private var bubble: some View {
        content
            // The wash sits directly on the blocks, and the frames only
            // position the result. Bounded text wraps and reports the width it
            // actually used, so the bubble hugs a short message and still
            // wraps a long one at reading measure. A message split across
            // several pieces takes the full column instead, so every segment
            // is the same width and the joined shape reads as one bubble.
            .environment(\.chatHugsContent, true)
            .frame(maxWidth: piece.segment == .single ? nil : .infinity, alignment: .leading)
            .padding(.top, insideInset)
            .padding(.horizontal, washPadding)
            .padding(.top, piece.segment.isFirst ? washPadding : 0)
            .padding(.bottom, piece.segment.isLast ? washPadding : 0)
            .background(colors.surfaceTint, in: washShape)
            .frame(maxWidth: dimensions.contentWidth, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var attention: some View {
        content
            .padding(.top, insideInset)
            .padding(.horizontal, washPadding)
            .padding(.top, piece.segment.isFirst ? washPadding : 0)
            .padding(.bottom, piece.segment.isLast ? washPadding : 0)
            .background(attentionWash, in: washShape)
            .overlay {
                SegmentBorder(segment: piece.segment, radius: washRadius)
                    .stroke(attentionBorder, lineWidth: 1)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch piece.content {
        case let .markdown(block, _):
            MarkdownBlockView(block: block, isAgentVoice: piece.isAgentVoice)
        case let .codeSegment(segment):
            CodeSegmentView(segment: segment)
        case let .listSegment(segment):
            ListSegmentView(segment: segment, isAgentVoice: piece.isAgentVoice)
        case let .thinking(text):
            ThinkingRow(text: text)
        case let .toolCall(call, isPending):
            ToolCallRow(call: call, isPending: isPending)
        case let .injected(kind, text):
            InjectedContentRow(kind: kind, text: text)
        case let .notice(notice):
            ChatNoticeRow(notice: notice)
        case let .image(image):
            ChatImageView(image: image)
        case let .streaming(overlay):
            StreamingBlocks(overlay: overlay)
        case .working:
            ChatWorkingIndicator()
        }
    }

    /// The gap above a piece whose wash continues upwards, painted as wash so
    /// the joined shape has no break in it. The list pays the rest outside.
    private var insideInset: CGFloat {
        piece.paysInsetOutside ? 0 : piece.topInset
    }

    private var washShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: piece.segment.isFirst ? washRadius : 0,
            bottomLeadingRadius: piece.segment.isLast ? washRadius : 0,
            bottomTrailingRadius: piece.segment.isLast ? washRadius : 0,
            topTrailingRadius: piece.segment.isFirst ? washRadius : 0
        )
    }

    private var washPadding: CGFloat { 10 }
    private var washRadius: CGFloat { 10 }

    private var attentionWash: Color {
        colors.attention.emphasized(.backgroundTint, in: colors)
    }

    private var attentionBorder: Color {
        colors.attention.emphasized(.disabled, in: colors)
    }
}

/// The edges of a wash that one piece owns: both sides always, the top and
/// its corners only where the wash starts, the bottom only where it ends.
///
/// An open path rather than a rectangle, so a middle piece strokes its two
/// sides and draws nothing across the joins.
private struct SegmentBorder: Shape {
    let segment: ChatPiece.Segment
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        // Inset by half the line width, matching `strokeBorder`, so the
        // stroke sits inside the wash rather than straddling its edge.
        let box = rect.insetBy(dx: 0.5, dy: 0.5)
        let top = segment.isFirst ? radius : 0
        let bottom = segment.isLast ? radius : 0
        var path = Path()

        path.move(to: CGPoint(x: box.minX, y: box.maxY - bottom))
        path.addLine(to: CGPoint(x: box.minX, y: box.minY + top))
        if segment.isFirst {
            path.addArc(
                center: CGPoint(x: box.minX + radius, y: box.minY + radius),
                radius: radius,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: box.maxX - radius, y: box.minY))
            path.addArc(
                center: CGPoint(x: box.maxX - radius, y: box.minY + radius),
                radius: radius,
                startAngle: .degrees(270),
                endAngle: .degrees(360),
                clockwise: false
            )
        } else {
            path.move(to: CGPoint(x: box.maxX, y: box.minY))
        }
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - bottom))
        guard segment.isLast else { return path }

        path.addArc(
            center: CGPoint(x: box.maxX - radius, y: box.maxY - radius),
            radius: radius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: box.minX + radius, y: box.maxY))
        path.addArc(
            center: CGPoint(x: box.minX + radius, y: box.maxY - radius),
            radius: radius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        return path
    }
}
