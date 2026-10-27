import Foundation

/// The ahead/behind counts against origin, shared by both frames of a live
/// listing: they are local, so they can't change between them.
nonisolated final class AheadBehindCache {
    var values: [String: (ahead: Int, behind: Int)?] = [:]

    init() {}

    func lookup(_ branch: String, in git: any StackGit) -> (ahead: Int, behind: Int)? {
        if let cached = values[branch] { return cached }
        let value = git.originAheadBehind(branch)
        values[branch] = .some(value)
        return value
    }
}

/// Hands a forge to the fetch thread. The forge only runs a subprocess per
/// call and keeps no state the listing touches meanwhile.
private nonisolated final class ForgeHandle: @unchecked Sendable {
    let forge: any StackForge

    init(_ forge: any StackForge) {
        self.forge = forge
    }
}

nonisolated extension Stack {
    /// Graph glyphs.
    static let nodeGlyph = "●"
    static let currentNodeGlyph = "➜"
    static let spine = "│"
    /// Trunk commits elided between fork points.
    static let gap = "┆"
    static let merge = "├─╯"
    static let restackGlyph = "↻"

    /// Membership in a GitHub native stack.
    static func stackGlyph(_ ui: TerminalUI) -> String {
        ui.glyphSet == .nerd ? "\u{F51E}" : "≡"
    }

    /// Starts the PR fetch for `branches` on a background thread.
    static func startFetch(_ forge: any StackForge, _ branches: [String]) -> any PRFetchCompletion {
        let handle = ForgeHandle(forge)
        return PRFetch(branches: branches) { handle.forge.pullRequests(forBranches: $0) }
    }

    static func list(_ ctx: StackContext, _ arguments: [String]) throws {
        var showAll = false
        var json = false
        var noPR = false
        for argument in arguments {
            switch argument {
            case "--all": showAll = true
            case "--json": json = true
            case "--no-pr": noPR = true
            default: throw CLIFailure("unknown argument: \(argument)")
            }
        }
        let branches = try ctx.loadAndFlush()
        let current = ctx.git.currentBranch()
        if branches.isEmpty { throw CLIFailure("no stacks tracked yet — `stack create <name>` or `stack track`") }
        let roots: [String]
        if showAll {
            roots = StackGraph.roots(branches)
        } else {
            var root = current.flatMap { branches[$0] != nil ? StackGraph.root(branches, of: $0) : nil }
            let allRoots = StackGraph.roots(branches)
            if root == nil, allRoots.count == 1 { root = allRoots[0] }
            guard let root else { throw CLIFailure("current branch is not in a stack — try `stack list --all`") }
            roots = [root]
        }
        let members = roots.flatMap { StackGraph.subtree(branches, of: $0) }
        var fetch: (any PRFetchCompletion)?
        if !noPR, let forge = ctx.forge {
            if forge.isInstalled {
                fetch = startFetch(forge, members)
            } else {
                ctx.warn("\(forge.cliName) not installed — \(forge.noun) info unavailable (--no-pr to silence)")
            }
        }

        if json {
            // JSON needs the actual PR data, so it waits rather than degrade.
            let prs = fetch.flatMap { $0.wait(timeout: blockingPRBudget) ? $0.result : nil } ?? [:]
            try printJSON(ctx, branches, members: members, current: current, prs: prs)
            return
        }
        try printLive(
            ctx, branches, roots: roots, current: current, fetch: fetch,
            forgeIcon: ctx.ui.forgeIcon(for: ctx.forgeKind),
            numberPrefix: ctx.forge?.numberPrefix ?? "#",
            // Cursor addressing needs a terminal; NO_COLOR turns off color only.
            live: ctx.console.stdoutIsTerminal
        )
    }

    private static func printJSON(
        _ ctx: StackContext,
        _ branches: StackBranches,
        members: [String],
        current: String?,
        prs: PullRequestMap
    ) throws {
        var sub: StackBranches = [:]
        for name in members { sub[name] = branches[name] }
        let depths = StackGraph.depths(sub)
        let needsRestack = try ctx.cascadedNeedsRestack(sub)
        let rows: [StackJSON] = try members.map { name in
            let pr = prs[name]
            let prJSON: StackJSON = pr.map {
                .object([
                    StackJSONMember("number", .int($0.number)),
                    StackJSONMember("state", .string($0.state.rawValue)),
                    StackJSONMember("is_draft", .bool($0.isDraft)),
                    StackJSONMember("base", $0.baseRefName.map(StackJSON.string) ?? .null),
                    StackJSONMember("url", $0.url.map(StackJSON.string) ?? .null),
                ])
            } ?? .null
            let stackJSON: StackJSON = pr?.githubStack.map {
                .object([
                    StackJSONMember("number", .int($0.number)),
                    StackJSONMember("size", $0.size.map(StackJSON.int) ?? .null),
                    StackJSONMember("position", .int($0.position)),
                ])
            } ?? .null
            return .object([
                StackJSONMember("name", .string(name)),
                StackJSONMember("parent", .string(branches[name]?.parent ?? "")),
                StackJSONMember("depth", .int(depths[name] ?? 1)),
                StackJSONMember("current", .bool(name == current)),
                StackJSONMember("needs_restack", .bool(needsRestack[name] ?? false)),
                StackJSONMember("behind_trunk", .bool(try ctx.behindTrunk(sub, name))),
                StackJSONMember("pr", prJSON),
                StackJSONMember("github_stack", stackJSON),
            ])
        }
        let document = StackJSON.object([
            StackJSONMember("trunk", .string(ctx.trunk)),
            StackJSONMember("current", current.map(StackJSON.string) ?? .null),
            StackJSONMember("branches", .array(rows)),
        ])
        ctx.console.print(document.rendered())
    }

    /// Prints the graph, filling in the PR column as `fetch` lands. `live`
    /// paints at once and redraws in place; otherwise it waits and prints
    /// once, so a piped reader never sees a stale frame.
    static func printLive(
        _ ctx: StackContext,
        _ branches: StackBranches,
        roots: [String],
        current: String?,
        fetch: (any PRFetchCompletion)?,
        forgeIcon: String,
        numberPrefix: String,
        live: Bool
    ) throws {
        let cache = AheadBehindCache()
        func lines(_ state: PRState, _ prs: PullRequestMap) throws -> [Chip] {
            try renderLines(
                ctx, branches, roots: roots, current: current, prs: prs, prState: state,
                forgeIcon: forgeIcon, numberPrefix: numberPrefix, aheadBehind: cache
            )
        }
        func graph(_ state: PRState, _ prs: PullRequestMap) throws -> String {
            LiveRedraw.text(try lines(state, prs))
        }
        guard let fetch else {
            ctx.console.print(try graph(.off, [:]))
            return
        }
        func collect() -> (state: PRState, prs: PullRequestMap) {
            fetch.wait(timeout: listPRBudget) ? PRFetch.resolve(fetch.result) : (.wait, [:])
        }
        guard live else {
            let resolved = collect()
            ctx.console.print(try graph(resolved.state, resolved.prs))
            return
        }
        try LiveRedraw.print(
            provisional: try lines(.loading, [:]), isTerminal: true,
            terminalSize: ctx.console.terminalSize, console: ctx.console
        ) {
            let resolved = collect()
            return try lines(resolved.state, resolved.prs)
        }
    }

    /// The fetch's pull requests, or none when it failed or timed out, so a
    /// half-done submit reads "no PR here" rather than stopping.
    static func collectPRs(_ fetch: any PRFetchCompletion) -> PullRequestMap {
        fetch.wait(timeout: blockingPRBudget) ? fetch.result ?? [:] : [:]
    }

    /// The fetch's pull requests, failing when it failed or timed out: a
    /// command that pushes or creates must not read that as "no PR here".
    static func requirePRs(_ fetch: any PRFetchCompletion, _ forge: any StackForge) throws -> PullRequestMap {
        guard fetch.wait(timeout: blockingPRBudget), let prs = fetch.result else {
            throw CLIFailure("could not read \(forge.noun)s from \(forge.cliName) — nothing was pushed or created")
        }
        return prs
    }

    /// The git-log-style graph, without a trailing newline. The far-left
    /// column is the trunk; each root attaches at its fork point, nearest
    /// first. `prState` decides the PR column.
    static func render(
        _ ctx: StackContext,
        _ branches: StackBranches,
        roots: [String],
        current: String?,
        prs: PullRequestMap,
        prState: PRState,
        forgeIcon: String? = nil,
        numberPrefix: String = "#",
        aheadBehind: AheadBehindCache? = nil
    ) throws -> String {
        LiveRedraw.text(try renderLines(
            ctx, branches, roots: roots, current: current, prs: prs, prState: prState,
            forgeIcon: forgeIcon, numberPrefix: numberPrefix, aheadBehind: aheadBehind
        ))
    }

    /// `render`'s lines, each with its display width for counting screen rows.
    static func renderLines(
        _ ctx: StackContext,
        _ branches: StackBranches,
        roots: [String],
        current: String?,
        prs: PullRequestMap,
        prState: PRState,
        forgeIcon: String? = nil,
        numberPrefix: String = "#",
        aheadBehind: AheadBehindCache? = nil
    ) throws -> [Chip] {
        var renderer = GraphRenderer(
            ctx: ctx,
            current: current,
            prs: prs,
            prState: prState,
            forgeIcon: forgeIcon ?? ctx.ui.github,
            numberPrefix: numberPrefix,
            cache: aheadBehind ?? AheadBehindCache(),
            drift: prState == .on ? StackGraph.githubStackDrift(branches, prs) : [:]
        )
        return try renderer.render(branches, roots: roots)
    }
}

/// One line of the graph. A node row carries a name and chip that align
/// across rows; any other row carries a label.
private nonisolated struct GraphRow {
    var graph: String
    /// The node row's graph width up to and including its glyph.
    var graphWidth: Int?
    var name: String?
    var nameWidth = 0
    var chip: Chip?
    var label: String?
}

private nonisolated struct GraphRenderer {
    let ctx: StackContext
    let current: String?
    let prs: PullRequestMap
    let prState: PRState
    let forgeIcon: String
    let numberPrefix: String
    let cache: AheadBehindCache
    let drift: [String: String]
    var rows: [GraphRow] = []

    var ui: TerminalUI { ctx.ui }

    init(
        ctx: StackContext,
        current: String?,
        prs: PullRequestMap,
        prState: PRState,
        forgeIcon: String,
        numberPrefix: String,
        cache: AheadBehindCache,
        drift: [String: String]
    ) {
        self.ctx = ctx
        self.current = current
        self.prs = prs
        self.prState = prState
        self.forgeIcon = forgeIcon
        self.numberPrefix = numberPrefix
        self.cache = cache
        self.drift = drift
    }

    mutating func render(_ branches: StackBranches, roots: [String]) throws -> [Chip] {
        // Nearest fork first; the sort is stable, so a tie keeps the roots'
        // own order.
        let distances = try roots.map { try ctx.trunkDistance(branches[$0]?.base ?? "") }
        let ranked = zip(roots, distances).enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
            .map(\.element)
        let above = ranked.filter { $0.1 == 0 }.map(\.0)
        let below = ranked.filter { $0.1 > 0 }.map(\.0)

        for root in above { try emitRoot(branches, root) }
        rows.append(GraphRow(
            graph: Stack.nodeGlyph, graphWidth: 1,
            name: "\(ui.dim)\(ctx.trunk)\(ui.reset)", nameWidth: Self.width(ctx.trunk)
        ))
        var previousBase = try ctx.trunkTip()
        for root in below {
            let base = branches[root]?.base ?? ""
            let gap = try ctx.git.revListCount("\(base)..\(previousBase)")
            rows.append(GraphRow(graph: Stack.gap, label: "\(ui.dim)\(gap)\(ui.reset)"))
            try emitRoot(branches, root)
            previousBase = base
        }
        // With no root below the head, the head node is already the bottom.
        if !below.isEmpty { rows.append(GraphRow(graph: Stack.nodeGlyph)) }

        let nodes = rows.filter { $0.graphWidth != nil && $0.name != nil }
        let nameField = nodes.map { $0.graphWidth! + 1 + $0.nameWidth }.max() ?? 0
        let chipWidth = nodes.compactMap { $0.chip?.width }.max() ?? 0
        return rows.map { row in
            var line = row.graph
            if let name = row.name, let graphWidth = row.graphWidth {
                line += " " + name + String(repeating: " ", count: max(0, nameField - graphWidth - 1 - row.nameWidth))
                if let chip = row.chip {
                    line += "  " + chip.text + String(repeating: " ", count: max(0, chipWidth - chip.width))
                }
            } else if let label = row.label {
                line += label
            }
            line = Self.trimmingTrailingWhitespace(line)
            return Chip(text: line, width: TerminalUI.visibleWidth(line))
        }
    }

    private mutating func emitRoot(_ branches: StackBranches, _ root: String) throws {
        let sub = StackGraph.stack(branches, of: root)
        let needsRestack = try ctx.cascadedNeedsRestack(sub)
        try emitSubtree(sub, needsRestack, root, column: 1, live: [0])
        // The root's own commits merge into the trunk column.
        rows.append(GraphRow(graph: Stack.merge, label: try countLabel(sub, needsRestack, root)))
    }

    /// Rows for `branch`'s block, top to bottom: the child that continues
    /// the spine, then the siblings teed off into the next column, then
    /// `branch`'s own node. `live` holds the columns with an open spine to
    /// the left.
    private mutating func emitSubtree(
        _ sub: StackBranches,
        _ needsRestack: [String: Bool],
        _ branch: String,
        column: Int,
        live: Set<Int>
    ) throws {
        let kids = StackGraph.children(sub, of: branch)
        if let spineChild = kids.last {
            try emitSubtree(sub, needsRestack, spineChild, column: column, live: live)
            rows.append(GraphRow(graph: prefix(live, column, Stack.spine), label: try countLabel(sub, needsRestack, spineChild)))
        }
        for kid in kids.dropLast() {
            try emitSubtree(sub, needsRestack, kid, column: column + 1, live: live.union([column]))
            let cells = (0 ..< column).map { live.contains($0) ? "\(Stack.spine) " : "  " }.joined()
            rows.append(GraphRow(graph: cells + Stack.merge, label: try countLabel(sub, needsRestack, kid)))
        }
        let glyph = branch == current ? "\(ui.bold)\(ui.cyan)\(Stack.currentNodeGlyph)\(ui.reset)" : Stack.nodeGlyph
        rows.append(GraphRow(
            graph: prefix(live, column, glyph),
            graphWidth: 2 * column + 1,
            name: nameCell(branch),
            nameWidth: Self.width(branch),
            chip: chip(for: branch)
        ))
    }

    /// `│ ` in every open column left of `column`, then `glyph`.
    private func prefix(_ live: Set<Int>, _ column: Int, _ glyph: String) -> String {
        (0 ..< column).map { live.contains($0) ? "\(Stack.spine) " : "  " }.joined() + glyph
    }

    private func nameCell(_ branch: String) -> String {
        if branch == current { return "\(ui.bold)\(branch)\(ui.reset)" }
        let prefix = ctx.branchPrefix
        if !prefix.isEmpty, branch.hasPrefix(prefix) {
            return "\(ui.dim)\(prefix)\(ui.reset)\(branch.dropFirst(prefix.count))"
        }
        return branch
    }

    private func chip(for branch: String) -> Chip? {
        switch prState {
        case .off: return nil
        case .loading: return ui.loadingChip(forgeIcon: forgeIcon)
        case .wait: return ui.netOffChip(forgeIcon: forgeIcon, failed: false)
        case .error: return ui.netOffChip(forgeIcon: forgeIcon, failed: true)
        case .on:
            let pr = prs[branch]
            let chip = ui.branchPRChip(
                pr,
                hasUpstream: cache.lookup(branch, in: ctx.git) != nil,
                forgeIcon: forgeIcon,
                numberPrefix: numberPrefix
            )
            guard let membership = pr?.githubStack else { return chip }
            let tag = "\(Stack.stackGlyph(ui))\(membership.number)"
            return Chip(text: "\(chip.text) \(ui.dim)\(tag)\(ui.reset)", width: chip.width + 1 + Self.width(tag))
        }
    }

    private func countLabel(_ sub: StackBranches, _ needsRestack: [String: Bool], _ branch: String) throws -> String {
        let count = try ctx.commitsOverParent(sub, branch)
        var note = ""
        if needsRestack[branch] == true {
            note = "  \(ui.yellow)\(Stack.restackGlyph) needs restack\(ui.reset)"
        } else if try ctx.behindTrunk(sub, branch) {
            note = "  \(ui.dim)\(Stack.restackGlyph) behind \(ctx.trunk)\(ui.reset)"
        } else if let reason = drift[branch] {
            note = "  \(ui.dim)\(Stack.stackGlyph(ui)) \(reason)\(ui.reset)"
        }
        let noun = count == 1 ? "commit" : "commits"
        return " \(ui.dim)\(TerminalUI.ahead)\(count) \(noun)\(ui.reset)" + aheadBehindText(branch) + note
    }

    private func aheadBehindText(_ branch: String) -> String {
        guard let counts = cache.lookup(branch, in: ctx.git) else { return "" }
        var parts: [String] = []
        if counts.ahead > 0 { parts.append("\(TerminalUI.up)\(counts.ahead)") }
        if counts.behind > 0 { parts.append("\(TerminalUI.down)\(counts.behind)") }
        return parts.isEmpty ? "" : " \(ui.green)\(parts.joined(separator: " "))\(ui.reset)"
    }

    /// Columns, counted in code points as the other copies of `stack` do.
    static func width(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    static func trimmingTrailingWhitespace(_ line: String) -> String {
        var line = line
        while let last = line.last, last.isWhitespace { line.removeLast() }
        return line
    }
}
