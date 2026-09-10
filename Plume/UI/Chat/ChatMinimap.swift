import SwiftUI

/// A skimmable map of the conversation, down the right edge of the chat.
///
/// The reader anchors on their own input, so prompts and questions keep their
/// text while a whole run of agent output between two of them collapses into
/// one tinted area. Clicking an entry puts it at the top of the viewport.
///
/// At rest this is a narrow rail of bars, wide enough to show the rhythm of
/// the conversation and nothing else. Hovering anywhere along it reveals the
/// full map over the chat, where the cursor's height picks the part of the
/// conversation shown — the same gesture as running a finger down the edge
/// of a book.
struct ChatMinimap: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme

    let outline: ChatOutline
    /// The piece ids on screen, so the reader can see where they are.
    var visiblePieceIDs: Set<String> = []
    /// Scrolls the list to a piece id.
    let onSelect: (String) -> Void

    /// Wide enough for a few words of a prompt. Only the rail holds layout
    /// space, so this is what the revealed map draws over the chat rather
    /// than a contribution to the pane's minimum width.
    static let width: CGFloat = 168

    /// The rail's width, which is what the minimap costs the chat. A tenth
    /// of the revealed map: enough for a prompt's bar to read as wider than
    /// a response's, and little enough to sit beside the text unnoticed.
    static let collapsedWidth: CGFloat = 17

    /// Follows the conversation rather than being scrolled by hand.
    @State private var position = ScrollPosition(edge: .top)

    @State private var isRevealed = false
    /// Where the cursor sits in the rail, 0 at the top and 1 at the bottom,
    /// which is the fraction of the conversation the revealed map shows.
    @State private var hoverFraction: CGFloat?

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
                            isRevealed: isRevealed,
                            onSelect: onSelect
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Clear of the background's fade, so a prompt's first
                // characters are never the ones drawn over bare chat.
                .padding(.leading, isRevealed ? Self.contentInset : 0)
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(true)
            .scrollPosition($position)
            // Kept where the reader is, from the map's own geometry rather
            // than the chat's uneven offset. While the cursor is in the rail
            // it drives the map instead, so following the chat would fight
            // it for the same scroll position.
            .onChange(of: outline.position(of: visiblePieceIDs)) { _, fraction in
                guard !isRevealed, let fraction else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    position.scrollTo(point: CGPoint(x: 0, y: offset(for: fraction, scale: scale, in: proxy.size)))
                }
            }
            .onChange(of: hoverFraction) { _, fraction in
                guard let fraction else { return }
                position.scrollTo(point: CGPoint(x: 0, y: offset(for: fraction, scale: scale, in: proxy.size)))
            }
            // Drawn wider than the rail it sits in, toward the chat. Only
            // the rail holds layout space, so revealing the map never
            // reflows the conversation under the cursor.
            .frame(width: isRevealed ? Self.width : Self.collapsedWidth, alignment: .trailing)
            .background(mapBackground)
            // Whatever the map currently occupies is what answers the
            // pointer: the rail while it is closed, the whole map once it is
            // open, so reading down the labels keeps driving it.
            .contentShape(.rect)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    hoverFraction = min(max(point.y / max(1, proxy.size.height), 0), 1)
                case .ended:
                    hoverFraction = nil
                }
            }
            .frame(width: Self.collapsedWidth, alignment: .trailing)
        }
        .frame(width: Self.collapsedWidth)
        .padding(.vertical, dimensions.verticalPadding)
        .padding(.trailing, Self.edgeInset)
        .accessibilityIdentifier(AccessibilityID.chatMinimap)
        .onChange(of: hoverFraction == nil) { _, away in
            withAnimation(.easeOut(duration: 0.15)) { isRevealed = !away }
        }
    }

    /// The chat's own background, so the revealed map reads as part of the
    /// surface it covers rather than as a panel over it. It fades out toward
    /// the conversation instead of ending on an edge, which would draw a line
    /// down the text it overlaps.
    @ViewBuilder private var mapBackground: some View {
        if isRevealed {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: chatBackground, location: Self.backgroundFalloff),
                    .init(color: chatBackground, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .padding(.trailing, -Self.edgeInset)
        }
    }

    private var chatBackground: Color {
        ThemeChrome.background(for: colorScheme) ?? Color(nsColor: .textBackgroundColor)
    }

    /// Puts `fraction` of the way down the conversation in the middle of the
    /// pane, clamped so neither end scrolls past itself.
    private func offset(for fraction: CGFloat, scale: CGFloat, in size: CGSize) -> CGFloat {
        let mapped = outline.totalWeight * scale * fraction - size.height / 2
        return max(0, min(mapped, max(0, outline.totalWeight * scale - size.height)))
    }

    /// Small enough that the map still reads as continuous mass, large enough
    /// that neighbouring entries do not merge.
    private static let entrySpacing: CGFloat = 2

    /// The shortest an entry draws, so a brief one stays clickable however
    /// long the conversation grows around it.
    private static let minimumEntryHeight: CGFloat = 3

    private static let edgeInset: CGFloat = 8

    /// How far across the revealed map the background has fully arrived.
    private static let backgroundFalloff: CGFloat = 0.3

    /// Keeps the entries clear of the background's fade. Derived from it, so
    /// tuning the falloff cannot leave text stranded over bare chat.
    private static var contentInset: CGFloat { width * backgroundFalloff }
}

/// One entry: a legible line for something the user said or was asked, a
/// tinted area for a run of the agent's output.
private struct ChatMinimapEntryView: View, ThemedView {
    @Environment(\.theme) var theme

    let entry: ChatOutline.Entry
    let height: CGFloat
    /// Whether any of what this entry covers is on screen.
    let isVisible: Bool
    /// Whether the map is showing its full width.
    let isRevealed: Bool
    let onSelect: (String) -> Void

    var body: some View {
        Button { onSelect(entry.id) } label: {
            switch entry.kind {
            case .prompt(let text), .question(let text):
                if isRevealed { label(text) } else { bar }
            case .response:
                area
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.chatMinimapEntry)
        .modifier(MinimapEmphasis(progress: isVisible ? 1 : 0, ceiling: entry.kind.minimapOpacityCeiling))
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

    /// What a prompt is in the rail: a bar the height of the line it would
    /// draw. Full width and full opacity, so the rail reads as the prompts
    /// with the responses as the gaps between them.
    private var bar: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .frame(height: Self.promptBarHeight)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.vertical, 2)
            .contentShape(.rect)
            .help(entry.kind.text)
    }

    /// A response is the same shape either way — only its width changes, and
    /// in the rail it is inset so the prompts are the wider mark.
    private var area: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .frame(height: height)
            .frame(
                maxWidth: .infinity,
                alignment: isRevealed ? .leading : .trailing
            )
            .padding(.leading, isRevealed ? 0 : Self.responseInset)
            .contentShape(.rect)
    }

    private static let promptBarHeight: CGFloat = 4

    /// How much narrower a response draws than a prompt in the rail. The two
    /// are told apart by width as well as by weight, since at this size a
    /// difference in opacity alone is easy to miss.
    private static let responseInset: CGFloat = 5
}

/// Fades an entry between its resting and on-screen emphasis.
///
/// `Emphasis` resolves to a `HierarchicalShapeStyle`, which does not
/// interpolate, so it would snap while anything else on the row eased.
/// Driving a single animatable fraction and deriving a concrete opacity from
/// it lets the emphasis ease.
///
/// Only the color carries the emphasis. Weight is deliberately left alone:
/// the map is a column of text the reader scans while scrolling, and
/// re-weighting a line reflows its glyphs, so entries would shift under the
/// eye as the viewport moves across them.
private struct MinimapEmphasis: ViewModifier, Animatable {
    var progress: Double
    /// The most this entry ever asserts itself.
    var ceiling: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.foregroundStyle(.primary.opacity(ceiling * (Self.restingFraction + progress * Self.emphasisRange)))
    }

    /// What an off-screen entry reads at, as a fraction of its ceiling. The
    /// map is supporting chrome, so even its emphasized state sits below body
    /// text.
    private static let restingFraction: Double = 0.4
    private static let emphasisRange: Double = 0.6
}

private extension ChatOutline.Kind {
    /// The line this entry carries, for the rail's tooltip.
    var text: String {
        switch self {
        case .prompt(let text), .question(let text): text
        case .response: ""
        }
    }

    /// A response draws as a filled shape rather than glyphs, and a solid
    /// area reads far heavier than a line of text at the same opacity. Sitting
    /// it below the prompts keeps them the thing the eye lands on.
    var minimapOpacityCeiling: Double {
        isUserInput ? 1 : 0.45
    }
}
