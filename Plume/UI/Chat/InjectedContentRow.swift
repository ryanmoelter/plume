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
            // Bounded and scrolling inside itself: an injected line carries a
            // whole skill body or an approved plan, which expanded would make
            // one lazy item many times its neighbours' height.
            ScrollView {
                expandedBody
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: ChatPieceMetrics.maxDisclosedHeight)
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
            .modifier(LabelEmphasis(accent: isSlashCommand ? colors.selection : nil))
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

    private var isSlashCommand: Bool {
        if case .slashCommand = kind { return true }
        return false
    }

    private var washColor: Color {
        colors.surfaceTint
    }
}

private struct LabelEmphasis: ViewModifier {
    let accent: Color?

    func body(content: Content) -> some View {
        if let accent {
            content.foregroundStyle(accent)
        } else {
            content.emphasis(.secondary)
        }
    }
}
