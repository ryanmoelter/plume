import SwiftUI

/// Renders parsed markdown with a system proportional font for prose —
/// monospace is reserved for code blocks and inline code, per the roadmap's
/// "don't use a monospace font" item. No WebKit; block layout is plain
/// SwiftUI stacks over `MarkdownBlock.parse`.
struct MarkdownView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatFontSize) private var bodyFontSize

    let blocks: [MarkdownBlock]

    init(_ markdown: String) {
        self.blocks = MarkdownBlock.parse(markdown)
    }

    init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func render(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(headingFont(level: level))
                .fixedSize(horizontal: false, vertical: true)

        case let .paragraph(text):
            Text(inline(text))
                .font(bodyFont)
                .fixedSize(horizontal: false, vertical: true)

        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\u{2022}")
                        Text(inline(item))
                    }
                    .font(bodyFont)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

        case let .numberedList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1).")
                        Text(inline(item))
                    }
                    .font(bodyFont)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

        case let .codeBlock(_, code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: bodyFontSize, design: .monospaced))
                    .foregroundStyle(codeForeground)
                    .padding(8)
            }
            .background(codeBackground, in: .rect(cornerRadius: 6))

        case let .quote(text):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(quoteBarColor)
                    .frame(width: 3)
                Text(inline(text))
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .rule:
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 1)
        }
    }

    /// Inline-only parsing (bold, italic, inline code, links) while keeping
    /// single newlines inside the block instead of collapsing them.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        ))) ?? AttributedString(text)
    }

    private var bodyFont: Font {
        .chatProse(size: bodyFontSize)
    }

    /// Heading sizes as multiples of the body size, preserving the original
    /// ladder's proportions (title/title2/title3/headline/subheadline/callout
    /// against the system 13pt body) and weight distinctions.
    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .chatProse(size: bodyFontSize * 2.15, weight: .bold)
        case 2: return .chatProse(size: bodyFontSize * 1.7, weight: .bold)
        case 3: return .chatProse(size: bodyFontSize * 1.35, weight: .bold)
        case 4: return .chatProse(size: bodyFontSize * 1.15, weight: .semibold)
        case 5: return .chatProse(size: bodyFontSize * 1.0, weight: .semibold)
        default: return .chatProse(size: bodyFontSize * 0.85, weight: .semibold)
        }
    }

    private var codeBackground: Color {
        ThemeChrome.foreground(for: colorScheme)?.opacity(0.08) ?? Color.secondary.opacity(0.1)
    }

    private var codeForeground: Color {
        ThemeChrome.foreground(for: colorScheme) ?? .primary
    }

    private var quoteBarColor: Color {
        ThemeChrome.foreground(for: colorScheme)?.opacity(0.4) ?? Color.secondary.opacity(0.4)
    }
}
