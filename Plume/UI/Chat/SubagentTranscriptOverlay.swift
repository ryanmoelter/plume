import SwiftUI

/// A subagent's whole conversation, over the chat, rendered by the same
/// `ChatPieceView` the main transcript uses.
///
/// A plain `VStack` rather than the main list's own container: a subagent
/// transcript is tens of rows, not thousands, so it needs none of that
/// list's realized-window machinery.
struct SubagentTranscriptOverlay: View, ThemedView {
    @Environment(\.theme) var theme

    let subagent: SubagentTranscript
    /// Tinted by the host so the panel reads as the chat holding a document,
    /// matching the plan overlay.
    var glass: Glass = .regular
    let onClose: () -> Void

    private var messages: [ChatMessage] {
        subagent.transcript.messages
    }

    /// Built in `onChange` rather than in `body`, for the reason the main
    /// list builds its own there: markdown parsing must not run on the render
    /// path.
    @State private var pieces: [ChatPiece] = []
    @State private var cache = ChatPieceCache()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if messages.isEmpty {
                Text("This subagent has not written anything yet.")
                    .font(typography.body.font)
                    .emphasis(.subtle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(pieces) { piece in
                            ChatPieceView(piece: piece)
                                .listItemPadding(bleed: true, vertical: false)
                                .padding(.top, piece.paysInsetOutside ? piece.topInset : 0)
                                .padding(.bottom, piece.bottomInset)
                        }
                    }
                    .padding(.bottom, dimensions.verticalPadding)
                }
            }
        }
        .onChange(of: messages, initial: true) { rebuildPieces() }
        .onChange(of: subagent.status) { rebuildPieces() }
        .glassEffect(glass, in: .rect(cornerRadius: 12))
        .listItemPadding(bleed: true)
        .padding(.vertical, 8)
    }

    private func rebuildPieces() {
        pieces = cache.pieces(
            for: messages,
            status: subagent.status,
            hiddenToolUseIDs: [],
            streaming: ChatStreamHandoff.Overlay(),
            dimensions: dimensions
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            StatusBadge(status: subagent.status)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(subagent.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subagent.id)
                    .font(typography.caption.mono)
                    .emphasis(.subtle)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .emphasis(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityIdentifier(AccessibilityID.subagentTranscriptClose)
        }
        .padding(12)
    }
}
