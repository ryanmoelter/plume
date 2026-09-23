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
    /// `pieces` without those the reveal has yet to reach, which is what the
    /// list draws: a piece takes room only once its text starts appearing.
    @State private var shownPieces: [ChatPiece] = []
    @State private var cache = ChatPieceCache()

    /// The ids the last rebuild produced, so the next one can name what
    /// arrived. See `ChatListMotion`.
    @State private var previousPieceIDs: [String] = []

    /// A rebuild waiting out `streamRebuildInterval`. Deltas land dozens of
    /// times a second and each rebuild splits the whole transcript, while
    /// the reveal paces what is shown on its own, so batching them costs
    /// nothing visible.
    @State private var pendingStreamRebuild: Task<Void, Never>?
    private static let streamRebuildInterval: Duration = .milliseconds(100)

    /// The pieces that grow into place. Only replaced when a rebuild actually
    /// brings some, so a piece has time to mount and read it — an id left
    /// here after the row has measured itself does nothing.
    @State private var arrivals: Set<String> = []

    /// The replies still revealing after their turn ended, keyed to where
    /// each is headed. The working indicator stays until they get there.
    @State private var heldTurnTargets: [String: Double] = [:]

    private var session: HeadlessSession? {
        guard let tabID else { return nil }
        return HeadlessSessionManager.shared.existingSession(for: tabID)
    }

    /// Exact, when the headless session knows which calls are stalled.
    /// Empty on the TUI transport, where rows fall back to position.
    private var pendingToolUseIDs: Set<String> {
        Set(session?.pendingPermissions.compactMap(\.toolUseID) ?? [])
    }

    /// The message the stream is writing, merged into the transcript's.
    private var live: ChatStreamHandoff.LiveMessage {
        ChatStreamHandoff.LiveMessage(session: session)
    }

    /// Nil without a tab, which leaves every message drawn whole.
    private var revealModel: ChatRevealModel? {
        tabID.map(ChatRevealModel.shared(for:))
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
    /// The pane's width, which decides how much room the rail gives itself.
    @State private var viewportWidth: CGFloat = 0
    @Environment(\.chatFontSize) private var chatFontSize
    @Environment(\.chatLinkDirectory) private var linkDirectory

    /// The minimap overlays the list rather than taking a column beside it, so
    /// the list gets the whole viewport and centers its columns in the same
    /// span the composer centers in. Anything the minimap covers is the
    /// padding outside a bleed item's column, which it is narrow enough to sit
    /// within.
    var body: some View {
        list
            .overlay(alignment: .trailing) {
                if !outline.isEmpty {
                    ChatMinimap(
                        outline: outline,
                        visiblePieceIDs: visiblePieceIDs,
                        onSelect: { jump(to: $0) },
                        onSelectEnd: { jumpToBottom(animated: true) },
                        bottomInset: floatingPanelHeight,
                        // The rail cannot measure this itself — its own
                        // geometry is the rail's, not the pane's.
                        viewportWidth: viewportWidth
                    )
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
    }

    private var list: some View {
        ChatListView(
            inputs: ChatListInputs(
                pieces: shownPieces,
                tabID: tabID,
                subagents: subagents,
                animate: settings.animateChatMotion,
                trailingInset: bottomPadding + floatingPanelHeight,
                chatFontSize: chatFontSize,
                workStartedAt: tabID.flatMap { StatusEngine.shared.workStarted(forTab: $0) },
                linkDirectory: linkDirectory,
                arrivals: arrivals
            ),
            revealModel: revealModel,
            commands: commands,
            onOpenSubagent: onOpenSubagent,
            onVisiblePieceIDs: { visiblePieceIDs = $0 },
            onDetachedChange: { jumpButton.isDetached = $0 }
        )
        .onChange(of: messages, initial: true) { rebuildPieces() }
        .onChange(of: status) { rebuildPieces() }
        .onChange(of: pendingToolUseIDs) { rebuildPieces() }
        .background { LiveMessageObserver(tabID: tabID, onChange: scheduleStreamRebuild) }
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

    private func scheduleStreamRebuild() {
        guard pendingStreamRebuild == nil else { return }
        pendingStreamRebuild = Task { @MainActor in
            try? await Task.sleep(for: Self.streamRebuildInterval)
            pendingStreamRebuild = nil
            guard !Task.isCancelled else { return }
            rebuildPieces()
        }
    }

    private func rebuildPieces() {
        let merged = ChatStreamHandoff.merge(messages, live: live)
        let split = { (status: TaskStatus) in
            cache.pieces(for: merged, status: status, hiddenToolUseIDs: pendingToolUseIDs, dimensions: dimensions)
        }
        var rebuilt = split(status)
        // Before the pieces reach the list, so a new message's rows mount
        // with its reveal already in place.
        revealModel?.update(targets: ChatReveal.targets(of: merged, pieces: rebuilt))
        heldTurnTargets = status == .awaitingReply ? revealModel?.unsettledTargets ?? [:] : [:]
        if !heldTurnTargets.isEmpty { rebuilt = split(.working) }
        pieces = rebuilt
        showRevealedPieces()
        outline = ChatOutlineBuilder.outline(from: rebuilt)
        pinSentPrompt(in: rebuilt)
    }

    /// Hands the list every piece the reveal has reached, and asks the reveal
    /// to call back when it reaches the next one held back.
    private func showRevealedPieces() {
        var shown: [ChatPiece] = []
        var thresholds: [String: Double] = [:]
        for piece in pieces {
            if let revealModel, !revealModel.hasReached(piece) {
                let offset = Double(piece.revealOffset)
                thresholds[piece.messageID] = min(thresholds[piece.messageID] ?? offset, offset)
            } else {
                shown.append(piece)
            }
        }
        let ids = shown.map(\.id)
        let arrived = ChatListMotion.arrivals(previous: previousPieceIDs, current: ids)
        if !arrived.isEmpty { arrivals = arrived }
        previousPieceIDs = ids
        shownPieces = shown
        thresholds.merge(heldTurnTargets) { min($0, $1) }
        revealModel?.watch(thresholds) {
            if heldTurnTargets.isEmpty { showRevealedPieces() } else { rebuildPieces() }
        }
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

/// Watches the stream on the list's behalf, so a delta re-runs this empty
/// body rather than the list's.
private struct LiveMessageObserver: View {
    let tabID: UUID?
    let onChange: () -> Void

    var body: some View {
        let session = tabID.flatMap { HeadlessSessionManager.shared.existingSession(for: $0) }
        Color.clear
            .onChange(of: ChatStreamHandoff.LiveMessage(session: session)) { onChange() }
    }
}

private extension ChatStreamHandoff.LiveMessage {
    init(session: HeadlessSession?) {
        self.init(
            id: session?.streamingMessageID,
            thinking: session?.streamingThinking ?? "",
            text: session?.streamingText ?? ""
        )
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
