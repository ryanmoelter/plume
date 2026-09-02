import SwiftUI

/// A compact marker for something Claude Code injected as a user line.
///
/// A skill invocation and a slash command are both things that happened and
/// are worth showing — just not as prose in the user's voice. The label says
/// what happened; the text stays behind a disclosure for when it matters.
struct InjectedContentRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatFontSize) private var chatFontSize

    let kind: InjectedContent
    let text: String

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: kind.markerSymbol)
                        .imageScale(.small)
                    Text(kind.markerLabel ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .imageScale(.small)
                        .emphasis(.subtle)
                }
                .font(.system(size: chatFontSize * 0.82, design: monospacedLabel ? .monospaced : .default))
                .emphasis(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(text)
                    .font(.system(size: chatFontSize * 0.82, design: .monospaced))
                    .emphasis(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(washColor, in: .rect(cornerRadius: 6))
            }
        }
        .listItemPadding(vertical: false)
    }

    /// A shell command reads as code; the rest read as labels.
    private var monospacedLabel: Bool {
        switch kind {
        case .shellCommand, .slashCommand: return true
        default: return false
        }
    }

    private var washColor: Color {
        .chatSurface(.backgroundTint, colorScheme: colorScheme)
    }
}
