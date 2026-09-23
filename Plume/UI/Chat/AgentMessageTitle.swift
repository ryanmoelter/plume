import SwiftUI

/// Names the agent that sent the message in the bubble below it.
struct AgentMessageTitle: View, ThemedView {
    @Environment(\.theme) var theme

    let name: String?

    var body: some View {
        Label {
            Text("Message from ") + Text(name ?? "another agent").font(typography.caption.mono)
        } icon: {
            Image(systemName: "bubble.left.and.bubble.right")
                .imageScale(.small)
        }
        .font(typography.caption.font)
        .emphasis(.secondary)
        .listItemPadding(vertical: false)
    }
}

#Preview {
    VStack(alignment: .leading) {
        AgentMessageTitle(name: "plume-xyz")
        AgentMessageTitle(name: nil)
    }
    .padding()
}
