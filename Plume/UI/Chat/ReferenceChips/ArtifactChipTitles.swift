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

    func title(forArtifact id: String) -> String? {
        titles[id]
    }

    /// Every artifact link is a chip: the title a call gave it, else the
    /// author's label, else the link itself without its scheme.
    func title(forArtifact id: String, label: String?, destination: String) -> String {
        if let named = titles[id] { return named }
        if let label, !label.allSatisfy(\.isWhitespace) { return label }
        guard let schemeEnd = destination.range(of: "://") else { return destination }
        return String(destination[schemeEnd.upperBound...])
    }
}
