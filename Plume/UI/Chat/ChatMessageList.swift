import SwiftUI

/// The scrolling list of chat messages.
///
/// Its own `View` struct rather than a method on `ChatTabView`, because
/// SwiftUI invalidates a body as a unit. `ChatTabView` also renders the
/// statusline, which reads the git, statusline and surface stores — all of
/// which change while a scroll is in flight. Built inline, every one of those
/// rebuilt this list. Here, only `messages` and `status` reach it, so nothing
/// else can.
struct ChatMessageList: View {
    let messages: [ChatMessage]
    let subagents: [SubagentTranscript]
    let status: TaskStatus
    let maxWidth: CGFloat
    let bottomPadding: CGFloat

    /// Scroll position, held in a reference box rather than `@State`.
    ///
    /// `onScrollGeometryChange` fires on every scroll frame, so writing this
    /// to `@State` invalidated the list once per frame while scrolling.
    /// Nothing renders from it — it is only read when a new message arrives,
    /// to decide whether to follow the bottom.
    @State private var scrollPosition = ScrollPosition()

    private let bottomAnchorID = "chat-bottom-anchor"

    var body: some View {
        let lastMessageID = messages.last?.id
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy so a long transcript only builds the rows on screen.
                // A plain VStack lays out every message on every pass, which
                // is thousands of markdown parses per frame on a real
                // conversation.
                LazyVStack(alignment: .leading, spacing: 16) {
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
                            status: isLast ? status : .unset
                        )
                        .id(message.id)
                    }
                    SubagentListView(subagents: subagents)
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
                .padding(16)
                .padding(.bottom, bottomPadding)
            }
            .onScrollGeometryChange(for: ChatScrollGeometry.self) { geometry in
                ChatScrollGeometry(
                    distanceFromBottom: max(0, geometry.contentSize.height - geometry.visibleRect.maxY),
                    contentHeight: geometry.contentSize.height
                )
            } action: { old, new in
                scrollPosition.distanceFromBottom = new.distanceFromBottom
                guard ChatScrollAnchor.shouldFollowGrowth(
                    previousDistanceFromBottom: old.distanceFromBottom,
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
        }
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
