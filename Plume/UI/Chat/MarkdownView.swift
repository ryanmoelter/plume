import SwiftUI

/// Renders parsed markdown with a system proportional font for prose —
/// monospace is reserved for code blocks and inline code, per the roadmap's
/// "don't use a monospace font" item. No WebKit; block layout is plain
/// SwiftUI stacks over `MarkdownBlock.parse`.
struct MarkdownView: View {
    @Environment(\.colorScheme) private var colorScheme

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
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\u{2022}")
                        Text(inline(item))
                    }
                    .font(.body)
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
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

        case let .codeBlock(_, code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
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
                    .font(.body)
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

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        case 4: return .headline
        case 5: return .subheadline.bold()
        default: return .callout.bold()
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
