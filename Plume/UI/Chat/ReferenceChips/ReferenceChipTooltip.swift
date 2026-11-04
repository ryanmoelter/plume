import Foundation

/// What a reference chip knows of its target beyond its title and icon.
nonisolated enum ReferenceChipDetail: Equatable, Sendable {
    case linear(LinearIssue)
    case pullRequest(PullRequestLinkSource.Entry)
}

/// The text a reference chip's tooltip shows: the full title, then the facts
/// the chip has no room for.
nonisolated enum ReferenceChipTooltip {
    static func text(for target: ReferenceTarget, detail: ReferenceChipDetail?, title: String?, directory: String?) -> String {
        switch (target, detail) {
        case (.linear, .linear(let issue)):
            return linear(issue)
        case (.linear(let identifier), _):
            return lines([title, identifier])
        case (.pullRequest(let owner, let repo, _), .pullRequest(let entry)):
            return pullRequest(entry, owner: owner, repo: repo)
        case (.pullRequest(let owner, let repo, let number), _):
            return lines([title, "\(owner)/\(repo) #\(number)"])
        case (.file(let path), _):
            return relativePath(path, to: directory)
        }
    }

    static func linear(_ issue: LinearIssue) -> String {
        let facts = [
            issue.identifier,
            issue.stateName,
            issue.assigneeName.flatMap { $0.isEmpty ? nil : $0 } ?? "Unassigned",
            issue.dueDate.flatMap(formattedDueDate).map { "Due \($0)" },
        ]
        return lines([issue.title, issue.summary, joined(facts)])
    }

    static func pullRequest(_ entry: PullRequestLinkSource.Entry, owner: String, repo: String) -> String {
        let facts = [
            "\(owner)/\(repo) #\(entry.number)",
            stateLabel(entry.state, isDraft: entry.isDraft),
            entry.author.map { "by \($0)" },
            reviewLabel(entry.reviewDecision, state: entry.state),
        ]
        return lines([entry.title, joined(facts)])
    }

    static func stateLabel(_ state: PullRequestState, isDraft: Bool) -> String {
        switch state {
        case .open: isDraft ? "Draft" : "Open"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }

    /// A merged or closed pull request's review no longer matters.
    static func reviewLabel(_ decision: ReviewDecision, state: PullRequestState) -> String? {
        guard state == .open else { return nil }
        switch decision {
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .none: return nil
        }
    }

    /// `path` relative to `directory` when it lies inside it, with `~` for
    /// the home folder otherwise.
    static func relativePath(_ path: String, to directory: String?, home: String = NSHomeDirectory()) -> String {
        let path = (path as NSString).standardizingPath
        if let directory {
            let base = (directory as NSString).standardizingPath
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
            if path == base { return "." }
        }
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        if path.hasPrefix(homePrefix) { return "~/" + path.dropFirst(homePrefix.count) }
        return path
    }

    /// Linear's due date is a calendar day with no time zone, so it is read
    /// and written in UTC to stay on that day.
    static func formattedDueDate(_ day: String) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return nil }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = TimeZone(identifier: "UTC")!
        return date.formatted(style)
    }

    private static func joined(_ facts: [String?]) -> String {
        facts.compactMap { $0 }.joined(separator: " · ")
    }

    private static func lines(_ lines: [String?]) -> String {
        lines.compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n")
    }
}
