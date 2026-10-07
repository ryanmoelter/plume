import SwiftUI

/// How much of another agent's message shows while it is collapsed.
enum AgentMessagePreviewMetrics {
    static let lineLimit = 10

    /// Wrapped lines the markdown would take at `width`, from a rough average
    /// glyph width. It only decides whether a message is long enough to cut,
    /// so being a line or two out costs nothing.
    static func estimatedLines(_ markdown: String, width: CGFloat) -> Int {
        let perLine = max(20, Int(width / 7))
        return markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + perLine - 1) / perLine) }
    }

    static func isCollapsible(_ markdown: String, width: CGFloat) -> Bool {
        estimatedLines(markdown, width: width) > lineLimit
    }
}

/// A collapsed agent message: its opening lines, faded out where they are
/// cut, as one piece in the chat list.
struct AgentMessagePreview: View, ThemedView {
    @Environment(\.theme) var theme

    let markdown: String

    /// Starts true because the splitter only collapses a message it expects
    /// to overflow; the measurement corrects it.
    @State private var isTruncated = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownView(markdown, isAgentVoice: true)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: Bool.self) { $0.size.height > maxHeight + 1 } action: { isTruncated = $0 }
                .frame(maxHeight: maxHeight, alignment: .top)
                .clipped()
                .mask { fade }
            if isTruncated {
                Label("Show the whole message", systemImage: "chevron.down")
                    .font(typography.caption.font)
                    .emphasis(.secondary)
                    .listItemPadding(vertical: false)
            }
        }
        // Over the text, which is selectable and would otherwise take the
        // click that expands the message.
        .overlay { Color.clear.contentShape(.rect) }
    }

    private var maxHeight: CGFloat {
        let line = proseTypography.body
        return CGFloat(AgentMessagePreviewMetrics.lineLimit) * (line.lineHeight + line.lineSpacing)
    }

    private var fade: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, isTruncated ? .clear : .black], startPoint: .top, endPoint: .bottom)
                .frame(height: proseTypography.body.lineHeight * 2)
        }
    }
}
