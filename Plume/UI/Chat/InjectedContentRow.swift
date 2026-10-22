import SwiftUI

/// A compact marker for something Claude Code injected as a user line.
///
/// A skill invocation or a command's output is something that happened and
/// is worth showing — just not as prose in the user's voice. The label says
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
            InjectedContentBody(kind: kind, text: text)
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

    /// A shell command reads as code; the rest read as labels.
    private var monospacedLabel: Bool {
        switch kind {
        case .shellCommand: return true
        default: return false
        }
    }
}

/// An injected line's text, bounded and scrolling inside itself.
struct InjectedContentBody: View, ThemedView {
    @Environment(\.theme) var theme

    let kind: InjectedContent
    let text: String

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: ChatPieceMetrics.maxDisclosedHeight)
        .padding(8)
        .background(colors.surfaceTint, in: .rect(cornerRadius: 6))
        .padding(.top, 4)
    }

    @ViewBuilder
    private var content: some View {
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
}

/// The prompt a slash command expanded into, under the command's bubble.
///
/// The command is what the user typed, so it reads as their message; what
/// Claude Code expanded it into is only a click away.
struct SlashCommandPromptRow: View, ThemedView {
    @Environment(\.theme) var theme

    let kind: InjectedContent
    let text: String
    let key: String

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Prompt")
                }
                .font(typography.caption.font)
                .emphasis(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide the prompt this command ran" : "Show the prompt this command ran")
            .plumeID(
                AccessibilityID.slashCommandPrompt,
                label: key,
                value: isExpanded ? "expanded" : "collapsed",
                invoke: toggle
            )
            if isExpanded {
                InjectedContentBody(kind: kind, text: text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .listItemPadding(vertical: false)
    }

    private func toggle() {
        isExpanded.toggle()
    }
}
