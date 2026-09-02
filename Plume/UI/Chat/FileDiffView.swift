import SwiftUI

/// An `Edit` or `Write`'s change, as added and removed lines.
struct FileDiffView: View, ThemedView {
    @Environment(\.theme) var theme

    let diff: FileDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            counts
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.lines.indices, id: \.self) { index in
                        line(diff.lines[index])
                    }
                    if diff.truncatedLineCount > 0 {
                        Text("… \(diff.truncatedLineCount) more lines")
                            .font(typography.caption.font)
                            .emphasis(.subtle)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .background(colors.surfaceTint, in: .rect(cornerRadius: 6))
        }
    }

    private var counts: some View {
        HStack(spacing: 8) {
            Text("+\(diff.addedCount)")
                .foregroundStyle(colors.success)
            Text("−\(diff.removedCount)")
                .foregroundStyle(colors.danger)
        }
        .font(typography.caption.mono)
    }

    private func line(_ line: FileDiff.Line) -> some View {
        Text("\(marker(line.kind))\(line.text)")
            .font(typography.caption.mono)
            .foregroundStyle(foreground(line.kind))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(background(line.kind))
    }

    private func marker(_ kind: FileDiff.LineKind) -> String {
        switch kind {
        case .context: " "
        case .removed: "-"
        case .added: "+"
        }
    }

    private func foreground(_ kind: FileDiff.LineKind) -> AnyShapeStyle {
        switch kind {
        case .context: AnyShapeStyle(Emphasis.secondary.textHierarchy)
        case .removed: AnyShapeStyle(colors.danger)
        case .added: AnyShapeStyle(colors.success)
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

#Preview {
    FileDiffView(diff: FileDiffBuilder.build(
        path: "/tmp/x.swift",
        oldText: "let a = 1\nlet b = 2\nlet c = 3",
        newText: "let a = 1\nlet b = 22\nlet c = 3"
    ))
    .padding()
    .frame(width: 420)
}
