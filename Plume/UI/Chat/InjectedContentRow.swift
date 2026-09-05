import SwiftUI

/// A compact marker for something Claude Code injected as a user line.
///
/// A skill invocation and a slash command are both things that happened and
/// are worth showing — just not as prose in the user's voice. The label says
/// what happened; the text stays behind a disclosure for when it matters.
struct InjectedContentRow: View, ThemedView {
    @Environment(\.theme) var theme

    let kind: InjectedContent
    let text: String

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            expandedBody
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(washColor, in: .rect(cornerRadius: 6))
                .padding(.top, 4)
        } label: {
            Label {
                Text(kind.markerLabel ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: kind.markerSymbol)
                    .imageScale(.small)
            }
            .font(typography.caption.mono(when: monospacedLabel))
            .emphasis(.secondary)
        }
        .listItemPadding(vertical: false)
    }

    @ViewBuilder
    private var expandedBody: some View {
        switch kind.bodyStyle {
        case .markdown:
            MarkdownView(kind.bodyText(text))
        case .monospaced:
            Text(text)
                .font(typography.caption.mono)
                .emphasis(.secondary)
                .textSelection(.enabled)
        }
    }

    /// A shell command reads as code; the rest read as labels.
    private var monospacedLabel: Bool {
        switch kind {
        case .shellCommand, .slashCommand: return true
        default: return false
        }
    }

    private var washColor: Color {
        colors.surfaceTint
    }
}
