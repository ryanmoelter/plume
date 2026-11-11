import SwiftUI

/// The chat list for a page over the chat — a plan, a subagent's
/// transcript — drawn the way the main transcript is, with its selection.
///
/// It has no tab: no permission dock, no streaming reveal, and no reading
/// position kept once the page closes.
struct ChatPageList: View, ThemedView {
    @Environment(\.theme) var theme

    let messages: [ChatMessage]
    var status: TaskStatus = .awaitingReply
    var initialPosition: ChatReadingPosition = .bottom

    /// Built in `onChange` rather than in `body`: markdown parsing must not
    /// run on the render path.
    @State private var pieces: [ChatPiece] = []
    @State private var cache = ChatPieceCache()
    @State private var expandedAgentMessages: Set<String> = []
    @State private var previousPieceIDs: [String] = []
    @State private var arrivals: Set<String> = []
    @State private var commands = ChatListCommands()
    @State private var settings = AppSettings.shared
    /// The chip store replaces an owner's wants wholesale, so the page asks
    /// under its own owner rather than its tab's.
    @State private var chipOwner = UUID()

    @Environment(\.chatFontSize) private var chatFontSize
    @Environment(\.chatLinkDirectory) private var linkDirectory
    @Environment(\.paneFocus) private var paneFocus

    var body: some View {
        ChatListView(
            inputs: ChatListInputs(
                pieces: pieces,
                leadingInset: dimensions.verticalPadding,
                animate: settings.animateChatMotion,
                trailingInset: dimensions.verticalPadding,
                chatFontSize: chatFontSize,
                linkDirectory: linkDirectory,
                arrivals: arrivals
            ),
            revealModel: nil,
            paneFocus: paneFocus,
            commands: commands,
            initialPosition: initialPosition,
            onToggleAgentMessage: toggleAgentMessage
        )
        .onChange(of: messages, initial: true) { rebuildPieces() }
        .onChange(of: status) { rebuildPieces() }
        .onChange(of: dimensions.contentWidth) { rebuildPieces() }
        .onChange(of: referenceRevision) { rebuildPieces() }
        .onChange(of: linkDirectory) { rebuildPieces() }
        .onDisappear { ReferenceChipStore.shared.release(owner: chipOwner) }
    }

    private var referenceRevision: Int {
        ReferenceChipStore.shared.revision(for: chipOwner)
    }

    private func rebuildPieces() {
        let store = ReferenceChipStore.shared
        let revision = referenceRevision
        let rebuilt = cache.pieces(
            for: messages,
            status: status,
            hiddenToolUseIDs: [],
            expandedAgentMessages: expandedAgentMessages,
            dimensions: dimensions,
            referenceRevision: revision,
            linkBase: linkDirectory,
            referenceTitle: { store.title(for: $0) }
        )
        store.want(cache.referenceTargets, owner: chipOwner)
        let ids = rebuilt.map(\.id)
        let arrived = ChatListMotion.arrivals(previous: previousPieceIDs, current: ids)
        if !arrived.isEmpty { arrivals = arrived }
        previousPieceIDs = ids
        pieces = rebuilt
    }

    /// Holds the reader on the row that changes least, as the main list does.
    private func toggleAgentMessage(_ key: String) {
        if expandedAgentMessages.contains(key) {
            commands.hold(pieceID: ChatPieceSplitter.agentMessageToggleID(key), overridingFollow: false)
        } else if let tail = pieces.last(where: { $0.agentMessageKey == key && $0.collapsedTail != nil }) {
            commands.hold(pieceID: tail.id, overridingFollow: true)
        }
        expandedAgentMessages.formSymmetricDifference([key])
        rebuildPieces()
    }
}
