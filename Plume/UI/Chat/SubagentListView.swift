import SwiftUI

/// Subagent transcripts spawned from the main conversation, collapsed behind
/// one section so they don't compete with it for attention. Absent entirely
/// when there are none.
struct SubagentListView: View {
    @Environment(\.chatFontSize) private var chatFontSize

    let subagents: [SubagentTranscript]

    @State private var expanded = false

    var body: some View {
        if !subagents.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(subagents) { subagent in
                        SubagentRow(subagent: subagent)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("\(subagents.count) subagent\(subagents.count == 1 ? "" : "s")")
                    .font(.system(size: chatFontSize * 0.9))
                    .foregroundStyle(.secondary)
            }
            .listItemPadding(vertical: false)
        }
    }
}

private struct SubagentRow: View {
    @Environment(\.chatFontSize) private var chatFontSize

    let subagent: SubagentTranscript

    @State private var expanded = false

    private var lastMessageSummary: String {
        guard let last = subagent.transcript.messages.last else { return "No messages" }
        for block in last.blocks {
            if case .markdown(let text) = block, !text.isEmpty {
                return text
            }
        }
        return "…"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(subagent.transcript.messages) { message in
                    ChatMessageRow(message: message, isLast: false, status: .unset)
                }
            }
            .padding(.top, 6)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(subagent.id)
                    .font(.system(size: chatFontSize * 0.75, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(lastMessageSummary)
                    .font(.system(size: chatFontSize * 0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}
