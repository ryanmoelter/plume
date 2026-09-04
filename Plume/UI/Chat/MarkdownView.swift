import SwiftUI

/// Renders parsed markdown with a proportional font for prose — monospace is
/// reserved for code blocks and inline code, per the roadmap's "don't use a
/// monospace font" item. No WebKit; block layout is plain SwiftUI stacks over
/// `MarkdownBlock.parse`.
struct MarkdownView: View, ThemedView {
    @Environment(\.theme) var theme

    let blocks: [MarkdownBlock]
    /// Whether this is the agent speaking, which earns the serif. Anything
    /// else — the user's own message, a tool's output — stays in the system
    /// face so it reads as input rather than published prose.
    let isAgentVoice: Bool

    init(_ markdown: String, isAgentVoice: Bool = false) {
        self.blocks = MarkdownCache.blocks(for: markdown)
        self.isAgentVoice = isAgentVoice
    }

    init(blocks: [MarkdownBlock], isAgentVoice: Bool = false) {
        self.blocks = blocks
        self.isAgentVoice = isAgentVoice
    }

    /// The scale this view's prose renders in.
    private var prose: Typography {
        isAgentVoice ? proseTypography : typography
    }

    var body: some View {
        VStack(alignment: .leading, spacing: dimensions.blockSpacing) {
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
        return dimensions.headingTopSpacing(level: level)
    }

    @ViewBuilder
    private func render(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(heading(text, level: level))
                .font(headingFont(level: level))
                .fixedSize(horizontal: false, vertical: true)
                .listItemPadding(vertical: false)

        case let .paragraph(text):
            Text(inline(text))
                .font(prose.body.font)
                .lineSpacing(prose.body.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .listItemPadding(vertical: false)

        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\u{2022}")
                        Text(inline(items[index]))
                    }
                    .font(prose.body.font)
                    .lineSpacing(prose.body.lineSpacing)
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
                    .font(prose.body.font)
                    .lineSpacing(prose.body.lineSpacing)
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
                    .font(prose.body.font)
                    .emphasis(.secondary)
                    .lineSpacing(prose.body.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listItemPadding(vertical: false)

        case let .table(header, alignments, rows):
            let hasHeader = MarkdownBlock.headerIsMeaningful(header)
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                if hasHeader {
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            Text(inline(header[column]))
                                .font(prose.body.semibold)
                                .fixedSize(horizontal: false, vertical: true)
                                .gridColumnAlignment(gridAlignment(alignments, at: column))
                        }
                    }
                    Rectangle()
                        .fill(colors.divider)
                        .frame(height: 1)
                        .gridCellColumns(max(header.count, 1))
                }
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(rows[row].indices, id: \.self) { column in
                            let cell = Text(inline(rows[row][column]))
                                .font(prose.body.font)
                                .lineSpacing(prose.body.lineSpacing)
                                .fixedSize(horizontal: false, vertical: true)
                            // `gridColumnAlignment` binds per column, so
                            // without a header row the first body row
                            // carries it.
                            if hasHeader || row > 0 {
                                cell
                            } else {
                                cell.gridColumnAlignment(gridAlignment(alignments, at: column))
                            }
                        }
                    }
                }
            }
            .listItemPadding(bleed: true, vertical: false)

        case .rule:
            Rectangle()
                .fill(colors.divider)
                .frame(height: 1)
        }
    }

    /// A column's alignment, defaulting to leading for a ragged delimiter row.
    private func gridAlignment(
        _ alignments: [MarkdownBlock.ColumnAlignment],
        at column: Int
    ) -> HorizontalAlignment {
        switch alignments.indices.contains(column) ? alignments[column] : .leading {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func inline(_ text: String) -> AttributedString {
        MarkdownCache.styledInline(text, fontSize: typography.bodySize, tint: codeBackground)
    }

    /// A heading's text, uppercased at the levels that rank by case rather
    /// than by size.
    ///
    /// Uppercases the parsed runs rather than the source: raising the markdown
    /// first would carry a link's URL up with it, and `.textCase` does not
    /// reach a `Text` built from an `AttributedString`.
    private func heading(_ text: String, level: Int) -> AttributedString {
        let parsed = inline(text)
        guard headingIsUppercased(level: level) else { return parsed }
        return parsed.runs.reduce(into: AttributedString()) { result, run in
            var raised = AttributedString(String(parsed[run.range].characters).uppercased())
            raised.mergeAttributes(run.attributes)
            result.append(raised)
        }
    }

    /// Heading levels map to the type scale's own roles, preserving the
    /// original ladder's weight distinctions.
    ///
    /// The ladder runs out before the levels do, so h5 and h6 sit at prose
    /// size and earn their rank from small caps instead — see
    /// `headingIsUppercased`.
    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return prose.headline.font
        case 2: return prose.title.font
        case 3: return prose.bodyLarge.font
        case 4: return prose.body.semibold
        case 5: return prose.body.semibold
        default: return prose.caption.semibold
        }
    }

    private func headingIsUppercased(level: Int) -> Bool {
        level >= 5
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

#Preview("Tables") {
    ScrollView {
        MarkdownView(
            """
            | Item | Count | Cost |
            | :--- | :---: | ---: |
            | Widgets with a long descriptive name | 12 | $1.50 |
            | Gadgets | 3 | $22.00 |

            | | |
            |---|---|
            | Package | `libghostty-spm` |
            | Requirement | `.exact("1.5.0")` |

            | Syntax | Renders |
            | --- | --- |
            | `**bold**` | **bold** |
            | `a \\| b` | a \\| b |

            Prose containing a | pipe stays a paragraph.
            """,
            isAgentVoice: true
        )
        .padding()
    }
    .plumeTheme(bodySize: 16)
    .frame(width: 700, height: 620)
}
