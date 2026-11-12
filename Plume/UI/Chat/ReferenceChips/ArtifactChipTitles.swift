import Foundation

/// The titles a conversation's own Artifact calls gave its artifacts, for
/// their chips. Read straight from the messages, so a chip shows its title in
/// the same build that first shows the link.
nonisolated struct ArtifactChipTitles: Equatable {
    private var titles: [String: String] = [:]

    init(messages: [ChatMessage]) {
        for artifact in ConversationArtifact.artifacts(in: messages) {
            guard let title = artifact.title,
                  case .artifact(let id) = ReferenceTarget.classify(artifact.url, base: nil) else { continue }
            titles[id] = title
        }
    }

    /// The generic label for an artifact no call named, since every artifact
    /// link is a chip.
    func title(forArtifact id: String) -> String {
        titles[id] ?? ReferenceTarget.genericArtifactLabel
    }
}
