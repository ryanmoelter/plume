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

    static func lines(status: TaskStatus, groups: [DirectoryGroup]) -> [Line] {
        var lines: [Line] = []
        if let status = statusText(status) { lines.append(.text(status)) }
        for group in groups { lines.append(contentsOf: self.lines(for: group)) }
        return lines
    }

    /// Directory first: it is the header the branch and pull request under it
    /// belong to, and it is labelled even when the task has only one.
    static func lines(for group: DirectoryGroup) -> [Line] {
        var lines: [Line] = []
        if let directory = directoryName(group.directory) { lines.append(.text(directory)) }
        if let branch = group.branch, !branch.isEmpty { lines.append(.text(branch)) }
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

    /// `.unset` means no agent has ever run, which is not worth a line.
    static func statusText(_ status: TaskStatus) -> String? {
        switch status {
        case .unset: nil
        case .needsInput: "needs input"
        default: status.rawValue
        }
    }

    static func directoryName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }

    static func accessibilityText(_ line: Line) -> String? {
        switch line {
        case .text(let text): text
        case .pullRequest(_, let state): PullRequestChipContent.accessibilityText(for: state)
        }
    }
}
