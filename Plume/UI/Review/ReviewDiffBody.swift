#if DEBUG
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

    @State private var viewportWidth: CGFloat = 0
    @State private var characterWidth: CGFloat = 8

    static let numberWidth: CGFloat = 44
    private static let markerWidth: CGFloat = 16
    private static let gutterWidth = (numberWidth + 4) * 2 + markerWidth

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
                        self.line(line, text: text)
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

    private func line(_ line: DiffLine, text: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker(line.kind))
                .foregroundStyle(markerColor(line.kind))
                .frame(width: Self.markerWidth)
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
