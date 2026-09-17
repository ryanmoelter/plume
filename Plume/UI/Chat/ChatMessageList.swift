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

    /// Whether the user has scrolled away far enough to want a jump back.
    ///
    /// An observable box rather than `@State`, and read only by the button
    /// itself: read here, the flag would re-run this body on every flip, and
    /// nothing else here needs it.
    @State private var jumpButton = JumpButtonVisibility()

    @State private var settings = AppSettings.shared

    /// The list's items. Built in `onChange` rather than in `body`: markdown
    /// parsing must not run on the render path, and writing observable state
    /// during a body is what spins SwiftUI forever.
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

    /// The list's handle, and the message ids of the last rebuild so a
    /// prompt the user just sent can be told from a transcript loading.
    @State private var commands = ChatListCommands()
    @State private var previousMessageIDs: [String] = []
    @Environment(\.chatFontSize) private var chatFontSize
    @Environment(\.chatLinkDirectory) private var linkDirectory

    /// The viewport's own width, so the left balance can react to it. Read
    /// from the `HStack` rather than the list, since the list's width is
    /// already the thing being solved for.
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: leftBalance)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
    }

    /// Space to the left of the list that balances the minimap's column on
    /// the right. Solved against the minimap's collapsed rail width, not its
    /// revealed width: the reveal is an overlay that never changes layout, so
    /// balancing against it would make the text jump when the map opens.
    private var leftBalance: CGFloat {
        ChatContentBalance.leftInset(
            viewportWidth: viewportWidth,
            contentWidth: dimensions.contentWidth,
            minimapWidth: ChatMinimap.collapsedWidth
        )
    }

    private var list: some View {
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
                jumpButton.isDetached = false
                jumpToBottom(animated: true)
            }
        }
    }

    private func jumpToBottom(animated: Bool) {
        commands.scrollToBottom(animated: animated)
    }

    /// Puts the piece at the top of the viewport. The custom list resolves
    /// the target itself.
    private func jump(to id: String) {
        commands.jump(to: id)
    }

    private func rebuildPieces() {
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
/// `ChatMessageList`'s. Always mounted and shown by opacity: inserting it on
/// demand resized the scroll view, which reported new geometry, which
/// toggled it again.
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
