import Foundation

/// One row of `wt list`.
nonisolated struct WorktreeRow: Equatable, Sendable {
    var name: String
    /// The branch, or `<short sha> (detached)`.
    var branch: String
    /// Commits ahead of the base ref, as a string; empty on the base branch's
    /// own row, and when unanswerable.
    var ahead: String
    var dirty: Bool
    var remoteAhead: Int
    var remoteBehind: Int
    var hasUpstream: Bool

    init(name: String, branch: String, ahead: String, dirty: Bool, remoteAhead: Int, remoteBehind: Int, hasUpstream: Bool) {
        self.name = name
        self.branch = branch
        self.ahead = ahead
        self.dirty = dirty
        self.remoteAhead = remoteAhead
        self.remoteBehind = remoteBehind
        self.hasUpstream = hasUpstream
    }
}

/// The `wt list --json` payload, which the dotfiles Sublime plugin reads.
/// Every key is always present: absent values encode as `null`, never
/// omitted.
nonisolated struct WorktreeListPayload: Encodable, Equatable, Sendable {
    struct PR: Encodable, Equatable, Sendable {
        var number: Int
        var state: String
        var isDraft: Bool
        var url: String?
        var title: String?

        private enum CodingKeys: String, CodingKey {
            case number, state, url, title
            case isDraft = "is_draft"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(number, forKey: .number)
            try container.encode(state, forKey: .state)
            try container.encode(isDraft, forKey: .isDraft)
            try container.encodeOrNull(url, forKey: .url)
            try container.encodeOrNull(title, forKey: .title)
        }
    }

    struct Worktree: Encodable, Equatable, Sendable {
        var name: String
        var path: String?
        var branch: String
        var current: Bool
        var ahead: Int
        var dirty: Bool
        var remoteAhead: Int
        var remoteBehind: Int
        var hasUpstream: Bool
        var pr: PR?

        private enum CodingKeys: String, CodingKey {
            case name, path, branch, current, ahead, dirty, pr
            case remoteAhead = "remote_ahead"
            case remoteBehind = "remote_behind"
            case hasUpstream = "has_upstream"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encodeOrNull(path, forKey: .path)
            try container.encode(branch, forKey: .branch)
            try container.encode(current, forKey: .current)
            try container.encode(ahead, forKey: .ahead)
            try container.encode(dirty, forKey: .dirty)
            try container.encode(remoteAhead, forKey: .remoteAhead)
            try container.encode(remoteBehind, forKey: .remoteBehind)
            try container.encode(hasUpstream, forKey: .hasUpstream)
            try container.encodeOrNull(pr, forKey: .pr)
        }
    }

    var prState: PRState
    var worktrees: [Worktree]

    private enum CodingKeys: String, CodingKey {
        case worktrees
        case prState = "pr_state"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prState, forKey: .prState)
        try container.encode(worktrees, forKey: .worktrees)
    }

    /// One line of JSON, without a trailing newline.
    func jsonString() -> String {
        WT.jsonLine(self)
    }
}

private nonisolated final class StatusResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [WorktreeStatus?]
    private var nextIndex = 0

    init(count: Int) {
        results = Array(repeating: nil, count: count)
    }

    /// The next index no worker has taken, or nil once all are taken.
    func claimNext() -> Int? {
        lock.withLock {
            guard nextIndex < results.count else { return nil }
            defer { nextIndex += 1 }
            return nextIndex
        }
    }

    func set(_ index: Int, _ status: WorktreeStatus) {
        lock.withLock { results[index] = status }
    }

    /// Every slot, once the workers have filled them all.
    var all: [WorktreeStatus] {
        lock.withLock { results.map { $0! } }
    }
}

nonisolated extension KeyedEncodingContainer {
    /// `encodeIfPresent` drops the key; the `--json` readers expect `null`.
    mutating func encodeOrNull<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }
}

nonisolated extension WT {
    /// Worktree and branch names past this many columns are cut with an
    /// ellipsis, so one long name can't blow out the table.
    static let nameMax = 40
    /// The narrowest a terminal's width cuts the name and branch columns to.
    static let fittedColumnFloor = 8
    /// `--json` can wait longer than the table for PR status.
    static let jsonPRWait: TimeInterval = 3
    /// The table never waits on the forge, so the fetch gets a generous
    /// budget.
    static let listPRTotal: TimeInterval = 8
    /// How many worktrees `buildRows` scans at once. `git status` reads the
    /// whole tree, so a large repository with many worktrees is held to a
    /// few at a time.
    static let statusWorkers = 8

    /// The plain `↗<ahead> ↑<remote ahead> ↓<remote behind> +` cluster. Width
    /// math runs on this, never on the colored twin.
    static func statusCluster(ahead: String, dirty: Bool, remoteAhead: Int = 0, remoteBehind: Int = 0) -> String {
        var parts: [String] = []
        if !ahead.isEmpty, ahead != "0" { parts.append("\(TerminalUI.ahead)\(ahead)") }
        if remoteAhead != 0 { parts.append("\(TerminalUI.up)\(remoteAhead)") }
        if remoteBehind != 0 { parts.append("\(TerminalUI.down)\(remoteBehind)") }
        if dirty { parts.append("+") }
        return parts.joined(separator: " ")
    }

    /// `statusCluster` colored: `↗` dim, `↑` `↓` `+` green.
    static func colorizeCluster(_ plain: String, ui: TerminalUI) -> String {
        if plain.isEmpty { return "" }
        return plain.split(separator: " ").map { segment in
            let color = segment.hasPrefix(TerminalUI.ahead) ? ui.dim : ui.green
            return "\(color)\(segment)\(ui.reset)"
        }.joined(separator: " ")
    }

    /// `value` as one line of JSON, slashes unescaped. Keys are sorted:
    /// `JSONEncoder` keeps no insertion order, and sorting keeps the output
    /// stable from run to run.
    static func jsonLine(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A row per worktree, in list order. The base branch's own row drops its
    /// ahead count, which would only re-count what `↑` already shows.
    static func buildRows(_ ctx: any WTContext) -> [WorktreeRow] {
        // Paths come from the parallel list: a shared name is ambiguous to
        // `worktreePath` but still has one path per row.
        let paths = ctx.worktreePathsInListOrder()
        let statuses = StatusResults(count: paths.count)
        // Each status is a few git processes, so the scan mostly waits.
        // Plain threads rather than `concurrentPerform`, which runs serially
        // when the dispatch pool is busy.
        let finished = DispatchGroup()
        // `worktreeStatus` only runs git and reads settings fixed at init.
        nonisolated(unsafe) let ctx = ctx
        for _ in 0..<min(statusWorkers, paths.count) {
            finished.enter()
            Thread {
                while let index = statuses.claimNext() {
                    statuses.set(index, ctx.worktreeStatus(paths[index]))
                }
                finished.leave()
            }.start()
        }
        finished.wait()
        return zip(ctx.listWorktreeNames(), statuses.all).map { name, status in
            return WorktreeRow(
                name: name,
                branch: status.display,
                ahead: status.display == ctx.baseBranch ? "" : status.ahead,
                dirty: status.dirty,
                remoteAhead: status.remoteAhead,
                remoteBehind: status.remoteBehind,
                hasUpstream: status.hasUpstream
            )
        }
    }

    /// The row of the working directory's worktree in `buildRows` order.
    /// Matched by path, since two worktrees can share a folder name.
    static func currentRowIndex(_ ctx: any WTContext) -> Int? {
        guard let current = ctx.currentWorktree()?.path else { return nil }
        return ctx.worktreePathsInListOrder().firstIndex(of: current)
    }

    /// The `wt list` table, without a trailing newline.
    ///
    /// A branch without an upstream renders local-only in every state but
    /// `off`, and a trunk branch renders as having no PR. `dirs` appends the
    /// `--paths` column. `currentIndex` is the working directory's row, from
    /// `currentRowIndex`.
    static func renderList(
        _ rows: [WorktreeRow],
        currentIndex: Int?,
        prState: PRState,
        prs: PullRequestMap,
        numberPrefix: String,
        forgeIcon: String? = nil,
        trunkBranches: Set<String> = [],
        dirs: [String]? = nil,
        ui: TerminalUI = .plain
    ) -> String {
        renderListLines(
            rows, currentIndex: currentIndex, prState: prState, prs: prs, numberPrefix: numberPrefix,
            forgeIcon: forgeIcon, trunkBranches: trunkBranches, dirs: dirs, ui: ui
        ).map(\.text).joined(separator: "\n")
    }

    /// One chip per table line, with the columns the line occupies on screen.
    ///
    /// `columns`, the terminal's width, caps every line. The name and branch
    /// columns narrow to fit (`TerminalUI.fitColumns`, down to
    /// `fittedColumnFloor`), and a line still too wide is cut at its tail.
    /// The fit reserves only the PR column this frame prints, so the columns
    /// can shift when PR status arrives.
    static func renderListLines(
        _ rows: [WorktreeRow],
        currentIndex: Int?,
        prState: PRState,
        prs: PullRequestMap,
        numberPrefix: String,
        forgeIcon: String? = nil,
        trunkBranches: Set<String> = [],
        dirs: [String]? = nil,
        columns: Int? = nil,
        ui: TerminalUI = .plain
    ) -> [Chip] {
        let names = rows.map { TerminalUI.truncate($0.name, toWidth: nameMax) }
        let branches = rows.map { TerminalUI.truncate($0.branch, toWidth: nameMax) }
        let clusters = rows.map {
            statusCluster(ahead: $0.ahead, dirty: $0.dirty, remoteAhead: $0.remoteAhead, remoteBehind: $0.remoteBehind)
        }
        let prChips = rows.map { row -> Chip in
            if !row.hasUpstream, prState != .off {
                // A branch never pushed can't have a PR, whatever the fetch says.
                return ui.branchPRChip(nil, hasUpstream: false, forgeIcon: forgeIcon, numberPrefix: numberPrefix)
            }
            switch prState {
            case .on:
                let pr = trunkBranches.contains(row.branch) ? nil : prs[row.branch]
                return ui.branchPRChip(pr, hasUpstream: row.hasUpstream, forgeIcon: forgeIcon, numberPrefix: numberPrefix)
            case .loading: return ui.loadingChip(forgeIcon: forgeIcon)
            case .wait: return ui.netOffChip(forgeIcon: forgeIcon, failed: false)
            case .error: return ui.netOffChip(forgeIcon: forgeIcon, failed: true)
            case .off: return Chip(text: "", width: 0)
            }
        }

        /// "<branch>  <cluster>", or the bare branch with no cluster.
        func fieldWidth(_ branch: String, _ plain: String) -> Int {
            TerminalUI.displayWidth(branch) + (plain.isEmpty ? 0 : 2 + TerminalUI.displayWidth(plain))
        }

        var nameColumn = names.map(TerminalUI.displayWidth).max() ?? 0
        var branchColumn = branches.map(TerminalUI.displayWidth).max() ?? 0
        if let columns {
            let prColumn = prChips.map(\.width).max() ?? 0
            let fitted = TerminalUI.fitColumns([nameColumn, branchColumn], floor: fittedColumnFloor) { widths in
                let field = zip(branches, clusters).map { branch, plain in
                    min(TerminalUI.displayWidth(branch), widths[1]) + fieldWidth("", plain)
                }.max() ?? 0
                return 2 + widths[0] + 2 + field + 2 + prColumn <= columns
            }
            nameColumn = fitted[0]
            branchColumn = fitted[1]
        }
        let fittedNames = names.map { TerminalUI.truncate($0, toWidth: nameColumn) }
        let fittedBranches = branches.map { TerminalUI.truncate($0, toWidth: branchColumn) }
        let maxName = fittedNames.map(TerminalUI.displayWidth).max() ?? 0
        let maxBranchStatus = zip(fittedBranches, clusters).map(fieldWidth).max() ?? 0

        return rows.indices.map { index in
            let isCurrent = index == currentIndex
            let branchName = fittedBranches[index]
            let plain = clusters[index]
            let prChip = prChips[index]
            let branchStatus = plain.isEmpty ? branchName : "\(branchName)  \(colorizeCluster(plain, ui: ui))"
            // Padded by the plain width: the colored cluster's escapes take no columns.
            let pad = String(repeating: " ", count: maxBranchStatus - fieldWidth(branchName, plain))

            let nameWidth = TerminalUI.displayWidth(fittedNames[index])
            let paddedName = fittedNames[index] + String(repeating: " ", count: maxName - nameWidth)
            var line = "\(isCurrent ? "→" : " ") \(paddedName)  \(branchStatus)\(pad)  \(prChip.text)"
            var width = 2 + maxName + 2 + maxBranchStatus + 2 + prChip.width
            if let dirs {
                while line.last == " " { line.removeLast() }
                let dir = index < dirs.count ? dirs[index] : ""
                line += "  \(ui.dim)\(dir)\(ui.reset)"
                // Trimming leaves out the pad and the empty PR column.
                if prChip.width == 0 { width = 2 + maxName + 2 + fieldWidth(branchName, plain) }
                width += 2 + TerminalUI.displayWidth(dir)
            }
            if isCurrent, !ui.reset.isEmpty {
                // Each interior reset also clears bold, so bold is re-armed after it.
                line = ui.bold + line.replacingOccurrences(of: ui.reset, with: ui.reset + ui.bold) + ui.reset
            }
            if let columns, width > columns {
                line = TerminalUI.truncate(line, toWidth: columns)
                width = TerminalUI.visibleWidth(line)
            }
            return Chip(text: line, width: width)
        }
    }

    /// The `--json` twin of `renderList`. `paths` runs parallel to `rows`,
    /// since names are not unique.
    static func buildListJSON(
        _ rows: [WorktreeRow],
        currentIndex: Int?,
        prState: PRState,
        prs: PullRequestMap,
        paths: [String],
        trunkBranches: Set<String> = []
    ) -> WorktreeListPayload {
        let worktrees = rows.enumerated().map { index, row in
            let pr = prState == .on && !trunkBranches.contains(row.branch) ? prs[row.branch] : nil
            return WorktreeListPayload.Worktree(
                name: row.name,
                path: index < paths.count ? paths[index] : nil,
                branch: row.branch,
                current: index == currentIndex,
                ahead: Int(row.ahead) ?? 0,
                dirty: row.dirty,
                remoteAhead: row.remoteAhead,
                remoteBehind: row.remoteBehind,
                hasUpstream: row.hasUpstream,
                pr: pr.map { .init(number: $0.number, state: $0.state.rawValue, isDraft: $0.isDraft, url: $0.url, title: $0.title) }
            )
        }
        return WorktreeListPayload(prState: prState, worktrees: worktrees)
    }

    /// Prints the table, filling in the PR column when the fetch lands.
    ///
    /// `live` (stdout is a terminal) fits the table to `terminalSize`, paints
    /// a loading frame at once, and redraws it in place when the fetch
    /// resolves or its budget runs out. A frame too tall for the terminal
    /// can't be rewound, so the resolved one prints below it. Otherwise it
    /// waits the whole budget and prints one frame, never cut.
    static func printListLive(
        _ rows: [WorktreeRow],
        currentIndex: Int?,
        fetch: PRFetchSession?,
        trunkBranches: Set<String>,
        live: Bool,
        terminalSize: TerminalSize? = nil,
        dirs: [String]? = nil,
        ui: TerminalUI = .plain,
        console: any CLIConsole
    ) {
        func table(_ state: PRState, _ prs: PullRequestMap) -> [Chip] {
            renderListLines(
                rows, currentIndex: currentIndex, prState: state, prs: prs, numberPrefix: fetch?.numberPrefix ?? "#",
                forgeIcon: fetch?.forgeIcon, trunkBranches: trunkBranches, dirs: dirs,
                columns: live ? terminalSize?.columns : nil, ui: ui
            )
        }

        guard let fetch else {
            console.print(LiveRedraw.text(table(.off, [:])))
            return
        }
        guard live else {
            let resolved = collectPRs(fetch, timeout: listPRTotal)
            console.print(LiveRedraw.text(table(resolved.state, resolved.prs)))
            return
        }

        LiveRedraw.print(
            provisional: table(.loading, [:]), isTerminal: live, terminalSize: terminalSize, console: console
        ) {
            let resolved = collectPRs(fetch, timeout: listPRTotal)
            return table(resolved.state, resolved.prs)
        }
    }

    /// The fetch's column state once it lands, or `wait` past `timeout`.
    static func collectPRs(_ fetch: PRFetchSession, timeout: TimeInterval) -> (state: PRState, prs: PullRequestMap) {
        fetch.completion.wait(timeout: timeout) ? PRFetch.resolve(fetch.completion.result) : (.wait, [:])
    }
}
