import Foundation

/// Ranks Linear issues against a mention query.
nonisolated enum LinearMentionMatcher {
    static let defaultLimit = 20

    static func matches(
        _ query: String,
        in issues: [MentionCandidate.LinearIssue],
        limit: Int = defaultLimit
    ) -> [RankedMention] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let words = needle.split(separator: " ").map(String.init)

        let scored: [(rule: Int, quality: MentionMatchQuality, issue: MentionCandidate.LinearIssue)] =
            issues.compactMap { issue in
                guard let (rule, quality) = match(issue, needle: needle, words: words) else { return nil }
                return (rule, quality, issue)
            }

        return scored
            .sorted { lhs, rhs in
                if lhs.rule != rhs.rule { return lhs.rule < rhs.rule }
                if lhs.issue.isOpen != rhs.issue.isOpen { return lhs.issue.isOpen }
                if lhs.issue.updatedAt != rhs.issue.updatedAt { return lhs.issue.updatedAt > rhs.issue.updatedAt }
                return lhs.issue.identifier < rhs.issue.identifier
            }
            .prefix(limit)
            .map { RankedMention(candidate: .linear($0.issue), quality: $0.quality) }
    }

    /// The rule that matched, lower is better, and its quality group.
    private static func match(
        _ issue: MentionCandidate.LinearIssue,
        needle: String,
        words: [String]
    ) -> (Int, MentionMatchQuality)? {
        if needle.isEmpty { return (5, .loose) }
        let identifier = issue.identifier.lowercased()
        let titleWords = self.titleWords(issue.title)

        if words.count == 1 {
            if identifier == needle { return (1, .exact) }
            if identifier.hasPrefix(needle) { return (2, .prefix) }
        } else if issue.teamKey.lowercased().hasPrefix(words[0]),
                  words.dropFirst().allSatisfy({ prefixesAny($0, titleWords) }) {
            return (3, .words)
        }
        if words.allSatisfy({ prefixesAny($0, titleWords) }) { return (4, .words) }
        if issue.title.lowercased().contains(needle) { return (5, .loose) }
        return nil
    }

    private static func titleWords(_ title: String) -> [String] {
        title.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    private static func prefixesAny(_ word: String, _ titleWords: [String]) -> Bool {
        titleWords.contains { $0.hasPrefix(word) }
    }
}

extension MentionCandidate.LinearIssue {
    /// `state` is the cache's entry for the issue's `stateID`, when it has one.
    nonisolated init(_ issue: LinearSyncCache.Issue, state: LinearWorkflowState?) {
        let state = state ?? issue.fallbackState
        self.init(
            identifier: issue.identifier,
            title: issue.title,
            url: issue.url,
            stateType: state.type,
            stateColor: state.color,
            updatedAt: issue.updatedAt
        )
    }
}
