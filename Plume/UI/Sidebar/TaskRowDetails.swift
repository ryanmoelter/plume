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
        /// One agent tab of a task that has several, heading its own lines.
        case agentHeader(AgentHeader)
        /// The group header: which project this directory belongs to.
        case project(String)
        /// A branch, marked when its checkout is a linked worktree, and with
        /// the chip drawn beside it for the states that take no row of their
        /// own — `.localOnly` has nowhere else to appear.
        case branch(String, isWorktree: Bool = false, accompaniedBy: PullRequestFetchState? = nil)
        /// Carries its directory so the chip can ask the store for that
        /// repository's ignored checks, not the task's.
        case pullRequest(directory: String?, state: PullRequestFetchState)
        /// A working Linear issue; a nil state means no fetch has been requested yet.
        case linearIssue(identifier: String, state: LinearIssueFetchState?)
        /// How many working issues the cap left out.
        case linearOverflow(Int)
        /// A pull request pinned to the task; a nil detail means GitHub has
        /// not answered yet.
        case pinnedPullRequest(PullRequestReference, detail: LinkedPullRequestStore.Detail?)
        /// How many pinned pull requests the cap left out.
        case pinnedPullRequestOverflow(Int)
    }

    /// One open directory of a task: where it is, what it is on, and its pull
    /// request. A task with one agent tab shows one per distinct directory;
    /// with several, each agent's `AgentGroup` carries one.
    struct DirectoryGroup: Equatable {
        var directory: String?
        var branch: String?
        var pullRequest: PullRequestFetchState?
        /// Nil until the lookup lands, which is why the header falls back to
        /// the directory's own name rather than waiting.
        var checkout: CheckoutFacts?

        init(
            directory: String?,
            branch: String? = nil,
            pullRequest: PullRequestFetchState? = nil,
            checkout: CheckoutFacts? = nil
        ) {
            self.directory = directory
            self.branch = branch
            self.pullRequest = pullRequest
            self.checkout = checkout
        }
    }

    struct AgentHeader: Equatable {
        var tabID: UUID
        var title: String
        /// The title, numbered when another agent of the task shares it, so a
        /// driver can tell the headers apart.
        var label: String
        var status: TaskStatus
        var isUnread: Bool
        /// How far the agent nests under the one that started it.
        var depth: Int
        var isRemotelyControlled: Bool
        /// The devices the tab holds, as `DeviceLeaseStore.summary` words them.
        var heldDevices: String?

        init(
            tabID: UUID,
            title: String,
            label: String? = nil,
            status: TaskStatus,
            isUnread: Bool = false,
            depth: Int = 0,
            isRemotelyControlled: Bool = false,
            heldDevices: String? = nil
        ) {
            self.tabID = tabID
            self.title = title
            self.label = label ?? title
            self.status = status
            self.isUnread = isUnread
            self.depth = depth
            self.isRemotelyControlled = isRemotelyControlled
            self.heldDevices = heldDevices
        }

        var statusText: String {
            ([status.label] + (isUnread ? ["unread"] : [])).joined(separator: ", ")
        }
    }

    /// A title that appears once stays bare; one that repeats is numbered on
    /// every copy, "Chat #1", "Chat #2". Numbering only the later copies would
    /// leave "Chat" matching all of them, since the control server matches a
    /// label as a substring.
    static func distinctLabels(_ titles: [String]) -> [String] {
        let totals = titles.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return titles.map { title in
            guard totals[title, default: 0] > 1 else { return title }
            let count = seen[title, default: 0] + 1
            seen[title] = count
            return "\(title) #\(count)"
        }
    }

    /// One agent tab of a task, with the directory it is open in.
    struct AgentGroup: Equatable {
        var header: AgentHeader
        var workspace: DirectoryGroup
    }

    /// The agent's status is the trailing badge's job, so it takes no line of
    /// its own.
    static func lines(groups: [DirectoryGroup]) -> [Line] {
        groups.flatMap(lines(for:))
    }

    /// A header per agent, followed by only what its directory says that the
    /// agent above did not, so agents sharing a folder stack without
    /// repeating it. An agent in another folder always shows at least its
    /// branch: a second clone on the same branch reads the same as the first,
    /// and showing only its pull request, or nothing, would make it look like
    /// it shared the first one's folder.
    static func lines(agents: [AgentGroup]) -> [Line] {
        var lines: [Line] = []
        var previous: (directory: String?, lines: [Line])?
        for agent in agents {
            let current = self.lines(for: agent.workspace)
            lines.append(.agentHeader(agent.header))
            if let previous {
                let differing = linesDiffering(current, from: previous.lines)
                let isOtherFolder = agent.workspace.directory != previous.directory
                lines.append(contentsOf: isOtherFolder && !startsAtFolderLine(differing) ? current : differing)
            } else {
                lines.append(contentsOf: current)
            }
            previous = (agent.workspace.directory, current)
        }
        return lines
    }

    private static func startsAtFolderLine(_ lines: [Line]) -> Bool {
        switch lines.first {
        case .project, .branch: true
        default: false
        }
    }

    /// `current` from its first line that reads differently from the same
    /// position in `previous`. The lines nest — a branch belongs to its
    /// project — so once one differs, everything under it is shown too.
    static func linesDiffering(_ current: [Line], from previous: [Line]) -> [Line] {
        let firstDifference = current.indices.first { $0 >= previous.count || !readsTheSame(current[$0], previous[$0]) }
        guard let firstDifference else { return [] }
        return Array(current[firstDifference...])
    }

    /// A pull request line carries its directory only so the chip can look up
    /// that repository's ignored checks; two folders showing one pull request
    /// read the same.
    private static func readsTheSame(_ line: Line, _ other: Line) -> Bool {
        if case .pullRequest(_, let state) = line, case .pullRequest(_, let otherState) = other {
            return state == otherState
        }
        return line == other
    }

    /// Project first: it is the header the branch and pull request under it
    /// belong to, and it is labelled even when the task has only one.
    static func lines(for group: DirectoryGroup) -> [Line] {
        var lines: [Line] = []
        if let header = projectName(for: group) { lines.append(.project(header)) }
        if let branch = group.branch, !branch.isEmpty {
            lines.append(.branch(
                branch,
                isWorktree: group.checkout?.isWorktree ?? false,
                accompaniedBy: group.pullRequest.flatMap(branchCompanion)
            ))
        }
        if let pullRequest = group.pullRequest, showsPullRequestLine(pullRequest) {
            lines.append(.pullRequest(directory: group.directory, state: pullRequest))
        }
        return lines
    }

    static let pinnedLineCap = 2

    /// One line per item up to `cap`, then a count of the rest.
    static func cappedLines<Item>(
        _ items: [Item],
        cap: Int = pinnedLineCap,
        line: (Item) -> Line,
        overflow: (Int) -> Line
    ) -> [Line] {
        var lines = items.prefix(cap).map(line)
        if items.count > cap { lines.append(overflow(items.count - cap)) }
        return lines
    }

    /// Mentioned issues never take a line.
    static func linearLines(
        _ issues: [LinkedLinearIssue],
        states: (String) -> LinearIssueFetchState?,
        cap: Int = pinnedLineCap
    ) -> [Line] {
        cappedLines(
            issues.filter { $0.role == .working },
            cap: cap,
            line: { .linearIssue(identifier: $0.identifier, state: states($0.identifier)) },
            overflow: Line.linearOverflow
        )
    }

    /// Leaves out a pull request a directory group already shows as its
    /// branch's. Until every group's pull request has loaded, that is not
    /// known, so no pinned line shows rather than one that may vanish.
    static func pinnedPullRequestLines(
        _ pinned: [PullRequestReference],
        groups: [DirectoryGroup],
        details: (PullRequestReference) -> LinkedPullRequestStore.Detail?,
        cap: Int = pinnedLineCap
    ) -> [Line] {
        // An agent with no folder has no pull request to wait for.
        let groups = groups.filter { !($0.directory ?? "").isEmpty }
        guard !pinned.isEmpty,
              !groups.contains(where: { $0.pullRequest == nil || $0.pullRequest == .loading })
        else { return [] }
        let branchPullRequests = Set(groups.compactMap { group -> PullRequestReference? in
            guard case .pullRequest(let pullRequest) = group.pullRequest, let url = pullRequest.url else { return nil }
            return ConversationReferenceScanner.references(in: url).pullRequests.first
        })
        return cappedLines(
            pinned.filter { !branchPullRequests.contains($0) },
            cap: cap,
            line: { .pinnedPullRequest($0, detail: details($0)) },
            overflow: Line.pinnedPullRequestOverflow
        )
    }

    /// The word standing in for an issue's state when there is none to show.
    /// Offline must never read as "no such issue", so each failure has its own.
    static func linearStatusWord(_ state: LinearIssueFetchState?) -> String? {
        switch state {
        case .issue, .stale, nil: nil
        case .loading: "loading"
        case .notFound: "not found"
        case .noWorkspace: "no workspace"
        case .failed: "offline"
        case .unauthorized: "key rejected"
        case .rateLimited: "rate limited"
        }
    }

    /// Each agent tab's folder, in tab order, nil where none resolves. When
    /// no agent tab has a folder, every one takes `taskDirectory`, which may
    /// come from any tab. When some do, a folderless one takes only
    /// `savedAgentDirectory`, a folder an agent tab saved: a terminal's folder
    /// follows `cd`, which must not move an agent's lines.
    static func agentTabDirectories(
        _ directories: [String?],
        savedAgentDirectory: String?,
        taskDirectory: String?
    ) -> [String?] {
        let anyHasFolder = directories.contains { nonEmpty($0) != nil }
        let fallback = anyHasFolder ? savedAgentDirectory : taskDirectory
        return directories.map { nonEmpty($0) ?? nonEmpty(fallback) }
    }

    /// The distinct directories a task shows a group for, in the order its
    /// agent tabs report them. Two tabs in one folder are one group; a task
    /// whose agent tabs have no folder falls back to `fallbackDirectory`.
    static func distinctDirectories(
        agentTabDirectories: [String?],
        fallbackDirectory: String?
    ) -> [String] {
        var seen: Set<String> = []
        var directories: [String] = []
        for directory in agentTabDirectories.compactMap(nonEmpty) where seen.insert(directory).inserted {
            directories.append(directory)
        }
        if directories.isEmpty, let fallbackDirectory = nonEmpty(fallbackDirectory) {
            directories = [fallbackDirectory]
        }
        return directories
    }

    private static func nonEmpty(_ directory: String?) -> String? {
        guard let directory, !directory.isEmpty else { return nil }
        return directory
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

    /// The project every worktree of a repository shares, so two tasks in two
    /// worktrees read as the same project rather than as two unrelated
    /// folders. Falls back to the folder's own name until the lookup lands,
    /// and for a directory that is not a repository at all.
    static func projectName(for group: DirectoryGroup) -> String? {
        group.checkout?.projectName ?? directoryName(group.directory)
    }

    static func directoryName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// For each line, the label of the agent header it sits under. Only a
    /// directory's own lines have one; the rest belong to the task.
    static func owningAgentLabels(_ lines: [Line]) -> [String?] {
        var owner: String?
        return lines.map { line in
            switch line {
            case .agentHeader(let header):
                owner = header.label
                return nil
            case .project, .branch, .pullRequest:
                return owner
            default:
                return nil
            }
        }
    }

    /// The control-server label for a directory line: the text it shows.
    static func controlLabel(_ line: Line) -> String? {
        switch line {
        case .project(let name): name
        case .branch(let branch, _, _): branch
        case .pullRequest(_, let state): PullRequestChipContent.accessibilityText(for: state)
        default: nil
        }
    }

    /// The control-server value for a directory line: what tells two lines
    /// with the same text apart.
    static func controlValue(_ line: Line, owner: String?) -> String? {
        var parts = [owner.map { "agent: \($0)" }]
        switch line {
        case .branch(_, let isWorktree, let companion):
            parts.append(isWorktree ? "worktree" : nil)
            parts.append(companion.flatMap(PullRequestChipContent.accessibilityText(for:)))
        case .pullRequest(let directory, _):
            parts.append(directory.map { "directory: \($0)" })
        default:
            break
        }
        let value = parts.compactMap { $0 }.joined(separator: "; ")
        return value.isEmpty ? nil : value
    }

    static func accessibilityText(_ line: Line) -> String? {
        switch line {
        case .text(let text): text
        case .agentHeader(let header): "\(header.title), \(header.statusText)"
        case .project(let name): name
        case .branch(let branch, let isWorktree, let companion):
            [isWorktree ? "worktree" : nil, branch,
             companion.flatMap(PullRequestChipContent.accessibilityText(for:))]
                .compactMap { $0 }.joined(separator: " ")
        case .pullRequest(_, let state): PullRequestChipContent.accessibilityText(for: state)
        case .linearIssue(let identifier, let state):
            if let issue = state?.issue {
                "Linear \(identifier), \(issue.stateName), \(issue.title)"
            } else if let word = linearStatusWord(state) {
                "Linear \(identifier), \(word)"
            } else {
                "Linear \(identifier)"
            }
        case .linearOverflow(let count): "\(count) more Linear issues"
        case .pinnedPullRequest(let reference, let detail):
            if case .pullRequest(let pull) = detail {
                "Pull request \(reference.number), \(pull.title)"
            } else {
                "Pull request \(reference.number)"
            }
        case .pinnedPullRequestOverflow(let count): "\(count) more pull requests"
        }
    }
}
