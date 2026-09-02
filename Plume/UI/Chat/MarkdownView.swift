import SwiftUI

/// Renders parsed markdown with a system proportional font for prose —
/// monospace is reserved for code blocks and inline code, per the roadmap's
/// "don't use a monospace font" item. No WebKit; block layout is plain
/// SwiftUI stacks over `MarkdownBlock.parse`.
struct MarkdownView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatFontSize) private var bodyFontSize
    @Environment(\.chatProseFace) private var proseFace

    let blocks: [MarkdownBlock]

    init(_ markdown: String) {
        self.blocks = MarkdownCache.blocks(for: markdown)
    }

    init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Indexed rather than `Array(blocks.enumerated())`: the
            // enumerated array is a fresh value every pass, which SwiftUI
            // cannot match against the previous children, so it evicts and
            // rebuilds the whole subtree. A trace caught this rebuilding
            // markdown blocks ~31,000 times over 15 seconds of scrolling.
            ForEach(blocks.indices, id: \.self) { index in
                render(blocks[index])
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
                .listItemPadding(vertical: false)

        case let .paragraph(text):
            Text(inline(text))
                .font(bodyFont)
                .fixedSize(horizontal: false, vertical: true)
                .listItemPadding(vertical: false)

        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\u{2022}")
                        Text(inline(items[index]))
                    }
                    .font(bodyFont)
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
                    .font(bodyFont)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .listItemPadding(vertical: false)

        case let .codeBlock(_, code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: bodyFontSize, design: .monospaced))
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
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listItemPadding(vertical: false)

        case .rule:
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 1)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        MarkdownCache.inline(text)
    }

    private var bodyFont: Font {
        prose(size: bodyFontSize)
    }

    /// Prose in whichever face the environment asks for.
    private func prose(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch proseFace {
        case .serif: return .chatProse(size: size, weight: weight)
        case .system: return .system(size: size, weight: weight)
        }
    }

    /// Heading sizes as multiples of the body size, preserving the original
    /// ladder's proportions (title/title2/title3/headline/subheadline/callout
    /// against the system 13pt body) and weight distinctions.
    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return prose(size: bodyFontSize * 2.15, weight: .bold)
        case 2: return prose(size: bodyFontSize * 1.7, weight: .bold)
        case 3: return prose(size: bodyFontSize * 1.35, weight: .bold)
        case 4: return prose(size: bodyFontSize * 1.15, weight: .semibold)
        case 5: return prose(size: bodyFontSize * 1.0, weight: .semibold)
        default: return prose(size: bodyFontSize * 0.85, weight: .semibold)
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
