import SwiftUI

/// The subagents a conversation has spawned, as a compact row each — what it
/// was asked to do, and how it is doing. Absent entirely when there are none.
///
/// Reading one is a separate act from scanning the list, so a row opens the
/// full transcript in an overlay rather than expanding in place; several
/// subagents running at once is the case this is for, and a nested disclosure
/// made the list unreadable at exactly that moment.
struct SubagentListView: View, ThemedView {
    @Environment(\.theme) var theme

    let subagents: [SubagentTranscript]
    /// Opens a subagent's transcript. The overlay is hosted by `ChatTabView`,
    /// which owns the space to draw it over.
    var onOpen: (SubagentTranscript) -> Void = { _ in }

    var body: some View {
        if !subagents.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(subagents.count) subagent\(subagents.count == 1 ? "" : "s")")
                    .font(typography.caption.font)
                    .emphasis(.subtle)
                    .padding(.bottom, 2)
                ForEach(subagents) { subagent in
                    SubagentRow(subagent: subagent) { onOpen(subagent) }
                }
            }
            .padding(.vertical, 6)
        }
    }
}

private struct SubagentRow: View, ThemedView {
    @Environment(\.theme) var theme

    let subagent: SubagentTranscript
    let onOpen: () -> Void

    @State private var isHovering = false

    private var messageCount: Int {
        subagent.transcript.messages.count
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                StatusBadge(status: subagent.status)
                    .frame(width: 12, alignment: .center)
                Text(subagent.title)
                    .font(typography.body.font)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text("\(messageCount)")
                    .font(typography.caption.mono)
                    .emphasis(.subtle)
                Image(systemName: "chevron.right")
                    .font(typography.caption.font)
                    .emphasis(.subtle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect(cornerRadius: 6))
            .background(
                isHovering ? colors.surfaceTint : Color.clear,
                in: .rect(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(subagent.descriptor?.description ?? subagent.id)
        .accessibilityIdentifier(AccessibilityID.subagentRow)
    }
}

#Preview {
    SubagentListView(subagents: [
        SubagentTranscript(
            id: "a1",
            transcript: Transcript(messages: [
                ChatMessage(id: "m1", role: .assistant, blocks: [.markdown("Looking")], timestamp: nil)
            ]),
            modifiedAt: nil,
            descriptor: SubagentDescriptor(description: "Explore the status engine", agentType: "Explore"),
            status: .working
        ),
        SubagentTranscript(
            id: "a2",
            transcript: Transcript(),
            modifiedAt: nil,
            descriptor: SubagentDescriptor(description: "Design the notification layer", agentType: "Plan"),
            status: .done
        ),
    ])
    .padding()
    .frame(width: 420)
}
