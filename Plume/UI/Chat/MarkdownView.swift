import AppKit
import SwiftUI

/// Renders parsed markdown with a proportional font for prose — monospace is
/// reserved for code blocks and inline code, per the roadmap's "don't use a
/// monospace font" item. Block layout is plain SwiftUI stacks over
/// `MarkdownBlock.parse`; only a mermaid fence reaches for WebKit, in
/// `MermaidBlock`.
struct MarkdownView: View, ThemedView {
    @Environment(\.theme) var theme

    let blocks: [MarkdownBlock]
    /// Whether this is the agent speaking, which earns the serif. Anything
    /// else — the user's own message, a tool's output — stays in the system
    /// face so it reads as input rather than published prose.
    let isAgentVoice: Bool

    /// The hovered block's index, so its copy button reveals while the pointer
    /// is anywhere over the block rather than only over the button itself.
    /// Keyed by position because two blocks can hold identical code.
    @State private var hoveredBlock: Int?

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
                render(blocks[index], at: index)
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
    private func render(_ block: MarkdownBlock, at index: Int) -> some View {
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

        case let .codeBlock(language, code):
            if MermaidDocument.isMermaidFence(language: language) {
                // Copying still yields the source, not the drawn diagram.
                MermaidBlock(source: code) {
                    codeBlock(code)
                }
                .overlay(alignment: .topTrailing) {
                    CodeBlockCopyButton(code: code, isRevealed: hoveredBlock == index)
                }
                .onHover { hoveredBlock = $0 ? index : nil }
                .listItemPadding(bleed: true, vertical: false)
            } else {
                codeBlock(code)
                    .overlay(alignment: .topTrailing) {
                        CodeBlockCopyButton(code: code, isRevealed: hoveredBlock == index)
                    }
                    .onHover { hoveredBlock = $0 ? index : nil }
                    .listItemPadding(bleed: true, vertical: false)
            }

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
            table(header: header, alignments: alignments, rows: rows)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listItemPadding(bleed: true, vertical: false)
                .padding(.vertical, 6)

        case .rule:
            Rectangle()
                .fill(colors.divider)
                .frame(height: 1)
        }
    }

    /// A fenced block's text in its bordered, scrollable container. Also what
    /// a mermaid fence shows while it draws and if it fails to.
    private func codeBlock(_ code: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(typography.body.mono)
                .foregroundStyle(codeForeground)
                .padding(14)
        }
        .background(codeBackground, in: .rect(cornerRadius: 6))
    }

    /// The table, laid out by `TableLayout` so its columns size to their
    /// content the way an HTML table's do.
    @ViewBuilder
    private func table(
        header: [String],
        alignments: [MarkdownBlock.ColumnAlignment],
        rows: [[String]]
    ) -> some View {
        let hasHeader = MarkdownBlock.headerIsMeaningful(header)
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        // Cells are laid out flat, row-major: `TableLayout` groups them back
        // into rows. Each draws its own leading and top rule; the outer border
        // closes the remaining two sides.
        TableLayout(columnCount: columnCount) {
            if hasHeader {
                ForEach(0..<columnCount, id: \.self) { column in
                    tableCell(
                        header.indices.contains(column) ? header[column] : "",
                        font: prose.body.semibold,
                        alignment: alignment(alignments, at: column),
                        isFirstColumn: column == 0,
                        isFirstRow: true,
                        fill: colors.surfaceTint
                    )
                }
            }
            // Every row draws all the columns, so a ragged row still carries
            // its share of the rules.
            ForEach(rows.indices, id: \.self) { row in
                ForEach(0..<columnCount, id: \.self) { column in
                    tableCell(
                        rows[row].indices.contains(column) ? rows[row][column] : "",
                        font: prose.body.font,
                        alignment: alignment(alignments, at: column),
                        isFirstColumn: column == 0,
                        isFirstRow: !hasHeader && row == 0,
                        fill: .clear
                    )
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(.rect(cornerRadius: tableCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: tableCornerRadius)
                .strokeBorder(colors.divider, lineWidth: 1)
        }
    }

    /// One table cell, filling its column and row so its fill and its rules
    /// cover the whole cell rather than just the text inside it.
    ///
    /// Draws only its leading and top rules, and neither in the first column
    /// or row, so no rule is painted twice and the outer border owns the
    /// table's edges. Leading and top sit on the cell's own origin, which is
    /// where neighbouring cells agree; trailing and bottom fall on a computed
    /// edge and drift apart by a fraction of a point.
    private func tableCell(
        _ text: String,
        font: Font,
        alignment: Alignment,
        isFirstColumn: Bool,
        isFirstRow: Bool,
        fill: Color
    ) -> some View {
        Text(inline(text))
            .font(font)
            .lineSpacing(prose.body.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // Fills the width and height `TableLayout` hands down, which is
            // what makes the fill and the rules cover the whole cell rather
            // than just its text. The layout sizes the column itself, so this
            // never decides how wide the column is.
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: alignment
            )
            .background(fill)
            .overlay(alignment: .leading) {
                if !isFirstColumn {
                    Rectangle().fill(colors.divider).frame(width: 1)
                }
            }
            .overlay(alignment: .top) {
                if !isFirstRow {
                    Rectangle().fill(colors.divider).frame(height: 1)
                }
            }
    }

    /// A column's alignment, defaulting to leading for a ragged delimiter row.
    private func alignment(
        _ alignments: [MarkdownBlock.ColumnAlignment],
        at column: Int
    ) -> Alignment {
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

    private var tableCornerRadius: CGFloat { 6 }
}

/// Copies a code block's raw text to the pasteboard, revealed on hover and
/// pinned to the block's corner so it never scrolls with the code beneath it.
private struct CodeBlockCopyButton: View, ThemedView {
    @Environment(\.theme) var theme

    let code: String
    let isRevealed: Bool

    @State private var didCopy = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(colors.foreground)
                .padding(6)
                .background(colors.surface(.backgroundTint), in: .circle)
        }
        .buttonStyle(.plain)
        .padding(6)
        .opacity(isRevealed || didCopy ? 1 : 0)
        .help("Copy code")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
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
