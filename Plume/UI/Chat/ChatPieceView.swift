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
    var animatesHeight: Bool = false
    /// Set for a piece that has just arrived, so it grows into place and
    /// pushes the pieces below it down.
    var growsFromZero: Bool = false
    /// Set for a block the stream has just opened, so it types itself out.
    var typesFromZero: Bool = false

    @State private var isHovered = false

    // One modifier chain for every wash, so a message gaining the
    // needs-input treatment changes values rather than structure. A `switch`
    // here would give the branches different identities, and every expanded
    // disclosure inside would collapse the moment the status changed.
    var body: some View {
        content
            .environment(\.chatHugsContent, piece.wash == .bubble)
            .frame(maxWidth: fillsColumn ? .infinity : nil, alignment: .leading)
            .padding(.top, insideInset)
            .padding(.horizontal, washPadding)
            .padding(.top, piece.segment.isFirst ? washPadding : 0)
            .padding(.bottom, piece.segment.isLast ? washPadding : 0)
            // Inside the wash, and outside the vertical padding it pays.
            // The wash then sizes to the animated frame, so a joined segment
            // cannot open a seam against its neighbour, and neither the
            // padding nor the segment this piece turns out to be — both
            // change when a neighbour does — jumps on its own.
            .animatedHeight(
                heightAnimation,
                initialHeight: growsFromZero ? 0 : nil,
                enabled: animatesHeight
            )
            .background(washFill, in: washShape)
            .overlay(alignment: .topTrailing) { copyButtons }
            .onHover { isHovered = $0 }
            .overlay {
                if piece.wash == .attention {
                    SegmentBorder(segment: piece.segment, radius: washRadius)
                        .stroke(attentionBorder, lineWidth: 1)
                }
            }
            // The wash sits directly on the blocks, and these frames only
            // position the result. Bounded text wraps and reports the width it
            // actually used, so the bubble hugs a short message and still
            // wraps a long one at reading measure. A message split across
            // several pieces takes the full column instead, so every segment
            // is the same width and the joined shape reads as one bubble.
            .frame(maxWidth: piece.wash == .bubble ? dimensions.contentWidth : nil, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: piece.wash == .bubble ? .trailing : .leading)
    }

    /// The whole reply on the first piece, the table on a table's own piece.
    /// A first piece that is a table offers both.
    @ViewBuilder
    private var copyButtons: some View {
        HStack(spacing: 2) {
            if let table = piece.tableCopySource {
                ChatCopyButton(markdown: table, isRevealed: isHovered, label: "Copy table as markdown")
            }
            if piece.offersMessageCopy, let message = piece.messageCopySource {
                ChatCopyButton(
                    markdown: message,
                    isRevealed: isHovered,
                    symbol: "text.document",
                    label: "Copy message as markdown"
                )
            }
        }
        .padding(4)
        // A hidden button still takes clicks, which would swallow a tap on
        // the text under it.
        .allowsHitTesting(isHovered)
    }

    @ViewBuilder
    private var content: some View {
        switch piece.content {
        case let .markdown(block, _):
            // Stable for a piece's whole life: a block the stream wrote keeps
            // its source until the transcript replaces it wholesale under new
            // ids, so this branch never flips underneath a live reveal.
            if let source = piece.streamSource {
                RevealedMarkdownBlock(
                    source: source,
                    isArriving: piece.isArriving,
                    typesFromZero: typesFromZero,
                    isAgentVoice: piece.isAgentVoice
                )
            } else {
                MarkdownBlockView(block: block, isAgentVoice: piece.isAgentVoice)
            }
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

    /// Shorter for a piece the turn in flight is still changing: its height
    /// steps at every line wrap while the reveal draws, so a longer ease
    /// would trail the text.
    private var heightAnimation: Animation {
        .easeOut(duration: piece.isLive ? 0.12 : 0.2)
    }

    /// A bubble of several pieces takes the whole column so every segment is
    /// the same width; one that is a whole message on its own hugs its text.
    private var fillsColumn: Bool {
        piece.wash == .bubble && piece.segment != .single
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

    private var washFill: Color {
        switch piece.wash {
        case .none: .clear
        case .bubble: colors.surfaceTint
        case .attention: colors.attention.emphasized(.backgroundTint, in: colors)
        }
    }

    private var attentionBorder: Color {
        colors.attention.emphasized(.disabled, in: colors)
    }

    private var washPadding: CGFloat { piece.wash == .none ? 0 : 10 }
    private var washRadius: CGFloat { 10 }
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
        // stroke sits inside the wash rather than straddling its edge — but
        // only on the edges this segment owns, or the sides would stop half a
        // point short either side of every join and leave a break.
        let box = CGRect(
            x: rect.minX + 0.5,
            y: rect.minY + (segment.isFirst ? 0.5 : 0),
            width: rect.width - 1,
            height: rect.height
                - (segment.isFirst ? 0.5 : 0)
                - (segment.isLast ? 0.5 : 0)
        )
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

#Preview {
    let dimensions = Dimensions(bodySize: 13)
    let messages = [
        ChatMessage(id: "1", role: .user, blocks: [.markdown("Fix the build")], timestamp: nil),
        ChatMessage(
            id: "2",
            role: .user,
            blocks: [.markdown("A longer note that runs to several blocks.\n\nSo its bubble is drawn once per piece and has to join back up without a seam.")],
            timestamp: nil
        ),
        ChatMessage(id: "3", role: .assistant, blocks: [.markdown("Working on it.")], timestamp: nil),
        ChatMessage(
            id: "4",
            role: .assistant,
            blocks: [.markdown("Should I proceed?\n\nThe change touches three files.")],
            timestamp: nil
        )
    ]
    let pieces = ChatPieceSplitter.pieces(
        for: messages,
        status: .questionAsked,
        hiddenToolUseIDs: [],
        streaming: ChatStreamHandoff.Overlay(),
        dimensions: dimensions
    )
    return VStack(alignment: .leading, spacing: 0) {
        ForEach(pieces) { piece in
            ChatPieceView(piece: piece)
                .listItemPadding(bleed: true, column: .unpadded, vertical: false)
                .padding(.top, piece.paysInsetOutside ? piece.topInset : 0)
                .padding(.bottom, piece.bottomInset)
        }
    }
    .padding()
    .frame(width: 560)
}
