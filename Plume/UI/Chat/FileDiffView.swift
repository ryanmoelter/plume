import SwiftUI

/// An `Edit` or `Write`'s change, as added and removed lines.
struct FileDiffView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatFontSize) private var chatFontSize

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
                            .font(.system(size: chatFontSize * 0.75))
                            .emphasis(.subtle)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .background(.chatSurface(.backgroundTint, colorScheme: colorScheme), in: .rect(cornerRadius: 6))
        }
    }

    private var counts: some View {
        HStack(spacing: 8) {
            Text("+\(diff.addedCount)")
                .foregroundStyle(ChatRole.success)
            Text("−\(diff.removedCount)")
                .foregroundStyle(ChatRole.danger)
        }
        .font(.system(size: chatFontSize * 0.75, design: .monospaced))
    }

    private func line(_ line: FileDiff.Line) -> some View {
        Text("\(marker(line.kind))\(line.text)")
            .font(.system(size: chatFontSize * 0.8, design: .monospaced))
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
        case .removed: AnyShapeStyle(ChatRole.danger)
        case .added: AnyShapeStyle(ChatRole.success)
        }
    }

    private func background(_ kind: FileDiff.LineKind) -> Color {
        switch kind {
        case .context: .clear
        case .removed: ChatRole.danger.emphasized(.backgroundTint, colorScheme: colorScheme)
        case .added: ChatRole.success.emphasized(.backgroundTint, colorScheme: colorScheme)
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
