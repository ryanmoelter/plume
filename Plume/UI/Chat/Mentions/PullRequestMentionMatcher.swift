import Foundation

/// Ranks pull requests against a mention query.
nonisolated enum PullRequestMentionMatcher {
    static let defaultLimit = 20

    static func matches(
        _ query: String,
        in pulls: [MentionCandidate.PullRequestEntry],
        limit: Int = defaultLimit
    ) -> [RankedMention] {
        var needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.hasPrefix("#") { needle.removeFirst() }
        let words = needle.split(separator: " ").map(String.init)

        let scored: [(rule: Int, pull: MentionCandidate.PullRequestEntry)] = pulls.compactMap { pull in
            guard let rule = match(pull, needle: needle, words: words) else { return nil }
            return (rule, pull)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.rule != rhs.rule { return lhs.rule < rhs.rule }
                let lhsOpen = lhs.pull.state == .open, rhsOpen = rhs.pull.state == .open
                if lhsOpen != rhsOpen { return lhsOpen }
                if lhs.pull.isDraft != rhs.pull.isDraft { return !lhs.pull.isDraft }
                let lhsDate = lhs.pull.updatedAt ?? .distantPast
                let rhsDate = rhs.pull.updatedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.pull.number > rhs.pull.number
            }
            .prefix(limit)
            .map { RankedMention(candidate: .pullRequest($0.pull), quality: quality(forRule: $0.rule)) }
    }

    private static func match(
        _ pull: MentionCandidate.PullRequestEntry,
        needle: String,
        words: [String]
    ) -> Int? {
        if needle.isEmpty { return 4 }
        let number = String(pull.number)
        if number == needle { return 1 }
        if number.hasPrefix(needle) { return 2 }
        let titleWords = pull.title.lowercased().split { !($0.isLetter || $0.isNumber) }
        if words.allSatisfy({ word in titleWords.contains { $0.hasPrefix(word) } }) { return 3 }
        if pull.title.lowercased().contains(needle) { return 4 }
        return nil
    }

    private static func quality(forRule rule: Int) -> MentionMatchQuality {
        switch rule {
        case 1: .exact
        case 2: .prefix
        case 3: .words
        default: .loose
        }
    }
}
