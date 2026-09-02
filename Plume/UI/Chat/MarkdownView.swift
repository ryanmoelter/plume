import SwiftUI

/// Renders parsed markdown with a system proportional font for prose —
/// monospace is reserved for code blocks and inline code, per the roadmap's
/// "don't use a monospace font" item. No WebKit; block layout is plain
/// SwiftUI stacks over `MarkdownBlock.parse`.
struct MarkdownView: View, ThemedView {
    @Environment(\.theme) var theme

    let blocks: [MarkdownBlock]

    init(_ markdown: String) {
        self.blocks = MarkdownCache.blocks(for: markdown)
    }

    init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    private var bodyFontSize: CGFloat { typography.bodySize }

    var body: some View {
        VStack(alignment: .leading, spacing: ChatMetrics.blockSpacing(forFontSize: bodyFontSize)) {
            // Indexed rather than `Array(blocks.enumerated())`: the
            // enumerated array is a fresh value every pass, which SwiftUI
            // cannot match against the previous children, so it evicts and
            // rebuilds the whole subtree. A trace caught this rebuilding
            // markdown blocks ~31,000 times over 15 seconds of scrolling.
            ForEach(blocks.indices, id: \.self) { index in
                render(blocks[index])
                    // A heading opening a message has nothing to separate from.
                    .padding(.top, headingTopSpacing(at: index))
            }
        }
        .textSelection(.enabled)
    }

    private func headingTopSpacing(at index: Int) -> CGFloat {
        guard index > 0, case let .heading(level, _) = blocks[index] else { return 0 }
        return ChatMetrics.headingTopSpacing(level: level, forFontSize: bodyFontSize)
    }

    @ViewBuilder
    private func render(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(headingFont(level: level))
                .fixedSize(horizontal: false, vertical: true)
                .listItemPadding(vertical: false)

        case let .paragraph(text):
            Text(inline(text))
                .font(typography.body.font)
                .lineSpacing(ChatMetrics.lineSpacing(forFontSize: bodyFontSize))
                .fixedSize(horizontal: false, vertical: true)
                .listItemPadding(vertical: false)

        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\u{2022}")
                        Text(inline(items[index]))
                    }
                    .font(typography.body.font)
                    .lineSpacing(ChatMetrics.lineSpacing(forFontSize: bodyFontSize))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .listItemPadding(vertical: false)

        case let .numberedList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).")
                        Text(inline(items[index]))
                    }
                    .font(typography.body.font)
                    .lineSpacing(ChatMetrics.lineSpacing(forFontSize: bodyFontSize))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .listItemPadding(vertical: false)

        case let .codeBlock(_, code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(typography.body.mono)
                    .foregroundStyle(codeForeground)
                    .padding(8)
            }
            .background(codeBackground, in: .rect(cornerRadius: 6))
            .listItemPadding(bleed: true, vertical: false)

        case let .quote(text):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(quoteBarColor)
                    .frame(width: 3)
                Text(inline(text))
                    .font(typography.body.font)
                    .emphasis(.secondary)
                    .lineSpacing(ChatMetrics.lineSpacing(forFontSize: bodyFontSize))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listItemPadding(vertical: false)

        case .rule:
            Rectangle()
                .fill(colors.divider)
                .frame(height: 1)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        MarkdownCache.styledInline(text, fontSize: bodyFontSize, tint: codeBackground)
    }

    /// Heading levels map to the type scale's own roles, preserving the
    /// original ladder's weight distinctions.
    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return typography.display.font
        case 2: return typography.headline.font
        case 3: return typography.title.font
        case 4: return typography.bodyLarge.font
        case 5: return typography.body.semibold
        default: return typography.caption.semibold
        }
    }

    private var codeBackground: Color {
        colors.surfaceTint
    }

    private var codeForeground: Color {
        colors.foreground
    }

    private var quoteBarColor: Color {
        colors.surface(.disabled)
    }
}
