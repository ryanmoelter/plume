import Foundation

/// How well a candidate matched, coarse enough to compare across sources.
nonisolated enum MentionMatchQuality: Int, Comparable, Sendable {
    case exact
    case prefix
    case words
    case loose

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated struct RankedMention: Hashable, Sendable {
    let candidate: MentionCandidate
    let quality: MentionMatchQuality
}

/// Merges each source's ranked matches into the one list the menu shows:
/// Linear issues, then pull requests, then files, each capped.
nonisolated enum MentionRanker {
    static let sourceOrder: [MentionCandidate.Source] = [.linear, .pullRequests, .files]
    static let perSourceLimit = 5
    static let fileLimit = 10
    /// A bare `@` lists the viewer's own issues and pull requests, with only
    /// a few files under them.
    static let bareFileLimit = 3
    static let totalLimit = 20

    static func limit(for source: MentionCandidate.Source, isBare: Bool) -> Int {
        switch source {
        case .files: isBare ? bareFileLimit : fileLimit
        case .linear, .pullRequests: perSourceLimit
        }
    }

    /// Each source's list must already be in its own best-first order.
    static func merge(_ results: [MentionCandidate.Source: [RankedMention]], isBare: Bool) -> [MentionCandidate] {
        let merged = sourceOrder.flatMap { source in
            (results[source] ?? []).prefix(limit(for: source, isBare: isBare)).map(\.candidate)
        }
        return Array(merged.prefix(totalLimit))
    }

    /// Where the selection belongs after the list changes: on the same
    /// candidate if it is still there, otherwise the top row.
    static func selectionIndex(keeping selectedID: String?, in candidates: [MentionCandidate]) -> Int {
        guard let selectedID else { return 0 }
        return candidates.firstIndex { $0.id == selectedID } ?? 0
    }
}

/// `TEAM-123`, or `TEAM-` on its way to one.
nonisolated enum LinearIdentifierShape {
    static func matches(_ word: String) -> Bool {
        let parts = word.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let key = parts.first, !key.isEmpty,
              key.first?.isLetter == true,
              key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return false }
        return parts[1].allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// `TEAM-123`, with its number.
    static func isComplete(_ word: String) -> Bool {
        matches(word) && word.last?.isNumber == true
    }
}
