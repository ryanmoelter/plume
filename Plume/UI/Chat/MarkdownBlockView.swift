import AppKit
import SwiftUI

/// One block-level element of parsed markdown.
///
/// Its own view rather than a method on `MarkdownView`, because the chat list
/// places blocks individually — one lazy item each, so no item is as tall as a
/// whole reply. See `ChatPieceSplitter`.
struct MarkdownBlockView: View, ThemedView {
    @Environment(\.theme) var theme

    let block: MarkdownBlock
    /// Whether this is the agent speaking, which earns the serif. Anything
    /// else — the user's own message, a tool's output — stays in the system
    /// face so it reads as input rather than published prose.
    var isAgentVoice: Bool = false

    var body: some View {
        content
            .textSelection(.enabled)
    }

    /// The scale this view's prose renders in.
    private var prose: Typography {
        isAgentVoice ? proseTypography : typography
    }

    @ViewBuilder
    private var content: some View {
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
            ListSegmentView(
                segment: ListSegment(kind: .bullet, items: items),
                isAgentVoice: isAgentVoice
            )

        case let .numberedList(items):
            ListSegmentView(
                segment: ListSegment(kind: .numbered, items: items),
                isAgentVoice: isAgentVoice
            )

        case let .codeBlock(language, code):
            CodeSegmentView(segment: CodeSegment(
                language: language,
                code: code,
                fullCode: code,
                isMermaid: MermaidDocument.isMermaidFence(language: language)
            ))

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
            // Centered rather than pinned leading: `TableLayout` sizes columns
            // to their content, so a narrow table otherwise sits against one
            // edge of a much wider column.
            table(header: header, alignments: alignments, rows: rows)
                .frame(maxWidth: .infinity, alignment: .center)
                .listItemPadding(bleed: true, vertical: false)
                .padding(.vertical, 6)

        case .rule:
            Rectangle()
                .fill(colors.divider)
                .frame(height: 1)
        }
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
        MarkdownCache.styledInline(text, fontSize: typography.bodySize, tint: colors.surfaceTint)
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

    private var quoteBarColor: Color {
        colors.surface(.disabled)
    }

    private var tableCornerRadius: CGFloat { 6 }
}

/// A bullet or numbered list, or one slice of a long one.
struct ListSegmentView: View, ThemedView {
    @Environment(\.theme) var theme

    let segment: ListSegment
    var isAgentVoice: Bool = false

    private var prose: Typography {
        isAgentVoice ? proseTypography : typography
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ChatBlockSpacing.listSegmentSpacing) {
            ForEach(segment.items.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 6) {
                    Text(marker(at: index))
                    Text(MarkdownCache.styledInline(
                        segment.items[index],
                        fontSize: typography.bodySize,
                        tint: colors.surfaceTint
                    ))
                }
                .font(prose.body.font)
                .lineSpacing(prose.body.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listItemPadding(vertical: false)
    }

    /// Numbering runs from the segment's own start, so a split list keeps
    /// counting rather than restarting at one.
    private func marker(at index: Int) -> String {
        switch segment.kind {
        case .bullet: "\u{2022}"
        case .numbered: "\(segment.startNumber + index)."
        }
    }
}

/// A fenced code block, or one slice of a long one.
///
/// A slice pays its inner padding and rounds its corners only on the edges it
/// owns, so consecutive slices join without a seam. Each keeps its own
/// horizontal scroll view — the cost of splitting, which the line threshold in
/// `ChatPieceMetrics` keeps rare.
struct CodeSegmentView: View, ThemedView {
    @Environment(\.theme) var theme

    let segment: CodeSegment

    @State private var isHovered = false

    var body: some View {
        Group {
            if segment.isMermaid {
                // Copying still yields the source, not the drawn diagram.
                MermaidBlock(source: segment.code, isRevealed: isHovered) { code }
                    .overlay(alignment: .topTrailing) { copyButton }
            } else {
                code
                    .overlay(alignment: .topTrailing) { copyButton }
            }
        }
        .onHover { isHovered = $0 }
        .listItemPadding(bleed: true, vertical: false)
    }

    private var code: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(segment.code)
                .font(typography.body.mono)
                .foregroundStyle(colors.foreground)
                .padding(.horizontal, padding)
                .padding(.top, segment.position.isFirst ? padding : 0)
                .padding(.bottom, segment.position.isLast ? padding : 0)
        }
        .background(colors.surfaceTint, in: shape)
    }

    @ViewBuilder
    private var copyButton: some View {
        if segment.position.isFirst {
            CodeBlockCopyButton(code: segment.fullCode, isRevealed: isHovered)
        }
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: segment.position.isFirst ? radius : 0,
            bottomLeadingRadius: segment.position.isLast ? radius : 0,
            bottomTrailingRadius: segment.position.isLast ? radius : 0,
            topTrailingRadius: segment.position.isFirst ? radius : 0
        )
    }

    private var padding: CGFloat { 14 }
    private var radius: CGFloat { 6 }
}

/// Copies a code block's raw text to the pasteboard, revealed on hover and
/// pinned to the block's corner so it never scrolls with the code beneath it.
struct CodeBlockCopyButton: View, ThemedView {
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
