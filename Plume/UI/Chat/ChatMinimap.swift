import SwiftUI

/// A skimmable map of the conversation, down the right edge of the chat.
///
/// The reader anchors on their own input, so prompts and questions keep their
/// text while a whole run of agent output between two of them collapses into
/// one tinted area. Clicking an entry puts it at the top of the viewport.
struct ChatMinimap: View, ThemedView {
    @Environment(\.theme) var theme

    let outline: ChatOutline
    /// The piece ids on screen, so the reader can see where they are.
    var visiblePieceIDs: Set<String> = []
    /// Scrolls the list to a piece id.
    let onSelect: (String) -> Void

    /// Wide enough for a few words of a prompt. The panel takes real layout
    /// space rather than floating, so this width is part of the pane's
    /// minimum.
    static let width: CGFloat = 168

    var body: some View {
        // Weights are relative, so the conversation is laid out as fractions
        // of the height available rather than at any fixed scale.
        GeometryReader { proxy in
            let scale = proxy.size.height / outline.totalWeight
            VStack(alignment: .leading, spacing: Self.entrySpacing) {
                ForEach(outline.entries) { entry in
                    ChatMinimapEntryView(
                        entry: entry,
                        height: max(Self.minimumEntryHeight, entry.weight * scale),
                        isVisible: !entry.pieceIDs.isDisjoint(with: visiblePieceIDs),
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

    /// The shortest an entry draws, so a brief one stays clickable however
    /// long the conversation grows around it.
    private static let minimumEntryHeight: CGFloat = 3

    private static let edgeInset: CGFloat = 8
}

/// One entry: a legible line for something the user said or was asked, a
/// tinted area for a run of the agent's output.
private struct ChatMinimapEntryView: View, ThemedView {
    @Environment(\.theme) var theme

    let entry: ChatOutline.Entry
    let height: CGFloat
    /// Whether any of what this entry covers is on screen.
    let isVisible: Bool
    let onSelect: (String) -> Void

    var body: some View {
        Button { onSelect(entry.id) } label: {
            switch entry.kind {
            case .prompt(let text):
                label(text)
            case .question(let text):
                label(text)
            case .response:
                area
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.chatMinimapEntry)
    }

    /// User input takes its natural line height rather than its share of the
    /// conversation: a one-line question between two long replies is the
    /// landmark being scanned for, so it has to stay readable.
    private func label(_ text: String) -> some View {
        Text(text.isEmpty ? "…" : text)
            .font(typography.caption.font)
            .fontWeight(isVisible ? .semibold : .regular)
            .emphasis(isVisible ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(.rect)
            .help(text)
    }

    private var area: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(colors.surface(isVisible ? .disabled : .backgroundTint))
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
    }
}
