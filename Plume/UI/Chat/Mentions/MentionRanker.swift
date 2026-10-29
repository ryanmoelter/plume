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
/// Linear issues, then pull requests, then files, each capped and, when the
/// query spans more than one source, led by its filter row.
nonisolated enum MentionRanker {
    static let sourceOrder: [MentionCandidate.Source] = [.linear, .pullRequests, .files]
    static let perSourceLimit = 5
    static let fileLimit = 10
    /// A bare `@` lists the viewer's own issues and pull requests, with only
    /// a few files under them.
    static let bareFileLimit = 3
    static let totalLimit = 20
    /// A filter prefix leaves one source, which then gets the whole menu, so
    /// `@file:` can browse a directory.
    static let filteredLimit = 50

    static func limit(for source: MentionCandidate.Source, isBare: Bool, isFiltered: Bool = false) -> Int {
        if isFiltered { return filteredLimit }
        return switch source {
        case .files: isBare ? bareFileLimit : fileLimit
        case .linear, .pullRequests: perSourceLimit
        }
    }

    /// How many ranked matches each source should hand back for `query`.
    static func matchLimit(for query: MentionQuery) -> Int {
        query.filter == nil ? FileMentionMatcher.defaultLimit : filteredLimit
    }

    /// Each source's list must already be in its own best-first order.
    static func merge(
        _ results: [MentionCandidate.Source: [RankedMention]],
        isBare: Bool,
        isFiltered: Bool = false
    ) -> [MentionCandidate] {
        let merged = sourceOrder.flatMap { source in
            (results[source] ?? []).prefix(limit(for: source, isBare: isBare, isFiltered: isFiltered)).map(\.candidate)
        }
        return Array(merged.prefix(isFiltered ? filteredLimit : totalLimit))
    }

    /// `merged` with each source's rows led by the filter row that narrows
    /// the menu to that source. A source with no rows gets no header.
    static func sectioned(_ merged: [MentionCandidate]) -> [MentionCandidate] {
        sourceOrder.flatMap { source -> [MentionCandidate] in
            let rows = merged.filter { $0.source == source }
            return rows.isEmpty ? [] : [.filter(MentionQuery.Filter(source: source))] + rows
        }
    }

    /// Where the selection belongs after the list changes: on the same
    /// candidate if it is still there, otherwise the top result, so Return
    /// takes a result rather than a section header.
    static func selectionIndex(keeping selectedID: String?, in candidates: [MentionCandidate]) -> Int {
        if let selectedID, let index = candidates.firstIndex(where: { $0.id == selectedID }) { return index }
        return candidates.firstIndex { !$0.isSectionHeader } ?? 0
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
