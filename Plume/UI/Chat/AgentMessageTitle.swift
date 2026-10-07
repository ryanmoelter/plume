import SwiftUI

/// Names the agent that sent the message in the bubble below it.
struct AgentMessageTitle: View, ThemedView {
    @Environment(\.theme) var theme

    let name: String?
    /// A subagent is named by the description it was spawned with, which is
    /// prose; a peer session's name is an identifier.
    var isSubagent = false
    var isExpanded = false

    var body: some View {
        HStack(spacing: 4) {
            Label {
                Text("Message from ") + senderText
            } icon: {
                Image(systemName: isSubagent ? StatusSymbol.subagents.name : "bubble.left.and.bubble.right")
                    .imageScale(.small)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            if isExpanded {
                Image(systemName: "chevron.up")
                    .imageScale(.small)
                    .accessibilityLabel("Collapse")
            }
        }
        .font(typography.caption.font)
        .emphasis(.secondary)
        .listItemPadding(vertical: false)
    }

    private var senderText: Text {
        guard let name else { return Text(isSubagent ? "a subagent" : "another agent") }
        return isSubagent ? Text(name) : Text(name).font(typography.caption.mono)
    }
}

#Preview {
    VStack(alignment: .leading) {
        AgentMessageTitle(name: "plume-xyz")
        AgentMessageTitle(name: nil)
        AgentMessageTitle(name: "Explore: find the chat list", isSubagent: true, isExpanded: true)
    }
    .padding()
}
