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
    /// The throttled fade bucket from `MarkdownView`, or nil to draw text
    /// with no fade at all. See `WordFade`.
    var fadeStep: Int?

    var body: some View {
        content
            .textSelection(.enabled)
    }

    /// A prose `Text` that cross-fades in when `fadeStep` advances.
    ///
    /// Keyed on `fadeStep` rather than on `attributed` itself: `attributed`
    /// changes on nearly every animation frame while `CharacterReveal`
    /// sweeps `revealedCount`, and `.contentTransition(.opacity)` retriggered
    /// that often measured tens of percent of a core once a few blocks
    /// streamed at once (`sample` showed a real per-glyph crossfade,
    /// `CGContextBeginTransparencyLayerWithRect`, on every retrigger).
    /// `fadeStep` only advances once every `WordFade.charactersPerFade`
    /// characters, so the crossfade fires that much less often while the
    /// text itself still updates every frame regardless.
    private func fadingText(_ attributed: AttributedString) -> some View {
        Text(attributed)
            .contentTransition(fadeStep != nil ? .opacity : .identity)
            .animation(fadeStep != nil ? .easeIn(duration: WordFade.duration) : nil, value: fadeStep)
    }

    /// The scale this view's prose renders in.
    private var prose: Typography {
        isAgentVoice ? proseTypography : typography
    }

    @ViewBuilder
    private var content: some View {
        switch block {
        case let .heading(level, text):
            fadingText(heading(text, level: level))
                .font(headingFont(level: level))
                .fixedSize(horizontal: false, vertical: true)
                .listItemPadding(vertical: false)

        case let .paragraph(text):
            fadingText(inline(text))
                .font(prose.body.font)
                .lineSpacing(prose.body.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .listItemPadding(vertical: false)

        case let .list(items):
            ListSegmentView(segment: ListSegment(items: items), isAgentVoice: isAgentVoice)

        case let .codeBlock(language, code):
            CodeSegmentView(segment: CodeSegment(
                language: language,
                code: code,
                isMermaid: MermaidDocument.isMermaidFence(language: language)
            ))

        case let .quote(text, continues):
            // A split quote's bar runs through the gap above each piece after
            // the first, so several pieces read as one quote. The gap is the
            // piece's top inset, paid inside the bar rather than above it —
            // the same trick a joined bubble's wash uses.
            HStack(spacing: 8) {
                Rectangle()
                    .fill(quoteBarColor)
                    .frame(width: 3)
                fadingText(inline(text))
                    .font(prose.body.font)
                    .emphasis(.secondary)
                    .lineSpacing(prose.body.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, continues ? quoteSegmentGap : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    private func inline(_ text: String, fontSize: CGFloat? = nil) -> AttributedString {
        MarkdownCache.styledInline(
            text,
            fontSize: fontSize ?? typography.bodySize,
            tint: colors.surfaceTint
        )
    }

    /// A heading's text, uppercased at the levels that rank by case rather
    /// than by size.
    ///
    /// Uppercases the parsed runs rather than the source: raising the markdown
    /// first would carry a link's URL up with it, and `.textCase` does not
    /// reach a `Text` built from an `AttributedString`.
    private func heading(_ text: String, level: Int) -> AttributedString {
        // Inline code carries its own font, which wins over the heading's, so
        // it has to be built at the heading's size rather than the body's.
        let parsed = inline(text, fontSize: headingStyle(level: level).size)
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
    private func headingStyle(level: Int) -> Typography.Style {
        switch level {
        case 1: return prose.headline
        case 2: return prose.title
        case 3: return prose.bodyLarge
        case 4, 5: return prose.body
        default: return prose.caption
        }
    }

    /// The ladder's own roles carry their weight; the levels that fall off it
    /// take semibold to keep ranking above prose.
    private func headingFont(level: Int) -> Font {
        let style = headingStyle(level: level)
        return level >= 4 ? style.semibold : style.font
    }

    private func headingIsUppercased(level: Int) -> Bool {
        level >= 5
    }

    /// The gap between two pieces of one split quote, drawn inside the bar.
    /// Matches the gap a paragraph already has from the one above it.
    private var quoteSegmentGap: CGFloat { dimensions.blockSpacing }

    private var quoteBarColor: Color {
        colors.surface(.disabled)
    }

    private var tableCornerRadius: CGFloat { 6 }
}

/// A list, nesting included, or one slice of a long one.
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
                let item = segment.items[index]
                HStack(alignment: .top, spacing: 6) {
                    Text(marker(for: item))
                    Text(MarkdownCache.styledInline(
                        item.text,
                        fontSize: typography.bodySize,
                        tint: colors.surfaceTint
                    ))
                }
                .font(prose.body.font)
                .lineSpacing(prose.body.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Self.indent * CGFloat(item.depth))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
        .listItemPadding(vertical: false)
    }

    /// Each item renders the number the parser resolved for it, so a segment
    /// of a split list needs no running count of its own.
    private func marker(for item: MarkdownBlock.ListItem) -> String {
        guard let number = item.number else { return Self.bullets[item.depth % Self.bullets.count] }
        return "\(number)."
    }

    /// Enough to clear a two-digit marker at the depth above.
    private static let indent: CGFloat = 20

    /// Depth reads from the glyph as well as the indent, the way a rendered
    /// markdown document's nested bullets do.
    private static let bullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
}

/// Which edges a code block shares with a neighbour, so the pair draws as
/// one shape.
struct CodeSegmentJoin: OptionSet {
    let rawValue: Int

    static let above = CodeSegmentJoin(rawValue: 1 << 0)
    static let below = CodeSegmentJoin(rawValue: 1 << 1)
    static let alone: CodeSegmentJoin = []
}

/// A fenced code block, always drawn whole.
struct CodeSegmentView: View, ThemedView {
    @Environment(\.theme) var theme

    let segment: CodeSegment
    /// Shown in the header instead of the language name, for a block whose
    /// role says more than its syntax does — a shell command's `bash input`
    /// and `bash output`.
    var title: String?
    /// False for a block nested inside another row, which owns its own
    /// column — the block then takes the width it is given rather than
    /// claiming one, so it lines up with the row around it instead of
    /// stepping in by another column's padding.
    var bleeds = true
    /// Squares the corners this block shares with a neighbour, so a stack of
    /// them reads as one shape rather than a column of separate blocks.
    var joins: CodeSegmentJoin = .alone
    /// A stroked outline in the surface color instead of a filled one, to
    /// set a block apart from the one it is joined to while keeping the two
    /// in the same family.
    var isOutlined = false
    /// Tints the header — its title and icon — as a failure. Only the
    /// header: the text below is what the command printed, and coloring it
    /// would claim every line of it is an error message.
    var isFailure = false
    /// Caps the block's height, scrolling the code in place past it. Nil
    /// lets it grow to fit, which is what a block in the flow of a reply
    /// does; a disclosed tool result sets it so a long one cannot run away
    /// with the page.
    var maxHeight: CGFloat?

    @State private var isHovered = false

    var body: some View {
        Group {
            if segment.isMermaid {
                // Copying still yields the source, not the drawn diagram.
                MermaidBlock(source: segment.code, isRevealed: isHovered) { reason in
                    VStack(alignment: .leading, spacing: 6) {
                        if let reason {
                            Text(reason)
                                .font(typography.body.font)
                                .emphasis(.secondary)
                        }
                        code
                    }
                }
            } else {
                code
            }
        }
        .textSelection(.enabled)
        .plumeHover { isHovered = $0 }
        .listItemPadding(bleed: true, vertical: false, enabled: bleeds)
    }

    private var code: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            lines
        }
        // `strokeBorder` draws inside the frame, so content filling it shows
        // through the translucent band. Insetting the clip by the stroke
        // matches the band's inner edge, corner radii included.
        .clipShape(shape.inset(by: isOutlined ? outlineWidth : 0))
        .background {
            if isOutlined {
                // The same color the filled block above uses, so the edge
                // they share disappears into it and the stroke reads only
                // around the outside. Several times a hairline's width,
                // since the color is far lighter than a divider's and has to
                // carry the edge on its own.
                shape.strokeBorder(colors.surfaceTint, lineWidth: outlineWidth)
            } else {
                shape.fill(colors.surfaceTint)
            }
        }
    }

    /// Rounded only on the edges this block does not share with a neighbour.
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: joins.contains(.above) ? 0 : radius,
            bottomLeadingRadius: joins.contains(.below) ? 0 : radius,
            bottomTrailingRadius: joins.contains(.below) ? 0 : radius,
            topTrailingRadius: joins.contains(.above) ? 0 : radius
        )
    }

    /// Names the language, with a code icon, and carries the copy button.
    ///
    /// An untagged fence says so rather than going blank, which keeps the
    /// copy button from sitting alone and every block in a reply lined up.
    private var header: some View {
        HStack(spacing: 5) {
            Group {
                Image(systemName: isFailure ? "exclamationmark.triangle" : "chevron.left.forwardslash.chevron.right")
                Text(title ?? CodeSyntax.displayName(for: segment.language) ?? "no language")
            }
            .font(typography.caption.font)
            .foregroundStyle(isFailure ? AnyShapeStyle(colors.danger) : AnyShapeStyle(.secondary))
            Spacer(minLength: 0)
            CodeBlockCopyButton(code: segment.code)
        }
        // The icon's leading edge meets the first character of code below.
        .padding(.leading, padding)
        .padding(.trailing, 6)
        .frame(height: ChatPieceMetrics.codeHeaderHeight)
        // The clip empties the band but reserves no room, so without this
        // the outline crops the top of a header of fixed height.
        .padding(.top, isOutlined ? outlineWidth : 0)
        // The label is decoration; a drag over it should not start a
        // selection that competes with the code's own.
        .textSelection(.disabled)
    }

    private var lines: some View {
        ScrollView(maxHeight == nil ? .horizontal : [.horizontal, .vertical], showsIndicators: false) {
            Text(highlighted)
                .font(.chatCode(size: typography.bodySize * AppSettings.shared.codeFontSizeMultiplier))
                .padding(.horizontal, padding)
                .padding(.bottom, padding)
                // The header already pays the gap above the first line.
                .padding(.top, 2)
        }
        // A scroll view that scrolls both axes centers content smaller than
        // itself, where one that scrolls a single axis pins it to the
        // leading edge. Only alignment: the initial offset stays put.
        .defaultScrollAnchor(.topLeading, for: .alignment)
        .frame(maxHeight: maxHeight)
    }

    /// An untagged or unrecognized fence yields plain text in the block's own
    /// foreground, which is the common case.
    private var highlighted: AttributedString {
        CodeSyntaxCache.highlighted(
            segment.code,
            language: segment.language,
            palette: CodeSyntaxPalette(palette: colors)
        )
    }

    private var padding: CGFloat { 14 }
    private var radius: CGFloat { 6 }
    private var outlineWidth: CGFloat { 3 }
}

/// Copies a code block's raw text to the pasteboard, from the block's header
/// so it never scrolls with the code beneath it.
struct CodeBlockCopyButton: View, ThemedView {
    @Environment(\.theme) var theme

    let code: String

    @State private var didCopy = false

    var body: some View {
        Button(action: copy) {
            CopyGlyph(didCopy: didCopy)
        }
        .buttonStyle(.plain)
        .help("Copy code")
        .accessibilityLabel("Copy code")
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
