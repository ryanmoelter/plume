import Foundation

/// A pull request as a row draws it, whether it is a branch's own or one
/// pinned to or named in the conversation.
nonisolated struct PullRequestSummary: Equatable, Sendable {
    let number: Int
    var title: String?
    var url: String?
    let state: PullRequestState
    let isDraft: Bool
    var reviewDecision: ReviewDecision = .none
    var hasReviewers = false
    var checkContexts: [CheckContext] = []
    /// Checks the repository ignores while pending.
    var ignoredChecks: Set<String> = []

    var checkRollup: CheckRollup {
        CheckRollup.folding(checkContexts, ignoredWhenPending: ignoredChecks)
    }

    init(
        number: Int,
        title: String? = nil,
        url: String? = nil,
        state: PullRequestState,
        isDraft: Bool,
        reviewDecision: ReviewDecision = .none,
        hasReviewers: Bool = false,
        checkContexts: [CheckContext] = [],
        ignoredChecks: Set<String> = []
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.hasReviewers = hasReviewers
        self.checkContexts = checkContexts
        self.ignoredChecks = ignoredChecks
    }

    init(_ pullRequest: PullRequest, ignoredChecks: Set<String> = []) {
        self.init(
            number: pullRequest.number,
            title: pullRequest.title,
            url: pullRequest.url,
            state: pullRequest.state,
            isDraft: pullRequest.isDraft,
            reviewDecision: pullRequest.reviewDecision,
            hasReviewers: pullRequest.hasReviewers,
            checkContexts: pullRequest.checkContexts,
            ignoredChecks: ignoredChecks
        )
    }

    init(_ entry: MentionCandidate.PullRequestEntry) {
        self.init(
            number: entry.number,
            title: entry.title.isEmpty ? nil : entry.title,
            url: entry.url,
            state: entry.state,
            isDraft: entry.isDraft,
            reviewDecision: entry.reviewDecision,
            hasReviewers: entry.hasReviewers,
            checkContexts: entry.checkContexts
        )
    }
}

/// What a pull request row draws: one status glyph before the title, the
/// rest of its glyphs after it, and a dim detail line.
nonisolated enum PullRequestRowContent {
    /// Draft, else checks, else review, else plain open. A merged or closed
    /// pull request shows only its own glyph.
    static func leading(_ pull: PullRequestSummary) -> PullRequestGlyph {
        if let finished = PullRequestChipContent.finishedGlyph(pull.state) { return finished }
        return openGlyphs(pull).first ?? PullRequestChipContent.open
    }

    /// The checks and review glyphs `leading` did not take.
    static func trailing(_ pull: PullRequestSummary) -> [PullRequestGlyph] {
        guard pull.state == .open else { return [] }
        return Array(openGlyphs(pull).dropFirst())
    }

    private static func openGlyphs(_ pull: PullRequestSummary) -> [PullRequestGlyph] {
        [
            pull.isDraft ? PullRequestChipContent.draft : nil,
            PullRequestChipContent.checkGlyph(pull.checkRollup),
            PullRequestChipContent.reviewGlyph(pull.reviewDecision, hasReviewers: pull.hasReviewers),
        ].compactMap { $0 }
    }

    /// The info pane's status glyph: checks have their own row there, so it
    /// takes draft, else review, else plain open. A draft reads dim there, as
    /// inactive.
    static func leadingWithoutChecks(_ pull: PullRequestSummary) -> PullRequestGlyph {
        if let finished = PullRequestChipContent.finishedGlyph(pull.state) { return finished }
        if pull.isDraft { return dimDraft }
        return PullRequestChipContent.reviewGlyph(pull.reviewDecision, hasReviewers: pull.hasReviewers)
            ?? PullRequestChipContent.open
    }

    private static let dimDraft = PullRequestGlyph(
        symbol: PullRequestChipContent.draft.symbol,
        tint: .neutral,
        label: PullRequestChipContent.draft.label,
        isDim: true
    )

    /// Nil for a finished pull request, whose review no longer matters, and
    /// for one nobody was asked to review.
    static func reviewStatus(_ pull: PullRequestSummary) -> String? {
        guard pull.state == .open else { return nil }
        return PullRequestChipContent.reviewGlyph(pull.reviewDecision, hasReviewers: pull.hasReviewers)?.label
    }

    /// `#123 · draft · awaiting review`.
    static func detail(_ pull: PullRequestSummary) -> String {
        ["#\(pull.number)", stateWord(pull), reviewStatus(pull)].compactMap { $0 }.joined(separator: " · ")
    }

    /// `PR #12 on GitHub, Make Sparkle the only updater. Draft, awaiting review`
    static func tooltip(_ pull: PullRequestSummary?, number: Int, forgeName: String) -> String {
        let head = "PR #\(number) on \(forgeName)"
        guard let pull else { return head }
        var text = head
        if let title = pull.title, !title.isEmpty { text += ", \(title)." } else { text += "." }
        let facts = [
            ReferenceChipTooltip.stateLabel(pull.state, isDraft: pull.isDraft),
            reviewStatus(pull),
        ].compactMap { $0 }
        return text + " " + facts.joined(separator: ", ")
    }

    static func stateWord(_ pull: PullRequestSummary) -> String {
        switch pull.state {
        case .merged: "merged"
        case .closed: "closed"
        case .open: pull.isDraft ? "draft" : "open"
        }
    }

    static func accessibilityText(_ pull: PullRequestSummary) -> String {
        ([leading(pull)] + trailing(pull)).map(\.label).joined(separator: " ")
    }
}

nonisolated struct CheckListEntry: Equatable, Sendable {
    let name: String
    let verdict: CheckVerdict
    /// Named in the repository's ignored checks, so its pending never holds
    /// up the rollup.
    let isIgnored: Bool
    var url: URL?
}

/// Every check on a pull request, for the list under its row.
nonisolated enum CheckListContent {
    /// Failing first, then pending, passed and skipped, each by name.
    static func entries(_ contexts: [CheckContext], ignored: Set<String>) -> [CheckListEntry] {
        contexts
            .map {
                CheckListEntry(name: $0.name, verdict: $0.verdict, isIgnored: ignored.contains($0.name), url: $0.url)
            }
            .sorted {
                $0.verdict != $1.verdict
                    ? $0.verdict < $1.verdict
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    /// `1 failing, 9 passed, 1 ignored`. A pending check the repository
    /// ignores counts as ignored, since it holds nothing up.
    static func summary(_ entries: [CheckListEntry]) -> String {
        func count(_ include: (CheckListEntry) -> Bool) -> Int { entries.filter(include).count }
        let ignoredPending: (CheckListEntry) -> Bool = { $0.verdict == .pending && $0.isIgnored }
        let parts: [(Int, String)] = [
            (count { $0.verdict == .failure }, "failing"),
            (count { $0.verdict == .pending && !$0.isIgnored }, "pending"),
            (count { $0.verdict == .success }, "passed"),
            (count { $0.verdict == .skipped }, "skipped"),
            (count(ignoredPending), "ignored"),
        ]
        return parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
    }

    static func glyph(for entry: CheckListEntry) -> PullRequestGlyph {
        switch entry.verdict {
        case .failure: PullRequestGlyph(symbol: "xmark.circle.fill", tint: .danger, label: "failing")
        case .pending:
            entry.isIgnored
                ? PullRequestGlyph(symbol: "circle.fill", tint: .neutral, label: "pending, ignored", isDim: true)
                : PullRequestGlyph(symbol: "circle.fill", tint: .attention, label: "pending")
        case .success: PullRequestGlyph(symbol: "checkmark.circle.fill", tint: .success, label: "passed")
        case .skipped: PullRequestGlyph(symbol: "minus.circle", tint: .neutral, label: "skipped", isDim: true)
        }
    }
}
