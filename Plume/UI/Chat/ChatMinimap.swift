import SwiftUI

/// A skimmable map of the conversation, down the right edge of the chat.
///
/// The reader anchors on their own prompts, so those keep their text and the
/// agent's replies become de-emphasized mass between them. Clicking a prompt
/// puts that message at the top of the viewport.
struct ChatMinimap: View, ThemedView {
    @Environment(\.theme) var theme

    let outline: ChatOutline
    /// Scrolls the list to a piece id.
    let onSelect: (String) -> Void

    /// Wide enough for a few words of a prompt. The panel takes real layout
    /// space rather than floating, so this width is part of the pane's
    /// minimum.
    static let width: CGFloat = 168

    var body: some View {
        // Weights are relative, so the whole conversation is laid out as
        // fractions of the height available rather than at any fixed scale.
        GeometryReader { proxy in
            let scale = proxy.size.height / outline.totalWeight
            VStack(alignment: .leading, spacing: Self.entrySpacing) {
                ForEach(outline.entries) { entry in
                    ChatMinimapEntryView(
                        entry: entry,
                        height: max(Self.minimumEntryHeight, entry.weight * scale),
                        onSelect: onSelect
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: Self.width)
        .padding(.vertical, dimensions.verticalPadding)
        .padding(.trailing, Self.edgeInset)
        .accessibilityIdentifier(AccessibilityID.chatMinimap)
    }

    /// Small enough that the map still reads as continuous mass, large enough
    /// that neighbouring entries do not merge.
    private static let entrySpacing: CGFloat = 2

    /// The shortest an entry draws, so a brief message stays clickable
    /// however long the conversation grows around it.
    private static let minimumEntryHeight: CGFloat = 3

    private static let edgeInset: CGFloat = 8
}

/// One message in the map: a legible line for a prompt, a tinted block for
/// anything else.
private struct ChatMinimapEntryView: View, ThemedView {
    @Environment(\.theme) var theme

    let entry: ChatOutline.Entry
    let height: CGFloat
    let onSelect: (String) -> Void

    var body: some View {
        Button { onSelect(entry.id) } label: {
            switch entry.kind {
            case .prompt(let text):
                prompt(text)
            case .response, .notice:
                block
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.chatMinimapEntry)
    }

    /// A prompt is the thing being scanned for, so it takes its natural line
    /// height rather than its share of the conversation — a one-line question
    /// between two long replies has to stay readable.
    private func prompt(_ text: String) -> some View {
        Text(text.isEmpty ? "…" : text)
            .font(typography.caption.font)
            .emphasis(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(.rect)
            .help(text)
    }

    private var block: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(colors.surface(entry.kind == .notice ? .divider : .backgroundTint))
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
    }
}
