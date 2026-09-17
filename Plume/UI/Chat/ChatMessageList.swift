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

    /// Scroll bookkeeping, held in a reference box rather than `@State`.
    ///
    /// `onScrollGeometryChange` fires on every scroll frame, so writing this
    /// to `@State` invalidated the list once per frame while scrolling.
    /// Nothing renders from it — it decides whether the jump-back button
    /// shows, and the button reads its own mirror of that.
    @State private var followState = ScrollFollowState()

    /// Drives the jump-to-bottom button. Following the newest content is not
    /// done through this: `defaultScrollAnchor(.bottom, for: .sizeChanges)`
    /// keeps a list that is already at the bottom there as content grows.
    @State private var position = ScrollPosition(edge: .bottom)

    /// Whether the user has scrolled away far enough to want a jump back.
    ///
    /// An observable box rather than `@State`, and read only by the button
    /// itself: read here, the flag re-ran this body — the one that builds the
    /// `LazyVStack` — every time it flipped, which is the loop
    /// `docs/chat-list-hang.md` records as hypothesis 4. `followState` holds
    /// the latch behind it; this is only the mirror the button renders from.
    @State private var jumpButton = JumpButtonVisibility()

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

    /// The stream blocks that should type from nothing rather than appear
    /// whole. See `ChatListMotion.openings`.
    @State private var openings: Set<String> = []

    /// Keeps this chat's reveals from typing over each other. One per list,
    /// which is one per tab.
    @State private var revealClock = RevealClock()

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

    /// The conversation reduced to its prompts, rebuilt beside the pieces it
    /// reads so the markdown is parsed once.
    @State private var outline = ChatOutline()

    /// The piece ids currently on screen, so the map can mark where the
    /// reader is. Reported by the scroll view in one callback rather than by
    /// a per-row visibility observer, which would be one observer per
    /// realized item.
    @State private var visiblePieceIDs: Set<String> = []

    /// The piece a downward jump is heading for. Only that row reports its
    /// frame, so the list carries one geometry observer at most, not one
    /// per realized item.
    @State private var jumpTargetID: String?

    /// The custom list's handle, and the message ids of the last rebuild so
    /// a prompt the user just sent can be told from a transcript loading.
    @State private var commands = ChatListCommands()
    @State private var previousMessageIDs: [String] = []
    @Environment(\.chatFontSize) private var chatFontSize
    @Environment(\.chatLinkDirectory) private var linkDirectory

    private static let contentSpace = "chatContent"

    /// Fixed for this list's life: switching containers under a mounted
    /// list would rebuild every row, so the setting applies to the next
    /// chat opened.
    @State private var engine = AppSettings.shared.effectiveChatListEngine

    var body: some View {
        HStack(spacing: 0) {
            list
            if !outline.isEmpty {
                ChatMinimap(
                    outline: outline,
                    visiblePieceIDs: visiblePieceIDs,
                    onSelect: { jump(to: $0) },
                    onSelectEnd: { jumpToBottom(animated: true) },
                    bottomInset: floatingPanelHeight
                )
            }
        }
    }

    private var list: some View {
        Group {
            switch engine {
            case .lazyStack: lazyList
            case .custom: customList
            }
        }
        .onChange(of: messages, initial: true) { rebuildPieces() }
        .onChange(of: status) { rebuildPieces() }
        .onChange(of: pendingToolUseIDs) { rebuildPieces() }
        .onChange(of: streaming) { rebuildPieces() }
        .onChange(of: dimensions.contentWidth) { rebuildPieces() }
        #if DEBUG
        .task(id: pieces.count) {
            await ScrollExercise.run(pieceIDs: pieces.map(\.id)) { id in
                jump(to: id)
            }
        }
        #endif
        .overlay(alignment: .bottom) {
            ChatJumpToBottomButton(visibility: jumpButton, bottomInset: floatingPanelHeight) {
                // The programmatic scroll reports as growth-free
                // geometry, but only after the fact; resetting here
                // hides the button at once.
                followState.distanceFromBottom = 0
                followState.detached = false
                jumpButton.isDetached = false
                jumpToBottom(animated: engine == .custom)
            }
        }
    }

    private var customList: some View {
        ChatListView(
            inputs: ChatListInputs(
                pieces: pieces,
                tabID: tabID,
                subagents: subagents,
                animate: settings.animateChatMotion,
                trailingInset: bottomPadding + floatingPanelHeight,
                chatFontSize: chatFontSize,
                workStartedAt: tabID.flatMap { StatusEngine.shared.workStarted(forTab: $0) },
                linkDirectory: linkDirectory,
                arrivals: arrivals,
                openings: openings
            ),
            revealClock: revealClock,
            commands: commands,
            onOpenSubagent: onOpenSubagent,
            onVisiblePieceIDs: { visiblePieceIDs = $0 },
            onDetachedChange: { jumpButton.isDetached = $0 }
        )
    }

    private var lazyList: some View {
        ScrollView {
            // Lazy so a long transcript only builds the rows on screen.
            //
            // Following the newest content is the scroll view's own job,
            // through `defaultScrollAnchor` — no `ScrollViewReader` and no
            // per-row `.id()`. `scrollTo` is reserved for a jump the user
            // asked for: the button below, and the minimap. The trials in
            // `docs/chat-list-hang.md` put the hang in the lazy stack's own
            // height estimation rather than in scrolling, so an animated
            // jump is fine; what is not is feeding a measured height back
            // into the piece model.
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
                        growsFromZero: arrivals.contains(piece.id),
                        typesFromZero: openings.contains(piece.id)
                    )
                    .listItemPadding(bleed: true, column: .unpadded, vertical: false)
                    .padding(.top, piece.paysInsetOutside ? piece.topInset : 0)
                    .padding(.bottom, piece.bottomInset)
                    .chatItemStatsProbe(list: statsToken, id: piece.id, kind: piece.kindName)
                    #if DEBUG
                    .chatItemOutline(id: piece.id, kind: piece.kindName)
                    #endif
                    .background {
                        if piece.id == jumpTargetID {
                            Color.clear.onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named(Self.contentSpace))
                            } action: { frame in
                                targetFrameChanged(frame)
                            }
                        }
                    }
                }
                if let tabID {
                    // Both draw nothing until they have something, so their
                    // height is the whole of their entrance and exit: a
                    // subagent starting, finishing and folding away, and a
                    // permission arriving, all ease the conversation above
                    // them instead of jumping it.
                    SubagentListView(subagents: subagents, tabID: tabID, onOpen: onOpenSubagent)
                        .listItemPadding(bleed: false, column: .unpadded)
                        .animatedHeight(enabled: settings.animateChatMotion)
                    PendingPermissionDock(tabID: tabID)
                        .listItemPadding(bleed: true, column: .unpadded)
                        .animatedHeight(enabled: settings.animateChatMotion)
                }
            }
            .scrollTargetLayout()
            // The content's own coordinate space, so a jump target's frame
            // is its scroll offset in one reading. Adding a viewport-relative
            // frame to the reported offset pairs two callbacks that are a
            // frame apart mid-animation, and lands short by that travel.
            .coordinateSpace(.named(Self.contentSpace))
        }
        .environment(\.revealClock, revealClock)
        .environment(\.workStartedAt, tabID.flatMap { StatusEngine.shared.workStarted(forTab: $0) })
        .chatItemStatsViewport(list: statsToken)
        .scrollPosition($position)
        // The room the floating composer panel covers, as a content margin
        // rather than a spacer row. A spacer inside `scrollTargetLayout` is
        // itself a scroll target, and the region it occupies still counts as
        // viewport — so a piece behind the glass read as visible and the
        // minimap marked the reader's place too far down. Eased so a
        // composer that gains a line slides the conversation.
        .contentMargins(.bottom, bottomPadding + floatingPanelHeight, for: .scrollContent)
        .animation(
            settings.animateChatMotion ? .easeOut(duration: 0.2) : nil,
            value: floatingPanelHeight
        )
        // The minimap says everything the indicator does and more, right
        // beside it, so two of them is one too many.
        .scrollIndicators(.hidden)
        .onScrollTargetVisibilityChange(idType: String.self) { ids in
            visiblePieceIDs = Set(ids)
        }
        .defaultScrollAnchor(.bottom)
        // Only while no downward jump is in flight. Scrolling *down* realizes
        // rows the lazy stack had only estimated, which changes the content
        // height; preserving the bottom distance through that drags the jump's
        // target down to the bottom edge, so a jump to a mid-conversation
        // prompt landed at the bottom of the viewport instead of the top.
        //
        // Keyed off the jump rather than off how far the reader has scrolled,
        // because this modifier feeds the scroll view's own anchoring, and a
        // value derived from the scroll position driving it is hypothesis 4 in
        // `docs/chat-list-hang.md`. `jumpTargetID` is already read by the
        // `ForEach` above, and only ever moves id → nil, so it cannot chatter.
        .defaultScrollAnchor(jumpTargetID == nil ? .bottom : nil, for: .sizeChanges)
        .onScrollGeometryChange(for: ChatScrollGeometry.self) { geometry in
            ChatScrollGeometry(
                distanceFromBottom: max(0, geometry.contentSize.height - geometry.visibleRect.maxY),
                contentHeight: geometry.contentSize.height,
                viewportHeight: geometry.containerSize.height,
                visibleMinY: geometry.visibleRect.minY
            )
        } action: { old, new in
            // Every tab stays mounted, hidden by opacity, so an offscreen
            // list keeps reporting geometry. Its viewport measures zero,
            // which reads as a huge distance from the bottom.
            guard new.viewportHeight > 0 else { return }
            followState.visibleMinY = new.visibleMinY
            if jumpTargetID != nil { scheduleSettle() }
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
                distanceFromBottom: followState.distanceFromBottom,
                wasDetached: followState.detached
            )
            guard detached != followState.detached else { return }
            followState.detached = detached
            Task { @MainActor in
                jumpButton.isDetached = detached
            }
        }
    }

    private func jumpToBottom(animated: Bool) {
        switch engine {
        case .custom:
            commands.scrollToBottom(animated: animated)
        case .lazyStack:
            if animated {
                withAnimation(.easeInOut(duration: 0.25)) {
                    position.scrollTo(edge: .bottom)
                }
            } else {
                position.scrollTo(edge: .bottom)
            }
        }
    }

    /// Puts the piece at the top of the viewport.
    ///
    /// The custom list resolves the target itself. In the lazy stack, above
    /// the viewport `scrollTo(id:anchor:)` is enough. Below it, the
    /// lazy stack resolves the request against an estimated frame, and once
    /// the target has entered from the bottom edge the scroll view treats
    /// the request as satisfied there — a repeat of it, or the same request
    /// with a different anchor, scrolls nothing. So a downward jump uses the
    /// anchored request only to get the target realized, and finishes on an
    /// offset computed from the realized row's frame.
    private func jump(to id: String) {
        if engine == .custom {
            commands.jump(to: id)
            return
        }
        guard let index = pieces.firstIndex(where: { $0.id == id }) else { return }
        let topVisibleIndex = pieces.indices.first { visiblePieceIDs.contains(pieces[$0].id) } ?? 0
        followState.targetY = nil
        followState.requestedY = nil
        followState.corrected = false
        jumpTargetID = index < topVisibleIndex ? nil : id
        withAnimation(.smooth(duration: 0.3)) {
            position.scrollTo(id: id, anchor: .top)
        }
    }

    /// Redirects the in-flight animation to the target's offset as soon as
    /// the row exists, so the motion stays one continuous scroll. A spring
    /// carries the velocity across the retarget. The frame is reported again
    /// if rows realizing above the target move it, and `settleJump` checks
    /// the landing.
    private func targetFrameChanged(_ frame: CGRect) {
        followState.targetY = frame.minY
        let y = frame.minY
        guard y != followState.requestedY else { return }
        followState.requestedY = y
        Task { @MainActor in
            withAnimation(.smooth(duration: 0.3)) {
                position.scrollTo(y: y)
            }
            scheduleSettle()
        }
    }

    /// The scroll has rested once the geometry has held still for a beat.
    private func scheduleSettle() {
        followState.settle?.cancel()
        followState.settle = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            settleJump()
        }
    }

    /// At rest both readings are current; re-aim if the row is not at the top.
    private func settleJump() {
        guard jumpTargetID != nil else { return }
        guard let targetY = followState.targetY else {
            jumpTargetID = nil
            return
        }
        let error = targetY - followState.visibleMinY
        guard abs(error) > 1, !followState.corrected else {
            jumpTargetID = nil
            return
        }
        followState.corrected = true
        // The anchored request can finish after the offset request and win,
        // leaving the position holding the target offset the view is not
        // at. Setting the same offset again is not a change, so first record
        // where the view actually is — which moves nothing — and then ask.
        position.scrollTo(y: followState.visibleMinY)
        Task { @MainActor in
            withAnimation(.smooth(duration: 0.3)) {
                position.scrollTo(y: targetY)
            }
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
        let opened = ChatListMotion.openings(previous: previousPieceIDs, current: ids)
        if !opened.isEmpty { openings = opened }
        previousPieceIDs = ids
        previousStreaming = overlay
        pieces = rebuilt
        outline = ChatOutlineBuilder.outline(from: rebuilt)
        pinSentPrompt(in: rebuilt)
        #if DEBUG
        ChatItemStats.shared.record(list: statsToken, rebuild: started.duration(to: .now))
        ChatItemStats.shared.setOrder(pieces.map(\.id), for: statsToken)
        #endif
    }

    /// A prompt the user just sent goes to the top of the viewport, with
    /// room below it for the reply. Detected from the transcript rather than
    /// the composer, so both transports and a queued message all count.
    ///
    /// Only a message appended to a conversation already showing: the first
    /// build is a transcript loading, and a resume replaces the whole list.
    private func pinSentPrompt(in pieces: [ChatPiece]) {
        let ids = messages.map(\.id)
        defer { previousMessageIDs = ids }
        guard !previousMessageIDs.isEmpty,
              ids.count > previousMessageIDs.count,
              ids.starts(with: previousMessageIDs) else { return }
        let appended = messages[previousMessageIDs.count...]
        guard let prompt = appended.last(where: { $0.role == .user }),
              let piece = pieces.first(where: { $0.messageID == prompt.id }) else { return }
        commands.pin(pieceID: piece.id)
    }
}

/// The jump-to-bottom button, and the only thing that renders from how far the
/// reader has scrolled.
///
/// Its own view so that reading the flag subscribes this body and not
/// `ChatMessageList`'s, which builds the `LazyVStack`. Always mounted and
/// shown by opacity: inserting it on demand resized the scroll view, which
/// reported new geometry, which toggled it again.
private struct ChatJumpToBottomButton: View {
    let visibility: JumpButtonVisibility
    let bottomInset: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .padding(9)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        .padding(.bottom, bottomInset + 12)
        .help("Jump to the newest message")
        .opacity(visibility.isDetached ? 1 : 0)
        .allowsHitTesting(visibility.isDetached)
    }
}

/// Whether the jump-to-bottom button is showing.
///
/// Observable and passed by reference, so only the button's own body reads the
/// flag. `ChatMessageList` writes it without ever reading it, which is what
/// keeps the list's body off the scroll position.
@MainActor
@Observable
private final class JumpButtonVisibility {
    var isDetached = false
}

/// Mutable scroll state that must not invalidate a view when it changes.
///
/// A class, so writing to it from a per-frame scroll callback is not a
/// SwiftUI state change.
@MainActor
private final class ScrollFollowState {
    var distanceFromBottom: CGFloat = 0
    var visibleMinY: CGFloat = 0
    /// The latch behind `ChatScrollAnchor.isDetached`, so the hysteresis' own
    /// input is not a view dependency either.
    var detached = false
    /// The jump target's scroll offset, once its row has realized.
    var targetY: CGFloat?
    /// The last content offset a retarget asked for, so an unchanged
    /// reading does not re-issue it.
    var requestedY: CGFloat?
    /// One correction covers the lost race; a second only adds a segment.
    var corrected = false
    var settle: Task<Void, Never>?
}
