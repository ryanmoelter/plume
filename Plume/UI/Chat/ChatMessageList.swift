import SwiftUI

/// The scrolling list of chat messages.
///
/// Its own `View` struct rather than a method on `ChatTabView`, because
/// SwiftUI invalidates a body as a unit. `ChatTabView` also renders the
/// statusline, which reads the git and surface stores plus the live headless
/// session — all of which change while a scroll is in flight. Built inline, every one of those
/// rebuilt this list. Here, only `messages`, `status` and the theme reach it,
/// so nothing else can.
struct ChatMessageList: View, ThemedView {
    @Environment(\.theme) var theme

    let messages: [ChatMessage]
    let subagents: [SubagentTranscript]
    let status: TaskStatus
    let bottomPadding: CGFloat
    /// How much of the list's bottom edge the floating bottom chrome covers —
    /// the composer panel plus any queued-message chips above it, including
    /// the gap below the panel. The last message must be scrollable clear of
    /// the glass, and the jump-to-bottom button must sit above all of it.
    var floatingPanelHeight: CGFloat = 0
    /// Set on the headless transport, so pending permissions can be docked
    /// after the last message. Nil leaves the list read-only.
    var tabID: UUID?
    var onOpenSubagent: (SubagentTranscript) -> Void = { _ in }

    /// Distance from the bottom, held in a reference box rather than `@State`.
    ///
    /// `onScrollGeometryChange` fires on every scroll frame, so writing this
    /// to `@State` invalidated the list once per frame while scrolling.
    /// Nothing renders from it — it only decides whether `isDetached` flips.
    @State private var followState = ScrollFollowState()

    /// Drives the jump-to-bottom button. Following the newest content is not
    /// done through this: `defaultScrollAnchor(.bottom, for: .sizeChanges)`
    /// keeps a list that is already at the bottom there as content grows.
    @State private var position = ScrollPosition(edge: .bottom)

    /// Whether the user has scrolled away far enough to want a jump back.
    /// Unlike `followState`, this does render, so it is `@State` — the
    /// `ChatScrollAnchor` threshold keeps it from flipping every frame.
    @State private var isDetached = false

    @State private var settings = AppSettings.shared

    /// The list's lazy items. Built in `onChange` rather than in `body`:
    /// markdown parsing must not run on the render path, and writing
    /// observable state during a body is what spins SwiftUI forever.
    @State private var pieces: [ChatPiece] = []
    @State private var cache = ChatPieceCache()

    /// The ids the last rebuild produced, and the overlay it was built from,
    /// so the next one can name what arrived. See `ChatListMotion`.
    @State private var previousPieceIDs: [String] = []
    @State private var previousStreaming = ChatStreamHandoff.Overlay()

    /// The pieces that grow into place. Only replaced when a rebuild actually
    /// brings some, so a piece has time to mount and read it — an id left
    /// here after the row has measured itself does nothing.
    @State private var arrivals: Set<String> = []

    /// Names this list to `PLUME_CHAT_ITEM_STATS`. Every tab stays mounted,
    /// so several lists measure at once and one set of numbers would be a
    /// blend of all of them.
    @State private var statsToken = UUID()

    private var session: HeadlessSession? {
        guard let tabID else { return nil }
        return HeadlessSessionManager.shared.existingSession(for: tabID)
    }

    /// Exact, when the headless session knows which calls are stalled.
    /// Empty on the TUI transport, where rows fall back to position.
    private var pendingToolUseIDs: Set<String> {
        Set(session?.pendingPermissions.compactMap(\.toolUseID) ?? [])
    }

    /// The live turn, minus whatever the transcript has already caught up on.
    private var streaming: ChatStreamHandoff.Overlay {
        guard let session else { return ChatStreamHandoff.Overlay() }
        return ChatStreamHandoff.overlay(
            streamedText: session.streamingText,
            streamedThinking: session.streamingThinking,
            transcriptTail: ChatStreamHandoff.trailingAssistantMarkdown(messages)
        )
    }

    var body: some View {
        ScrollView {
            // Lazy so a long transcript only builds the rows on screen.
            //
            // No `ScrollViewReader` and no `scrollTo`: a programmatic scroll
            // into a lazy stack whose rows are still estimates retargets on
            // every placement pass, and the stack's prefetch asks for another
            // pass each time. With a stream growing the content it never
            // settles and pins the main thread — `docs/chat-list-hang.md`.
            // The scroll view's own anchors follow the bottom instead.
            LazyVStack(alignment: .leading, spacing: 0) {
                // One item per piece, not per message, so no item is tall
                // enough to make the stack's height estimates oscillate.
                // Every gap between items is the following one's top inset.
                // Every piece eases its own height, and one that has just
                // arrived grows into place from nothing, which is what
                // pushes the conversation up. No `.transition` and no
                // animated transaction around this `ForEach`: an animated
                // diff inside a lazy stack is the shape the hang doc warns
                // about, and it would also play an entrance for any row the
                // stack happens to realize during a scroll. `ChatPieceView`
                // owns the frame so the wash animates with it.
                ForEach(pieces) { piece in
                    ChatPieceView(
                        piece: piece,
                        animatesHeight: settings.animateChatMotion,
                        growsFromZero: arrivals.contains(piece.id)
                    )
                    .listItemPadding(bleed: true, column: .unpadded, vertical: false)
                    .padding(.top, piece.paysInsetOutside ? piece.topInset : 0)
                    .padding(.bottom, piece.bottomInset)
                    .chatItemStatsProbe(list: statsToken, id: piece.id, kind: piece.kindName)
                }
                if let tabID {
                    SubagentListView(subagents: subagents, tabID: tabID, onOpen: onOpenSubagent)
                        .listItemPadding(bleed: true, column: .unpadded)
                    PendingPermissionDock(tabID: tabID)
                        .listItemPadding(bleed: true, column: .unpadded)
                }
                // The room the floating composer panel covers. Eased on the
                // leaf, so a composer that grows a line slides the
                // conversation instead of snapping it, and the transaction
                // reaches nothing else.
                Color.clear
                    .frame(height: bottomPadding + floatingPanelHeight)
                    .animation(
                        settings.animateChatMotion ? .easeOut(duration: 0.2) : nil,
                        value: floatingPanelHeight
                    )
            }
            .scrollTargetLayout()
        }
        .chatItemStatsViewport(list: statsToken)
        .onChange(of: messages, initial: true) { rebuildPieces() }
        .onChange(of: status) { rebuildPieces() }
        .onChange(of: pendingToolUseIDs) { rebuildPieces() }
        .onChange(of: streaming) { rebuildPieces() }
        .onChange(of: dimensions.contentWidth) { rebuildPieces() }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .onScrollGeometryChange(for: ChatScrollGeometry.self) { geometry in
            ChatScrollGeometry(
                distanceFromBottom: max(0, geometry.contentSize.height - geometry.visibleRect.maxY),
                contentHeight: geometry.contentSize.height,
                viewportHeight: geometry.containerSize.height
            )
        } action: { old, new in
            // Every tab stays mounted, hidden by opacity, so an offscreen
            // list keeps reporting geometry. Its viewport measures zero,
            // which reads as a huge distance from the bottom.
            guard new.viewportHeight > 0 else { return }
            if ChatScrollAnchor.reflectsUserScroll(
                previousContentHeight: old.contentHeight,
                newContentHeight: new.contentHeight
            ) {
                followState.distanceFromBottom = new.distanceFromBottom
            }
            // Off the recorded position, never off `new`: growth pushes
            // the bottom away from the viewport, so reading the live
            // distance would flash the button on every streamed chunk.
            // Off the update pass: this action can run several times in a
            // single frame, and writing view state from inside one is what
            // SwiftUI reports as modifying state during a view update.
            let detached = ChatScrollAnchor.isDetached(
                distanceFromBottom: followState.distanceFromBottom
            )
            guard detached != isDetached else { return }
            Task { @MainActor in
                if detached != isDetached { isDetached = detached }
            }
        }
        #if DEBUG
        .task(id: pieces.count) {
            await ScrollExercise.run(pieceIDs: pieces.map(\.id)) { id in
                position.scrollTo(id: id, anchor: .top)
            }
        }
        #endif
        // Always mounted, shown by opacity. Inserting it on demand
        // resizes the scroll view, which reports new geometry, which
        // toggles it again.
        .overlay(alignment: .bottom) {
            scrollToBottomButton {
                // The programmatic scroll reports as growth-free
                // geometry, but only after the fact; resetting here
                // hides the button at once.
                followState.distanceFromBottom = 0
                isDetached = false
                position.scrollTo(edge: .bottom)
            }
            .opacity(isDetached ? 1 : 0)
            .allowsHitTesting(isDetached)
        }
    }

    private func rebuildPieces() {
        #if DEBUG
        let started = ContinuousClock.now
        #endif
        let overlay = streaming
        let rebuilt = cache.pieces(
            for: messages,
            status: status,
            hiddenToolUseIDs: pendingToolUseIDs,
            streaming: overlay,
            dimensions: dimensions
        )
        let ids = rebuilt.map(\.id)
        let arrived = ChatListMotion.arrivals(
            previous: previousPieceIDs,
            current: ids,
            streamingChanged: overlay != previousStreaming
        )
        if !arrived.isEmpty { arrivals = arrived }
        previousPieceIDs = ids
        previousStreaming = overlay
        pieces = rebuilt
        #if DEBUG
        ChatItemStats.shared.record(list: statsToken, rebuild: started.duration(to: .now))
        ChatItemStats.shared.setOrder(pieces.map(\.id), for: statsToken)
        #endif
    }

    private func scrollToBottomButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .padding(9)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        .padding(.bottom, floatingPanelHeight + 12)
        .help("Jump to the newest message")
    }
}

/// Mutable scroll state that must not invalidate a view when it changes.
///
/// A class, so writing to it from a per-frame scroll callback is not a
/// SwiftUI state change.
@MainActor
private final class ScrollFollowState {
    var distanceFromBottom: CGFloat = 0
}
