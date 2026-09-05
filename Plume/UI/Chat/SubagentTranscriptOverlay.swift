import SwiftUI

/// A subagent's whole conversation, over the chat, rendered by the same
/// `ChatMessageRow` the main transcript uses.
///
/// A plain `VStack` rather than the main list's `LazyVStack`: a subagent
/// transcript is tens of rows, not thousands, and nothing scrolls it
/// programmatically — which is the pairing that hangs a lazy stack
/// (`docs/chat-list-hang.md`).
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
                        ForEach(messages) { message in
                            // Live status belongs to the last row only, the
                            // same rule the main list follows.
                            let isLast = message.id == messages.last?.id
                            ChatMessageRow(
                                message: message,
                                isLast: isLast,
                                status: isLast ? subagent.status : .unset
                            )
                            .listItemPadding(bleed: true, column: .unpadded)
                        }
                    }
                }
            }
        }
        .glassEffect(glass, in: .rect(cornerRadius: 12))
        .listItemPadding(bleed: true)
        .padding(.vertical, 8)
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
        }
        .padding(12)
    }
}
