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
                // Lazy so a long transcript only builds the rows on screen.
                // A plain VStack lays out every message on every pass, which
                // is thousands of markdown parses per frame on a real
                // conversation.
                LazyVStack(alignment: .leading, spacing: 0) {
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
                            .listItemPadding(bleed: true, column: .unpadded)
                    }
                    SubagentListView(subagents: subagents)
                        .listItemPadding(bleed: true, column: .unpadded)
                    if let tabID {
                        PendingPermissionDock(tabID: tabID)
                            .listItemPadding(bleed: true, column: .unpadded)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .padding(.bottom, bottomPadding)
            }
            .onScrollGeometryChange(for: ChatScrollGeometry.self) { geometry in
                ChatScrollGeometry(
                    distanceFromBottom: max(0, geometry.contentSize.height - geometry.visibleRect.maxY),
                    contentHeight: geometry.contentSize.height
                )
            } action: { old, new in
                if ChatScrollAnchor.reflectsUserScroll(
                    previousContentHeight: old.contentHeight,
                    newContentHeight: new.contentHeight
                ) {
                    scrollPosition.distanceFromBottom = new.distanceFromBottom
                }
                // Off the recorded position, never off `new`: growth pushes
                // the bottom away from the viewport, so reading the live
                // distance would flash the button on every streamed chunk.
                let detached = ChatScrollAnchor.isDetached(
                    distanceFromBottom: scrollPosition.distanceFromBottom
                )
                if detached != isDetached { isDetached = detached }
                guard ChatScrollAnchor.shouldFollowGrowth(
                    previousDistanceFromBottom: scrollPosition.distanceFromBottom,
                    previousContentHeight: old.contentHeight,
                    newContentHeight: new.contentHeight
                ) else { return }
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
            .onChange(of: lastMessageID) { _, newID in
                guard newID != nil else { return }
                if ChatScrollAnchor.shouldAutoScroll(distanceFromBottom: scrollPosition.distanceFromBottom) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
            .overlay(alignment: .bottom) {
                if isDetached {
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
                }
            }
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
        .transition(.scale(scale: 0.8).combined(with: .opacity))
        .animation(.snappy(duration: 0.18), value: isDetached)
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
