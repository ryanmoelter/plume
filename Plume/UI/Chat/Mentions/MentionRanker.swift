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

/// Merges each source's ranked matches into the one list the menu shows.
nonisolated enum MentionRanker {
    static let perSourceLimit = 5
    static let totalLimit = 12

    /// Each source's list must already be in its own best-first order.
    static func merge(
        _ results: [MentionCandidate.Source: [RankedMention]],
        query: String,
        teamKeys: Set<String>
    ) -> [MentionCandidate] {
        let order = sourceOrder(for: query, teamKeys: teamKeys)
        let capped = order.flatMap { source in
            (results[source] ?? []).prefix(perSourceLimit).map { (source, $0) }
        }
        let sorted = capped.enumerated().sorted { lhs, rhs in
            if lhs.element.1.quality != rhs.element.1.quality {
                return lhs.element.1.quality < rhs.element.1.quality
            }
            return lhs.offset < rhs.offset
        }
        return sorted.prefix(totalLimit).map(\.element.1.candidate)
    }

    static func sourceOrder(for query: String, teamKeys: Set<String>) -> [MentionCandidate.Source] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return [.pullRequests, .files, .linear]
        }
        let isPathLike = trimmed.contains("/") || trimmed.contains(".")
        if !isPathLike, looksLikeLinear(trimmed, teamKeys: teamKeys) {
            return [.linear, .files, .pullRequests]
        }
        return [.files, .linear, .pullRequests]
    }

    /// An identifier (`DROID-12`), an exact team key, or a multi-word query
    /// whose first word starts a team key (`dro layout`).
    private static func looksLikeLinear(_ query: String, teamKeys: Set<String>) -> Bool {
        let words = query.split(separator: " ")
        guard let first = words.first?.uppercased() else { return false }
        if LinearIdentifierShape.matches(first) { return true }
        if teamKeys.contains(first) { return true }
        return words.count > 1 && first.count >= 2 && teamKeys.contains { $0.hasPrefix(first) }
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
}
