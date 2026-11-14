import SwiftUI

/// A plan's markdown, drawn in the chat's own list so it reads and selects
/// like a reply.
struct PlanDocumentView: View {
    let markdown: String?

    var body: some View {
        if let messages = PlanDocument.messages(for: markdown) {
            ChatPageList(messages: messages, initialPosition: .top)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("Nothing here yet")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

enum PlanDocument {
    /// One stable id, so a plan file changing on disk updates its pieces in
    /// place rather than replacing them.
    static let messageID = "plume.plan"

    /// The plan as one agent message, or nil when there is nothing to show.
    static func messages(for markdown: String?) -> [ChatMessage]? {
        guard let markdown, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return [ChatMessage(id: messageID, role: .assistant, blocks: [.markdown(markdown)], timestamp: nil)]
    }
}
