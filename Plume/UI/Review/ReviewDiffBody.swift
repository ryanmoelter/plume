#if DEBUG
import SwiftUI

/// A file's unified diff as a lazy SwiftUI list: line numbers, a marker, and
/// the line as `ReviewDiffRow` highlighted it.
struct ReviewDiffBody: View, ThemedView {
    @Environment(\.theme) var theme
    let rows: [ReviewDiffRow]

    @State private var viewportWidth: CGFloat = 0

    static let numberWidth: CGFloat = 44

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
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
            .frame(minWidth: viewportWidth, alignment: .leading)
        }
        .defaultScrollAnchor(.topLeading, for: .alignment)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .font(.system(size: 12, design: .monospaced))
    }

    private func hunk(_ header: String) -> some View {
        Text(header)
            .foregroundStyle(colors.attention)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, Self.numberWidth * 2 + 8)
            .padding(.vertical, 3)
            .frame(minWidth: viewportWidth, alignment: .leading)
            .background(colors.attention.opacity(0.08))
    }

    private func line(_ line: DiffLine, text: AttributedString) -> some View {
        HStack(spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker(line.kind))
                .foregroundStyle(markerColor(line.kind))
                .frame(width: 16)
            Text(text)
                .lineLimit(1)
                .fixedSize()
            if line.missingNewline {
                Image(systemName: "return")
                    .foregroundStyle(colors.danger)
                    .help("No newline at end of file")
                    .padding(.leading, 4)
            }
        }
        .padding(.vertical, 1)
        .frame(minWidth: viewportWidth, alignment: .leading)
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
