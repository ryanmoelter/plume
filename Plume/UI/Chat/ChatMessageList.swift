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
    /// How much of the list's bottom edge the floating composer panel covers,
    /// including the gap below it. The last message must be scrollable clear
    /// of the glass, and the jump-to-bottom button must sit above it.
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
                ForEach(messages) { message in
                    // Only the newest row reflects live status, so only
                    // it reads `status`. Passing it to every row made a
                    // status change invalidate the whole list.
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
                }
                if !attachesToLastMessage, !streaming.isEmpty {
                    StreamingBlocks(overlay: streaming)
                        // Matches the inset an assistant row pays around
                        // its body, so a reply doesn't shift as the
                        // transcript takes over from the stream.
                        .padding(.vertical, 4)
                        .listItemPadding(bleed: true, column: .unpadded)
                }
                if let tabID {
                    SubagentListView(subagents: subagents, tabID: tabID, onOpen: onOpenSubagent)
                        .listItemPadding(bleed: true, column: .unpadded)
                    PendingPermissionDock(tabID: tabID)
                        .listItemPadding(bleed: true, column: .unpadded)
                }
                Color.clear
                    .frame(height: bottomPadding + floatingPanelHeight)
            }
            .scrollTargetLayout()
        }
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
        .task(id: messages.count) {
            await ScrollExercise.run(messages: messages) { id in
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
