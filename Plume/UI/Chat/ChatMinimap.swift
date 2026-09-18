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
    /// Scrolls the list to the very bottom, where it starts following new
    /// content again.
    var onSelectEnd: () -> Void = {}
    /// What the composer and anything floating above it cover, matching the
    /// chat's own bottom margin.
    var bottomInset: CGFloat = 0
    /// The pane's width, which decides whether the rail has room to spread.
    var viewportWidth: CGFloat = 0

    /// Wide enough for a few words of a prompt. The minimap holds no layout
    /// space at all, so this is what the revealed map draws over the chat
    /// rather than a contribution to the pane's minimum width.
    static let width: CGFloat = 260

    /// The rail's width, and so a prompt bar's. The rail overlays the chat
    /// rather than taking a column, so this plus `edgeInset` on either side
    /// has to fit within `Dimensions.horizontalBleedPadding` — otherwise the
    /// rail crosses a bleed item's column and sits over the text.
    static let collapsedWidth: CGFloat = 8

    /// Follows the conversation rather than being scrolled by hand.
    @State private var position = ScrollPosition(edge: .top)

    @State private var isRevealed = false
    /// Where the cursor sits in the rail, 0 at the top and 1 at the bottom,
    /// which is the fraction of the conversation the revealed map shows.
    @State private var hoverFraction: CGFloat?
    /// What the entries actually measure, which is what the map scrolls
    /// through.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: isRevealed ? Self.entrySpacing * 2 : Self.entrySpacing) {
                    ForEach(outline.entries) { entry in
                        ChatMinimapEntryView(
                            entry: entry,
                            height: max(Self.minimumEntryHeight, entry.weight * Self.pointsPerWeight),
                            isVisible: !entry.pieceIDs.isDisjoint(with: visiblePieceIDs),
                            isRevealed: isRevealed,
                            railWidth: railWidth,
                            // The end of the map means the end of the
                            // conversation, not the top of its last entry:
                            // that is where the list picks up following new
                            // content, and anchoring the last entry to the
                            // top would stop short of it.
                            onSelect: entry.id == outline.entries.last?.id
                                ? { _ in onSelectEnd() }
                                : onSelect
                        )
                    }
                }
                // Held to at least the pane so a conversation too short to
                // fill it sits in the middle rather than hanging from the
                // top. Once the entries outgrow that the minimum stops
                // binding and the map scrolls as before.
                .frame(maxWidth: .infinity, minHeight: liveHeight(in: proxy.size), alignment: .leading)
                // Clear of the background's fade, so a prompt's first
                // characters are never the ones drawn over bare chat.
                .padding(.leading, isRevealed ? Self.contentInset : 0)
                // Read rather than derived from the weights: a revealed
                // prompt draws as a line of text, not as the bar its weight
                // describes, so the two heights are far apart and scrolling
                // against the wrong one strands the end of the map.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(true)
            .scrollPosition($position)
            // The chat's top margin, so the map starts level with the
            // conversation it maps. The bottom only has to clear the
            // composer — the map is a column of small marks rather than
            // text, so it can run closer to the edge than the chat does, and
            // an entry still scrolls out from under the composer before it
            // can be clicked.
            .contentMargins(.top, dimensions.verticalPadding, for: .scrollContent)
            .contentMargins(.bottom, bottomInset + dimensions.verticalPadding, for: .scrollContent)
            // Kept where the reader is, from the map's own geometry rather
            // than the chat's uneven offset. While the cursor is in the rail
            // it drives the map instead, so following the chat would fight
            // it for the same scroll position.
            //
            // Watched together with the reveal so that closing re-asserts
            // the chat's position. The chat has not moved while the pointer
            // was steering, so nothing else would put the map back, and it
            // would keep whatever the pointer left it showing.
            .onChange(of: FollowDrive(position: outline.position(of: visiblePieceIDs), revealed: isRevealed)) { _, drive in
                guard !drive.revealed, let fraction = drive.position else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    position.scrollTo(point: CGPoint(x: 0, y: offset(for: fraction, in: proxy.size)))
                }
            }
            // Keyed to the pointer and to the height it is measured
            // against. Opening the map both doubles the space between its
            // entries and turns each prompt into a line of text, so the
            // content grows as it reveals; an offset computed once from the
            // closed height would be short by that growth, and the map
            // would lurch when the new height arrived. Recomputing as the
            // height settles keeps the pointer pointing at the same place
            // throughout.
            .onChange(of: ScrollDrive(fraction: hoverFraction, contentHeight: contentHeight)) { _, drive in
                guard let fraction = drive.fraction else { return }
                position.scrollTo(point: CGPoint(x: 0, y: offset(for: fraction, in: proxy.size)))
            }
            // Drawn wider than the rail it sits in, toward the chat. Only
            // the rail holds layout space, so revealing the map never
            // reflows the conversation under the cursor.
            .frame(width: isRevealed ? Self.width : railWidth, alignment: .trailing)
            .background(mapBackground)
            .frame(width: railWidth, alignment: .trailing)
            // Answered by a region that does not move when the map opens.
            // Hanging it off the map's own body would mean revealing the map
            // moved the region the pointer is being tracked in, which
            // changes whether the pointer is inside it — the map would open,
            // lose the pointer, close, and find it again.
            .overlay(alignment: .trailing) {
                Color.clear
                    .frame(width: isRevealed ? Self.width : hoverWidth)
                    // Out over the trailing inset as well, so the target runs
                    // to the window edge rather than stopping short of it.
                    .padding(.trailing, -railInset)
                    .contentShape(.rect)
                    // Watches the pointer without standing in its way: this
                    // sits over the entries and the resize handle, and a
                    // hit-testable overlay would swallow every click meant
                    // for them.
                    .allowsHitTesting(false)
                    .onContinuousHover(coordinateSpace: .named(Self.railSpace)) { phase in
                        switch phase {
                        case .active(let point):
                            // Against the space the entries occupy, not the
                            // rail's full height: the margins are not part of
                            // the conversation, so travelling over them would
                            // mean the ends of the map were unreachable.
                            let live = max(1, liveHeight(in: proxy.size))
                            hoverFraction = min(max((point.y - dimensions.verticalPadding) / live, 0), 1)
                        case .ended:
                            hoverFraction = nil
                        }
                    }
            }
            .coordinateSpace(.named(Self.railSpace))
        }
        .frame(width: railWidth)
        .padding(.trailing, railInset)
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
            .padding(.trailing, -railInset)
        }
    }

    private var chatBackground: Color {
        ThemeChrome.background(for: colorScheme) ?? Color(nsColor: .textBackgroundColor)
    }

    /// The room the entries actually get: the pane less the margins the
    /// content is inset by, which are not part of the conversation.
    private func liveHeight(in size: CGSize) -> CGFloat {
        max(0, size.height - 2 * dimensions.verticalPadding - bottomInset)
    }

    /// Puts `fraction` of the way down the conversation in the middle of the
    /// pane, clamped so neither end scrolls past itself.
    private func offset(for fraction: CGFloat, in size: CGSize) -> CGFloat {
        // Both margins count as content to scroll past. Leaving the top one
        // out stops short of the end by its height, which cuts off the last
        // entry.
        let travel = max(0, contentHeight + 2 * dimensions.verticalPadding + bottomInset - size.height)
        return travel * Self.eased(fraction)
    }

    /// Maps where the pointer is to how far through the conversation the map
    /// has travelled.
    ///
    /// The ends are dead bands: the first and last twentieth of the rail pin
    /// to the top and the bottom, so reaching either end does not demand the
    /// very edge of the window. Between them the curve is smoothstep, which
    /// leaves the pointer least sensitive where it enters and most sensitive
    /// through the middle — most of the conversation is covered by the middle
    /// of the travel, where the hand is steadiest.
    static func eased(_ fraction: CGFloat) -> CGFloat {
        let span = liveRange.upperBound - liveRange.lowerBound
        let t = min(max((fraction - liveRange.lowerBound) / span, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Where the rail starts and stops responding. Short of the very edges,
    /// which are hard to hit and easy to overshoot.
    static let liveRange: ClosedRange<CGFloat> = 0.05...0.95

    /// Small enough that the rail still reads as continuous mass, large
    /// enough that neighbouring entries do not merge. The open map doubles
    /// it, where the entries are lines of text rather than marks and want
    /// the air between them.
    private static let entrySpacing: CGFloat = 2

    /// How tall a unit of weight draws. Fixed rather than fitted to the pane
    /// so the rail reads at the same density whatever the conversation's
    /// length — a bar means the same thing in a long chat as in a short one.
    /// `ChatOutlineBuilder`'s weights are already authored in rough points,
    /// so this is a correction to them rather than a scale of its own.
    /// Raising it spaces the conversation out and reaches the scrolling
    /// threshold sooner.
    private static let pointsPerWeight: CGFloat = 1

    /// The shortest an entry draws, so a brief one stays clickable however
    /// long the conversation grows around it.
    private static let minimumEntryHeight: CGFloat = 3

    private static let edgeInset: CGFloat = 2

    /// The narrowest target the rail ever offers the pointer. The bars alone
    /// are too thin to aim at, and unlike them the target reaches the window
    /// edge — so throwing the pointer at the edge always finds it. Once the
    /// rail is wider than this the footprint takes over.
    private static let hoverWidth: CGFloat = 16

    /// The bars at their widest, and how far they sit from the window edge
    /// there. Between the two ends the rail interpolates, so it grows with
    /// the pane rather than snapping at a threshold.
    private static let spreadWidth: CGFloat = collapsedWidth * 2
    private static let spreadInset: CGFloat = 8

    /// Room left between the bars and the bleed column at full size. Nothing
    /// draws it — it is what stops the rail from crowding the conversation
    /// once both are at their full width. It matches the trailing inset, so
    /// the bars sit in equal air on both sides.
    private static let spreadLeading: CGFloat = spreadInset

    /// What the rail asks of the pane at full size: the bars, the inset
    /// holding them off the window edge, and the gap keeping them off the
    /// bleed column.
    private static let spreadCost: CGFloat = spreadWidth + spreadInset + spreadLeading

    /// How much of its full size the rail can afford, 0 while the bars are
    /// still within the bleed column's padding and 1 once they clear it with
    /// room to spare.
    ///
    /// The rail takes whatever the conversation is not using, up to the size
    /// it wants. Growth starts where the bars would otherwise reach into the
    /// padding beside a full-width bleed item, so widening the pane never
    /// costs the conversation anything.
    static func railSpread(forViewport width: CGFloat, dimensions: Dimensions) -> CGFloat {
        let slack = (width - dimensions.bleedWidth) / 2
        let floor = dimensions.horizontalBleedPadding
        guard slack > floor else { return 0 }
        return min((slack - floor) / (spreadCost - floor), 1)
    }

    static func railWidth(forViewport width: CGFloat, dimensions: Dimensions) -> CGFloat {
        let spread = railSpread(forViewport: width, dimensions: dimensions)
        return collapsedWidth + (spreadWidth - collapsedWidth) * spread
    }

    static func railInset(forViewport width: CGFloat, dimensions: Dimensions) -> CGFloat {
        let spread = railSpread(forViewport: width, dimensions: dimensions)
        return edgeInset + (spreadInset - edgeInset) * spread
    }

    /// What the rail draws: the bars and the inset holding them off the
    /// window edge. The pointer is offered this much, so the target grows
    /// with the rail rather than staying the size it needed when the bars
    /// were thinnest. The leading gap is deliberately left out — it is empty
    /// space over the conversation, and reaching into it made the map open
    /// while the pointer was still on the text.
    static func railFootprint(forViewport width: CGFloat, dimensions: Dimensions) -> CGFloat {
        railWidth(forViewport: width, dimensions: dimensions)
            + railInset(forViewport: width, dimensions: dimensions)
    }

    private var railWidth: CGFloat {
        Self.railWidth(forViewport: viewportWidth, dimensions: dimensions)
    }

    /// What the pointer is given to aim at, never less than a comfortable
    /// target however narrow the bars are drawn.
    private var hoverWidth: CGFloat {
        max(Self.hoverWidth, Self.railFootprint(forViewport: viewportWidth, dimensions: dimensions))
    }

    private var railInset: CGFloat {
        Self.railInset(forViewport: viewportWidth, dimensions: dimensions)
    }

    /// The rail's own space, which stays put while the map grows out of it,
    /// so the pointer's height means the same thing open or closed.
    private static let railSpace = "chatMinimapRail"

    /// How far across the revealed map the background has fully arrived.
    private static let backgroundFalloff: CGFloat = 0.3

    /// Keeps the entries clear of the background's fade. Derived from it, so
    /// tuning the falloff cannot leave text stranded over bare chat.
    private static var contentInset: CGFloat { width * backgroundFalloff }
}

/// What the map's scroll position is a function of: where the pointer is,
/// and how tall the content it is pointing into has become.
private struct ScrollDrive: Equatable {
    var fraction: CGFloat?
    var contentHeight: CGFloat
}

/// What returns the map to the conversation: where the chat is, and whether
/// the pointer has stopped overriding it.
private struct FollowDrive: Equatable {
    var position: CGFloat?
    var revealed: Bool
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
    /// The rail's current width, which a collapsed bar is drawn against.
    let railWidth: CGFloat
    let onSelect: (String) -> Void

    var body: some View {
        Button { onSelect(entry.id) } label: {
            if entry.kind.isUserInput {
                promptEntry(entry.kind.text)
            } else {
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
    ///
    /// The bar the rail shows is this same view, not a second one swapped in
    /// for it — the text fades out over a filled shape that shrinks to the
    /// bar's height. Two views would be two identities to SwiftUI, and the
    /// transition would slide one out while the other grew.
    private func promptEntry(_ text: String) -> some View {
        HStack(spacing: 3) {
            // Only what the user did not write themselves is marked, and
            // only at a size where the mark is legible.
            if let symbol = entry.kind.symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
            }
            Text(text.isEmpty ? "…" : text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(typography.caption.font)
        .opacity(isRevealed ? 1 : 0)
        // Collapsed, the text is only faded out — it still lays out at its
        // full length, and inside the scroll view that length is what the
        // rail's width resolves against. Without this a chat of long prompts
        // gets a wider rail than a chat of short ones.
        .frame(width: isRevealed ? nil : railWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: isRevealed ? nil : Self.promptBarHeight)
        .background {
            RoundedRectangle(cornerRadius: 1.5)
                .opacity(isRevealed ? 0 : 1)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .help(text)
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
            .padding(.leading, isRevealed ? 0 : responseInset)
            .contentShape(.rect)
    }

    private static let promptBarHeight: CGFloat = 4

    /// How much narrower a response draws than a prompt in the rail. The two
    /// are told apart by width as well as by weight, since at this size a
    /// difference in opacity alone is easy to miss. A response keeps half the
    /// rail whatever the rail's width, so the pair reads the same either way.
    private var responseInset: CGFloat { railWidth / 2 }
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
    /// A response draws as a filled shape rather than glyphs, and a solid
    /// area reads far heavier than a line of text at the same opacity. Sitting
    /// it below the prompts keeps them the thing the eye lands on.
    var minimapOpacityCeiling: Double {
        isUserInput ? 1 : 0.45
    }
}
