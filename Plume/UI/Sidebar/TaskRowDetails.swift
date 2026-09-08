import Foundation

/// The dim lines under a task's name in the sidebar.
///
/// Pure so the ordering and the omissions are testable without a view — and so
/// collapsing the row to a single joined line later is a different join of the
/// same array.
enum TaskRowDetails {
    /// One line, either words or the pull request chip's own drawing.
    enum Line: Equatable {
        case text(String)
        /// A branch, with the chip drawn beside it for the states that take no
        /// row of their own — `.localOnly` has nowhere else to appear.
        case branch(String, accompaniedBy: PullRequestFetchState?)
        /// Carries its directory so the chip can ask the store for that
        /// repository's ignored checks, not the task's.
        case pullRequest(directory: String?, state: PullRequestFetchState)
    }

    /// One open directory of a task: where it is, what it is on, and its pull
    /// request. A task shows one of these per distinct agent-tab directory.
    struct DirectoryGroup: Equatable {
        var directory: String?
        var branch: String?
        var pullRequest: PullRequestFetchState?

        init(directory: String?, branch: String? = nil, pullRequest: PullRequestFetchState? = nil) {
            self.directory = directory
            self.branch = branch
            self.pullRequest = pullRequest
        }
    }

    /// The agent's status is the trailing badge's job, so it takes no line of
    /// its own.
    static func lines(groups: [DirectoryGroup]) -> [Line] {
        groups.flatMap(lines(for:))
    }

    /// Directory first: it is the header the branch and pull request under it
    /// belong to, and it is labelled even when the task has only one.
    static func lines(for group: DirectoryGroup) -> [Line] {
        var lines: [Line] = []
        if let directory = directoryName(group.directory) { lines.append(.text(directory)) }
        if let branch = group.branch, !branch.isEmpty {
            lines.append(.branch(branch, accompaniedBy: group.pullRequest.flatMap(branchCompanion)))
        }
        if let pullRequest = group.pullRequest, showsPullRequestLine(pullRequest) {
            lines.append(.pullRequest(directory: group.directory, state: pullRequest))
        }
        return lines
    }

    /// The distinct directories a task shows a group for, in the order its
    /// agent tabs report them. Two tabs in one folder are one group; a task
    /// whose agent tabs have reported nothing falls back to its own folder.
    static func distinctDirectories(
        agentTabDirectories: [String?],
        taskDirectory: String?
    ) -> [String] {
        var seen: Set<String> = []
        var directories: [String] = []
        for directory in agentTabDirectories.compactMap({ $0 }) where !directory.isEmpty {
            if seen.insert(directory).inserted { directories.append(directory) }
        }
        if directories.isEmpty, let taskDirectory, !taskDirectory.isEmpty {
            directories = [taskDirectory]
        }
        return directories
    }

    /// Drawing nothing and taking no row are separate facts: these states keep
    /// their glyphs for the accessibility label, but a row holding one faint
    /// mark reads as dead space, so they take none. `.timedOut` and `.failed`
    /// stay — an offline Plume must not look like a repository with no pull
    /// requests.
    static func showsPullRequestLine(_ state: PullRequestFetchState) -> Bool {
        switch state {
        case .forgeUnsupported, .noPR, .localOnly, .loading: false
        default: !PullRequestChipContent.glyphs(for: state).isEmpty
        }
    }

    /// A branch with no upstream is a fact about the branch, so it rides on
    /// the branch line rather than vanishing with the pull request row. The
    /// other hidden states say nothing a branch name does not already.
    static func branchCompanion(_ state: PullRequestFetchState) -> PullRequestFetchState? {
        state == .localOnly ? state : nil
    }

    static func directoryName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }

    static func accessibilityText(_ line: Line) -> String? {
        switch line {
        case .text(let text): text
        case .branch(let branch, let companion):
            [branch, companion.flatMap(PullRequestChipContent.accessibilityText(for:))]
                .compactMap { $0 }.joined(separator: " ")
        case .pullRequest(_, let state): PullRequestChipContent.accessibilityText(for: state)
        }
    }
}
