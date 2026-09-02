import Foundation

/// A `type: "system"` transcript line worth showing, or an assistant line
/// Claude Code flagged as an API error.
///
/// Most system lines are bookkeeping — turn durations, mode changes, hook
/// summaries — and stay dropped. What survives is what a reader would
/// otherwise be confused by: a failed turn that looks identical to a silent
/// one, and history disappearing under compaction.
struct ChatNotice: Equatable {
    enum Kind: Equatable {
        case error
        case warning
        case info
        /// History was compacted away at this point.
        case compaction
    }

    let kind: Kind
    let title: String
    /// Longer text behind a disclosure. Nil when the title says everything.
    let detail: String?
}

extension ChatNotice {
    /// Builds a notice from a `system` entry, or nil for the bookkeeping
    /// subtypes that carry nothing a reader needs.
    static func decoding(_ entry: TranscriptEntry) -> ChatNotice? {
        guard entry.type == "system" else { return nil }
        switch entry.subtype {
        case "compact_boundary":
            return ChatNotice(
                kind: .compaction,
                title: "Conversation compacted",
                detail: entry.compactMetadata.map(compactionDetail)
            )
        case "api_error":
            return ChatNotice(
                kind: .error,
                title: "API error",
                detail: entry.errorDescription
            )
        case "informational", "local_command":
            guard let content = entry.systemContent?.nonEmpty else { return nil }
            return ChatNotice(kind: kind(forLevel: entry.level), title: content, detail: nil)
        default:
            // An unrecognized subtype still matters when it is flagged as an
            // error; anything quieter is bookkeeping.
            guard entry.level == "error", let content = entry.systemContent?.nonEmpty else { return nil }
            return ChatNotice(kind: .error, title: content, detail: nil)
        }
    }

    private static func kind(forLevel level: String?) -> Kind {
        switch level {
        case "error": return .error
        case "warning": return .warning
        default: return .info
        }
    }

    private static func compactionDetail(_ metadata: CompactMetadata) -> String {
        var parts: [String] = []
        if let trigger = metadata.trigger { parts.append("\(trigger) compaction") }
        if let pre = metadata.preTokens, let post = metadata.postTokens {
            parts.append("\(formatted(pre)) → \(formatted(post)) tokens")
        }
        return parts.joined(separator: " · ")
    }

    private static func formatted(_ tokens: Int) -> String {
        tokens >= 1000 ? "\(tokens / 1000)k" : "\(tokens)"
    }
}

/// The parts of a `compact_boundary`'s `compactMetadata` worth showing.
struct CompactMetadata: Decodable, Equatable {
    let trigger: String?
    let preTokens: Int?
    let postTokens: Int?
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
