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
        /// An agent tab's subagents and background tasks, inside its group.
        case activity(tabID: UUID)
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
        /// A child session outside its parent's run in the strip.
        var isDetachedChild: Bool
        /// The devices the tab holds, as `DeviceLeaseStore.summary` words them.
        var heldDevices: String?
        /// The label of the agent this one nests under, set by
        /// `lines(agents:taskLines:activity:)`. Nil for a top-level agent.
        var parentLabel: String?

        init(
            tabID: UUID,
            title: String,
            label: String? = nil,
            status: TaskStatus,
            isUnread: Bool = false,
            depth: Int = 0,
            isRemotelyControlled: Bool = false,
            isDetachedChild: Bool = false,
            heldDevices: String? = nil,
            parentLabel: String? = nil
        ) {
            self.tabID = tabID
            self.title = title
            self.label = label ?? title
            self.status = status
            self.isUnread = isUnread
            self.depth = depth
            self.isRemotelyControlled = isRemotelyControlled
            self.isDetachedChild = isDetachedChild
            self.heldDevices = heldDevices
            self.parentLabel = parentLabel
        }

        /// The agent has stopped for the user, or has a reply they have not read.
        var needsAttention: Bool {
            status.wantsAttention || isUnread
        }

        func drawsBold(boldsAttention: Bool) -> Bool {
            boldsAttention && needsAttention
        }

        var statusText: String {
            ([status.label] + (isUnread ? ["unread"] : [])).joined(separator: ", ")
        }

        /// The header's control-server value: its status, then whether its
        /// group holds the task's focused tab, is hovered and is pressed.
        func controlValue(isFocused: Bool, isHovered: Bool, isPressed: Bool = false) -> String {
            ([statusText]
                + (needsAttention ? ["attention"] : [])
                + (parentLabel.map { ["child of \($0)"] } ?? [])
                + (isDetachedChild ? ["detached child"] : [])
                + (isFocused ? ["focused"] : [])
                + (isHovered ? ["hovered"] : [])
                + (isPressed ? ["pressed"] : []))
                .joined(separator: "; ")
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

    /// One kind of line a directory contributes.
    enum Attribute: CaseIterable {
        case project, branch, pullRequest
    }

    static func attribute(of line: Line) -> Attribute? {
        switch line {
        case .project: .project
        case .branch: .branch
        case .pullRequest: .pullRequest
        default: nil
        }
    }

    /// `agents` come in `TaskStore.nestedByParent` order, each header's
    /// `depth` saying how far it nests.
    ///
    /// Every agent takes a header. With several top-level agents, a shared
    /// attribute, absence included, shows once at the task level, where a
    /// one-agent row shows it; the rest show under each agent's header. A
    /// sole top-level agent keeps all its lines under its own header, so its
    /// group sets it apart from its children. The project is shared when every top-level
    /// agent's reads the same. A branch or pull request is shared only when
    /// every one is also in the same folder: two clones on one branch are
    /// still two checkouts, and a shared branch above per-agent projects
    /// would sit outside its header. `taskLines` follow the shared lines,
    /// before the first header, except under a sole top-level agent: the task
    /// is that agent, so they follow its own lines inside its group.
    ///
    /// A child session shows only the lines that differ from its parent's,
    /// by `lines(of:differingFrom:)`. A tab in `activity` gets an
    /// `.activity` line after its header's own lines.
    static func lines(agents: [AgentGroup], taskLines: [Line] = [], activity: Set<UUID> = []) -> [Line] {
        let perAgent = agents.map { lines(for: $0.workspace) }
        let parents = parentIndices(depths: agents.map(\.header.depth))
        let topLevel = agents.indices.filter { parents[$0] == nil }
        let shared = topLevel.count > 1
            ? sharedAttributes(topLevel.map { (agents[$0].workspace, perAgent[$0]) }) : []
        func isShared(_ line: Line) -> Bool {
            attribute(of: line).map(shared.contains) ?? false
        }
        let parentTakesTaskLines = topLevel.count == 1 && agents.count > 1
        var lines = (topLevel.first.map { perAgent[$0] } ?? []).filter(isShared)
            + (parentTakesTaskLines ? [] : taskLines)
        for index in agents.indices {
            var header = agents[index].header
            let shown: [Line]
            if let parent = parents[index] {
                header.parentLabel = agents[parent].header.label
                shown = Self.lines(of: agents[index].workspace, differingFrom: agents[parent].workspace)
            } else {
                shown = perAgent[index].filter { !isShared($0) }
            }
            lines.append(.agentHeader(header))
            lines.append(contentsOf: shown)
            if parentTakesTaskLines, parents[index] == nil { lines.append(contentsOf: taskLines) }
            if activity.contains(header.tabID) { lines.append(.activity(tabID: header.tabID)) }
        }
        return lines
    }

    /// For each depth, the index of the nearest earlier one a level up.
    private static func parentIndices(depths: [Int]) -> [Int?] {
        var open: [(index: Int, depth: Int)] = []
        return depths.indices.map { index in
            open.removeAll { $0.depth >= depths[index] }
            let parent = open.last { $0.depth == depths[index] - 1 }?.index
            open.append((index, depths[index]))
            return parent
        }
    }

    private static func sharedAttributes(_ agents: [(workspace: DirectoryGroup, lines: [Line])]) -> Set<Attribute> {
        func readsTheSameEverywhere(_ attribute: Attribute) -> Bool {
            let values = agents.map { $0.lines.first { self.attribute(of: $0) == attribute } }
            return values.allSatisfy { $0 == values.first }
        }
        let sharesProject = readsTheSameEverywhere(.project)
        let sharesFolder = sharesProject && Set(agents.map(\.workspace.directory)).count <= 1
        return Set(Attribute.allCases.filter { attribute in
            switch attribute {
            case .project: sharesProject
            case .branch, .pullRequest: sharesFolder && readsTheSameEverywhere(attribute)
            }
        })
    }

    /// A child's lines, less the ones its parent already shows: the project
    /// when it reads the same, and the branch and pull request when they also
    /// sit in the same folder.
    static func lines(of child: DirectoryGroup, differingFrom parent: DirectoryGroup) -> [Line] {
        let parentLines = lines(for: parent)
        let sameFolder = child.directory == parent.directory
        return lines(for: child).filter { line in
            switch attribute(of: line) {
            case .project: !parentLines.contains(line)
            case .branch, .pullRequest: !(sameFolder && parentLines.contains(line))
            case nil: true
            }
        }
    }

    /// `lines` keeping the first `count` headers, plus the header of
    /// `keptTabID` and every header above it, so a kept child never loses
    /// its parent. A header's own lines travel with it.
    static func lines(
        _ lines: [Line],
        keepingHeaders count: Int,
        alsoKeeping keptTabID: UUID? = nil
    ) -> (lines: [Line], hiddenTabIDs: [UUID]) {
        let starts = lines.indices.filter { if case .agentHeader = lines[$0] { true } else { false } }
        guard let first = starts.first else { return (lines, []) }
        let headers = starts.map { index -> AgentHeader in
            guard case .agentHeader(let header) = lines[index] else { preconditionFailure() }
            return header
        }
        var kept = Set(headers.indices.prefix(count))
        if let keptIndex = headers.firstIndex(where: { $0.tabID == keptTabID }), !kept.contains(keptIndex) {
            kept.insert(keptIndex)
            var depth = headers[keptIndex].depth
            for index in headers.indices[..<keptIndex].reversed() where headers[index].depth < depth {
                kept.insert(index)
                depth = headers[index].depth
            }
        }
        var result = Array(lines[..<first])
        for (group, start) in starts.enumerated() where kept.contains(group) {
            let end = group + 1 < starts.count ? starts[group + 1] : lines.endIndex
            result.append(contentsOf: lines[start..<end])
        }
        return (result, headers.indices.filter { !kept.contains($0) }.map { headers[$0].tabID })
    }

    static func headerCount(_ lines: [Line]) -> Int {
        lines.count { if case .agentHeader = $0 { true } else { false } }
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

    /// For each line, the agent groups it sits in, outermost first, each named
    /// by its header's index. A child's group sits inside its parent's, so the
    /// parent's group runs on past its children. Lines above the first header
    /// sit in none.
    static func agentGroupNesting(_ lines: [Line]) -> [[Int]] {
        var open: [(index: Int, depth: Int)] = []
        return lines.indices.map { index in
            switch lines[index] {
            case .agentHeader(let header):
                open.removeAll { $0.depth >= header.depth }
                open.append((index, header.depth))
            case .project, .branch, .pullRequest, .activity,
                 .linearIssue, .linearOverflow, .pinnedPullRequest, .pinnedPullRequestOverflow:
                break
            default:
                open = []
            }
            return open.map(\.index)
        }
    }

    /// For each line, the agent tab a click on it selects: its innermost
    /// group's, since a child's lines sit inside its parent's group too.
    static func agentTabTargets(_ lines: [Line], nesting: [[Int]]) -> [UUID?] {
        nesting.map { groups in groups.last.flatMap { agentTabID(ofGroup: $0, in: lines) } }
    }

    /// The group headed by the task's focused tab, if an agent header shows it.
    static func focusedAgentGroup(_ lines: [Line], focusedTabID: UUID?) -> Int? {
        guard let focusedTabID else { return nil }
        return lines.indices.first { agentTabID(ofGroup: $0, in: lines) == focusedTabID }
    }

    /// The innermost group under the pointer. Moving between two lines can
    /// briefly hover both; the deeper group wins, then the later one.
    static func hoveredAgentGroup(hoveredLines: Set<Int>, nesting: [[Int]]) -> Int? {
        hoveredLines
            .compactMap { nesting.indices.contains($0) ? nesting[$0] : nil }
            .compactMap { groups in groups.last.map { (depth: groups.count, group: $0) } }
            .max { ($0.depth, $0.group) < ($1.depth, $1.group) }?
            .group
    }

    private static func agentTabID(ofGroup index: Int, in lines: [Line]) -> UUID? {
        guard lines.indices.contains(index), case .agentHeader(let header) = lines[index] else { return nil }
        return header.tabID
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
        // The row's label speaks for every tab's activity at once.
        case .activity: nil
        }
    }
}
