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

    /// Follows the conversation rather than being scrolled by hand.
    @State private var position = ScrollPosition(edge: .top)

    var body: some View {
        GeometryReader { proxy in
            // Entries take their natural size until the map outgrows the
            // pane; past that it scrolls rather than compressing every entry
            // into illegibility.
            let scale = max(1, proxy.size.height / outline.totalWeight)
            ScrollView {
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
            .scrollIndicators(.hidden)
            .scrollPosition($position)
            // Kept where the reader is, from the map's own geometry rather
            // than the chat's uneven offset.
            .onChange(of: outline.position(of: visiblePieceIDs)) { _, fraction in
                guard let fraction else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    position.scrollTo(point: CGPoint(
                        x: 0,
                        y: max(0, outline.totalWeight * scale * fraction - proxy.size.height / 2)
                    ))
                }
            }
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
            case .prompt(let text), .question(let text):
                label(text)
            case .response:
                area
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.chatMinimapEntry)
        // One driver for both halves of the emphasis, so the weight and the
        // darkening arrive together rather than the color easing while the
        // weight snaps.
        .modifier(MinimapEmphasis(progress: isVisible ? 1 : 0))
        .animation(.easeOut(duration: 0.2), value: isVisible)
    }

    /// User input takes its natural line height rather than its share of the
    /// conversation: a one-line question between two long replies is the
    /// landmark being scanned for, so it has to stay readable.
    private func label(_ text: String) -> some View {
        Text(text.isEmpty ? "…" : text)
            .font(typography.caption.font)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(.rect)
            .help(text)
    }

    private var area: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
    }
}

/// Fades an entry between its resting and on-screen emphasis.
///
/// `Emphasis` resolves to a `HierarchicalShapeStyle` and `fontWeight` takes a
/// discrete `Font.Weight`, neither of which interpolates — so both would snap
/// while anything else on the row eased. Driving a single animatable fraction
/// and deriving a concrete opacity and weight from it animates the pair
/// together.
private struct MinimapEmphasis: ViewModifier, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.primary.opacity(Self.restingOpacity + progress * Self.emphasisRange))
            .fontWeight(progress > 0.5 ? .semibold : .regular)
    }

    /// What an off-screen entry reads at. The map is supporting chrome, so
    /// even its resting state sits below body text.
    private static let restingOpacity: Double = 0.4
    private static let emphasisRange: Double = 0.6
}
