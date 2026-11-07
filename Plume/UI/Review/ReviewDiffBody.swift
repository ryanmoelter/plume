#if DEBUG
import AppKit
import SwiftUI

/// A file's unified diff as a lazy SwiftUI list: line numbers, a marker, and
/// the line as `ReviewDiffRow` highlighted it.
///
/// Code scrolls sideways at the full width of its widest line, laid out up
/// front from `columns` because a lazy stack only measures the rows it has
/// realized. Markdown is prose, so it wraps instead.
struct ReviewDiffBody: View, ThemedView {
    @Environment(\.theme) var theme
    let rows: [ReviewDiffRow]
    let columns: Int
    let wraps: Bool
    /// Where comments are drafted; nil shows the diff alone.
    var model: ReviewModel?
    var path = ""

    @State private var viewportWidth: CGFloat = 0
    @State private var characterWidth: CGFloat = 8
    /// The row a shift-click extends a comment from.
    @State private var anchorRow: Int?

    static let numberWidth: CGFloat = 44
    private static let markerWidth: CGFloat = 16
    static let gutterWidth = (numberWidth + 4) * 2 + markerWidth

    static func wraps(_ path: String) -> Bool {
        ["md", "markdown"].contains((path as NSString).pathExtension.lowercased())
    }

    private var codeFont: Font {
        .chatCode(size: typography.bodySize * AppSettings.shared.codeFontSizeMultiplier)
    }

    private var rowWidth: CGFloat {
        guard !wraps else { return viewportWidth }
        return max(viewportWidth, Self.gutterWidth + CGFloat(columns) * characterWidth + 24)
    }

    var body: some View {
        ScrollView(wraps ? .vertical : [.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    switch row.kind {
                    case .hunk(let header):
                        hunk(header)
                    case .line(let line, let text):
                        self.line(line, text: text, row: row.id)
                        if let model {
                            ForEach(model.comments.filter { $0.path == path && $0.endsAt(line) }) { comment in
                                ReviewCommentEditor(model: model, comment: comment)
                                    .frame(width: wraps ? viewportWidth : min(rowWidth, max(viewportWidth, 1)), alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .defaultScrollAnchor(.topLeading, for: .alignment)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .font(codeFont)
        .background {
            // One glyph of the code font, which is monospaced.
            Text(verbatim: "0")
                .font(codeFont)
                .fixedSize()
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { characterWidth = max($0, 1) }
        }
    }

    private func hunk(_ header: String) -> some View {
        Text(header)
            .foregroundStyle(colors.attention)
            .lineLimit(1)
            .padding(.leading, Self.gutterWidth)
            .padding(.vertical, 3)
            .frame(width: rowWidth, alignment: .leading)
            .background(colors.attention.opacity(0.08))
    }

    private func line(_ line: DiffLine, text: AttributedString, row: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                number(line.oldNumber)
                number(line.newNumber)
                Text(marker(line.kind))
                    .foregroundStyle(markerColor(line.kind))
                    .frame(width: Self.markerWidth)
            }
            .contentShape(.rect)
            .onTapGesture { comment(at: row, extending: NSEvent.modifierFlags.contains(.shift)) }
            .help(model == nil ? "" : "Comment on this line; shift-click to comment on a range")
            .plumeID(
                AccessibilityID.reviewDiffGutter,
                label: "\(line.oldNumber.map(String.init) ?? "-"):\(line.newNumber.map(String.init) ?? "-")",
                invoke: { comment(at: row, extending: false) }
            )
            Text(text)
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: !wraps, vertical: true)
            if line.missingNewline {
                Image(systemName: "return")
                    .foregroundStyle(colors.danger)
                    .help("No newline at end of file")
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .frame(width: rowWidth, alignment: .leading)
        .background(background(line.kind))
    }

    /// Drafts a comment on one line, or from the last clicked line to this
    /// one when extending.
    private func comment(at row: Int, extending: Bool) {
        guard let model else { return }
        let bounds = extending ? anchorRow.map { (min($0, row), max($0, row)) } ?? (row, row) : (row, row)
        let lines: [DiffLine] = rows[bounds.0...bounds.1].compactMap { row in
            if case .line(let line, _) = row.kind { return line }
            return nil
        }
        if extending, let previous = model.comments.last, previous.path == path, previous.body.isEmpty {
            model.deleteComment(previous.id)
        }
        model.addComment(path: path, lines: lines)
        anchorRow = row
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .emphasis(.subtle)
            .frame(width: Self.numberWidth, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private func marker(_ kind: FileDiff.LineKind) -> String {
        switch kind {
        case .context: " "
        case .removed: "-"
        case .added: "+"
        }
    }

    private func markerColor(_ kind: FileDiff.LineKind) -> Color {
        switch kind {
        case .context: .clear
        case .removed: colors.danger
        case .added: colors.success
        }
    }

    private func background(_ kind: FileDiff.LineKind) -> Color {
        switch kind {
        case .context: .clear
        case .removed: colors.danger.emphasized(.backgroundTint, in: colors)
        case .added: colors.success.emphasized(.backgroundTint, in: colors)
        }
    }
}
#endif
