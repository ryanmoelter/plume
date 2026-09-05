import SwiftUI

/// The scrolling list of chat messages.
///
/// Its own `View` struct rather than a method on `ChatTabView`, because
/// SwiftUI invalidates a body as a unit. `ChatTabView` also renders the
/// statusline, which reads the git and surface stores plus the live headless
/// session — all of which change while a scroll is in flight. Built inline, every one of those
/// rebuilt this list. Here, only `messages` and `status` reach it, so nothing
/// else can.
struct ChatMessageList: View {
    let messages: [ChatMessage]
    let subagents: [SubagentTranscript]
    let status: TaskStatus
    let bottomPadding: CGFloat
    /// Set on the headless transport, so pending permissions can be docked
    /// after the last message. Nil leaves the list read-only.
    var tabID: UUID?

    /// Scroll position, held in a reference box rather than `@State`.
    ///
    /// `onScrollGeometryChange` fires on every scroll frame, so writing this
    /// to `@State` invalidated the list once per frame while scrolling.
    /// Nothing renders from it — it is only read when a new message arrives,
    /// to decide whether to follow the bottom.
    @State private var scrollPosition = ScrollPosition()

    private let bottomAnchorID = "chat-bottom-anchor"

    /// Whether the user has scrolled away far enough to want a jump back.
    /// Unlike `scrollPosition`, this does render, so it is `@State` — the
    /// `ChatScrollAnchor` threshold keeps it from flipping every frame.
    @State private var isDetached = false

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
        let lastMessageID = messages.last?.id
        let streaming = streaming
        // The overlay belongs on the trailing assistant message so the live
        // text continues its paragraph. A turn that has not produced one yet
        // gets a row of its own, after the user's message.
        let attachesToLastMessage = messages.last?.role == .assistant
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: a `LazyVStack` chooses which rows to realize
                // from the content height, and chat rows vary enough in
                // height that the choice changes the total, which changes the
                // choice. The two settle into an oscillation the layout can
                // never resolve, pinning a core with the window frozen.
                // Laziness is still worth having on a long transcript — it
                // needs row heights that don't depend on how many rows are
                // realized.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(messages) { message in
                        // Only the newest row reflects live status, so only
                        // it reads `status`. Passing it to every row made a
                        // status change invalidate the whole list, which
                        // rebuilds rows the lazy stack had already built.
                        let isLast = ChatScrollAnchor.isEligibleForLiveStatus(
                            messageID: message.id,
                            lastMessageID: lastMessageID
                        )
                        ChatMessageRow(
                            message: message,
                            isLast: isLast,
                            status: isLast ? status : .unset,
                            pendingToolUseIDs: isLast ? pendingToolUseIDs : [],
                            streaming: isLast && attachesToLastMessage ? streaming : .init()
                        )
                        .listItemPadding(bleed: true, column: .unpadded)
                        .id(message.id)
                    }
                    if !attachesToLastMessage, !streaming.isEmpty {
                        StreamingBlocks(overlay: streaming)
                            // Matches the inset an assistant row pays around
                            // its body, so a reply doesn't shift as the
                            // transcript takes over from the stream.
                            .padding(.vertical, 4)
                            .listItemPadding(bleed: true, column: .unpadded)
                    }
                    SubagentListView(subagents: subagents)
                        .listItemPadding(bleed: true, column: .unpadded)
                    if let tabID {
                        PendingPermissionDock(tabID: tabID)
                            .listItemPadding(bleed: true, column: .unpadded)
                    }
                    // Trailing padding sits above the anchor, so the anchor
                    // really is the last thing in the content. Applied to the
                    // VStack instead, it lands below the anchor, and every
                    // `scrollTo(anchor: .bottom)` comes to rest a padding's
                    // distance short of the bottom.
                    Color.clear
                        .frame(height: bottomPadding)
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
            }
            .onScrollGeometryChange(for: ChatScrollGeometry.self) { geometry in
                ChatScrollGeometry(
                    distanceFromBottom: max(0, geometry.contentSize.height - geometry.visibleRect.maxY),
                    contentHeight: geometry.contentSize.height,
                    viewportHeight: geometry.containerSize.height
                )
            } action: { old, new in
                // Every tab stays mounted, hidden by opacity, so an offscreen
                // list keeps reporting geometry. Its viewport measures zero,
                // which reads as a huge distance from the bottom and scrolls
                // to chase it — and that scroll reports again.
                guard new.viewportHeight > 0 else { return }
                if ChatScrollAnchor.reflectsUserScroll(
                    previousContentHeight: old.contentHeight,
                    newContentHeight: new.contentHeight
                ) {
                    scrollPosition.distanceFromBottom = new.distanceFromBottom
                }
                // Off the recorded position, never off `new`: growth pushes
                // the bottom away from the viewport, so reading the live
                // distance would flash the button on every streamed chunk.
                // Off the update pass: this action can run several times in a
                // single frame, and writing view state from inside one is what
                // SwiftUI reports as modifying state during a view update.
                let detached = ChatScrollAnchor.isDetached(
                    distanceFromBottom: scrollPosition.distanceFromBottom
                )
                guard detached != isDetached else { return }
                Task { @MainActor in
                    if detached != isDetached { isDetached = detached }
                }
            }
            // Following is driven by what arrives, never by geometry: a scroll
            // reports geometry of its own, and deciding to scroll from that
            // report is a loop with no fixed point.
            .onChange(of: lastMessageID) { _, newID in
                guard newID != nil else { return }
                followBottomIfPinned(proxy)
            }
            .onChange(of: streaming) { _, _ in
                followBottomIfPinned(proxy)
            }
            .onAppear {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
            #if DEBUG
            .task(id: messages.count) {
                await ScrollExercise.run(messages: messages, proxy: proxy)
            }
            #endif
            // Always mounted, shown by opacity. Inserting it on demand
            // resizes the scroll view, which reports new geometry, which
            // toggles it again.
            .overlay(alignment: .bottom) {
                scrollToBottomButton {
                    // The programmatic scroll reports as growth-free
                    // geometry, but only after the fact; resetting here
                    // hides the button at once and restores auto-follow.
                    scrollPosition.distanceFromBottom = 0
                    isDetached = false
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                }
                .opacity(isDetached ? 1 : 0)
                .allowsHitTesting(isDetached)
            }
        }
    }

    /// Scrolls to the newest content when the user is already at the bottom.
    private func followBottomIfPinned(_ proxy: ScrollViewProxy) {
        guard ChatScrollAnchor.shouldAutoScroll(
            distanceFromBottom: scrollPosition.distanceFromBottom
        ) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
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
        .padding(.bottom, 12)
        .help("Jump to the newest message")
    }
}

/// Mutable scroll state that must not invalidate a view when it changes.
///
/// A class, so writing to it from a per-frame scroll callback is not a
/// SwiftUI state change.
@MainActor
private final class ScrollPosition {
    var distanceFromBottom: CGFloat = 0
}
