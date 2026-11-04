import SwiftUI

/// A subagent's whole conversation, over the chat, in the main transcript's
/// own list.
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
                ChatPageList(messages: messages, status: subagent.status)
                    .id(subagent.id)
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
            .paneKeyboardShortcut(.cancelAction)
            .help("Close")
            .plumeID(AccessibilityID.subagentTranscriptClose)
        }
        .padding(12)
    }
}
