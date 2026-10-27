import Foundation

/// Building and navigating stacks: create, split, track, untrack, checkout,
/// and prev/next/first/last.
nonisolated extension Stack {
    static func create(_ ctx: StackContext, _ arguments: [String]) throws {
        var insert = false
        var name: String?
        for argument in arguments {
            if argument == "--insert" {
                insert = true
            } else if argument.hasPrefix("-") {
                throw CLIFailure("unknown flag: \(argument)")
            } else if name == nil {
                name = argument
            } else {
                throw CLIFailure("too many arguments (usage: stack create <name> [--insert])")
            }
        }
        guard let rawName = name, !rawName.isEmpty else { throw CLIFailure("usage: stack create <name> [--insert]") }
        let branch = ctx.applyPrefix(rawName)
        if ctx.git.branchExists(branch) {
            throw CLIFailure("branch '\(branch)' already exists — `stack track \(branch)` to track it")
        }
        guard let current = ctx.git.currentBranch() else { throw CLIFailure("detached HEAD — check out a branch first") }
        try ctx.state.withLock {
            var branches = try ctx.loadAndFlushLocked()
            if branches[current] == nil, current != ctx.trunk {
                throw CLIFailure("'\(current)' is not in a stack — run `stack track` first")
            }
            if insert, branches[current] == nil {
                throw CLIFailure("--insert requires the current branch to be in a stack")
            }
            let result = try ctx.git.run(["switch", "-c", branch], capture: false)
            if result.status != 0 { throw CLIFailure(nil, code: result.status) }
            if insert {
                // Their base already equals this tip, so it stays consistent.
                for child in branches.keys where branches[child]?.parent == current {
                    branches[child]?.parent = branch
                }
            }
            branches[branch] = StackEntry(parent: current, base: try ctx.rev(branch))
            try ctx.saveState(branches)
        }
        ctx.console.print("created '\(branch)' on '\(current)'" + (insert ? " (children moved onto it)" : ""))
    }

    static func split(_ ctx: StackContext, _ arguments: [String]) throws {
        guard let current = ctx.git.currentBranch() else { throw CLIFailure("detached HEAD — check out a branch first") }
        try ctx.state.withLock {
            var branches = try ctx.loadAndFlushLocked()
            guard let entry = branches[current] else {
                throw CLIFailure("'\(current)' is not in a stack — run `stack track` first")
            }
            let tip = try ctx.rev(current)
            var base = entry.base
            if !ctx.git.isAncestor(base, tip) {
                guard let mergeBase = ctx.git.mergeBase(try ctx.parentTip(branches, current), tip) else {
                    throw CLIFailure("'\(current)' shares no history with '\(entry.parent)'")
                }
                base = mergeBase
            }
            let listed = try ctx.git.git("rev-list", "--reverse", "\(base)..\(StackRef.local(current))")
            let commits = listed.isEmpty ? [] : listed.components(separatedBy: "\n")
            if commits.count < 2 {
                throw CLIFailure("'\(current)' has \(commits.count) commit(s) on '\(entry.parent)' — nothing to split")
            }
            let requested = arguments.isEmpty
                ? try interactiveSplit(ctx, current, commits)
                : try parseSplitArguments(ctx, arguments, commits)
            let pairs = requested.map { (name: ctx.applyPrefix($0.name), sha: $0.sha) }
            for pair in pairs where ctx.git.branchExists(pair.name) {
                throw CLIFailure("branch '\(pair.name)' already exists")
            }
            if Set(pairs.map(\.name)).count != pairs.count { throw CLIFailure("duplicate branch names") }
            var previous = (name: entry.parent, sha: entry.base)
            for pair in pairs {
                try ctx.git.git("branch", pair.name, pair.sha)
                branches[pair.name] = StackEntry(parent: previous.name, base: previous.sha)
                previous = pair
            }
            branches[current]?.parent = previous.name
            branches[current]?.base = previous.sha
            try ctx.saveState(branches)
            ctx.console.print("split '\(current)' into: \(pairs.map(\.name).joined(separator: ", ")) ← \(current)")
            let root = StackGraph.root(branches, of: current)
            ctx.console.print(try render(ctx, branches, roots: [root], current: current, prs: [:], prState: .off))
        }
    }

    private static func parseSplitArguments(
        _ ctx: StackContext,
        _ arguments: [String],
        _ commits: [String]
    ) throws -> [(name: String, sha: String)] {
        var pairs: [(name: String, sha: String)] = []
        var lastIndex = -1
        for argument in arguments {
            guard let colon = argument.firstIndex(of: ":") else {
                throw CLIFailure("expected <name>:<commit>, got '\(argument)'")
            }
            let name = String(argument[..<colon])
            let committish = String(argument[argument.index(after: colon)...])
            if name.isEmpty || committish.isEmpty { throw CLIFailure("expected <name>:<commit>, got '\(argument)'") }
            guard let sha = ctx.git.resolve(committish) else { throw CLIFailure("unknown ref: \(committish)") }
            guard let index = commits.firstIndex(of: sha) else {
                throw CLIFailure("\(committish) (\(sha.prefix(12))) is not one of this branch's own commits")
            }
            if index <= lastIndex {
                throw CLIFailure("boundaries must be in ascending (oldest-first) order and distinct")
            }
            if index == commits.count - 1 {
                throw CLIFailure("\(committish) is the branch tip — the current branch keeps the last commits")
            }
            pairs.append((name, sha))
            lastIndex = index
        }
        return pairs
    }

    private static func interactiveSplit(
        _ ctx: StackContext,
        _ current: String,
        _ commits: [String]
    ) throws -> [(name: String, sha: String)] {
        var subjects: [String: String] = [:]
        for line in try ctx.git.git("log", "--reverse", "--format=%H %s", "\(commits[0])~..\(StackRef.local(current))").components(separatedBy: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            subjects[String(line[..<space])] = String(line[line.index(after: space)...])
        }
        let listing = commits.enumerated().map { index, sha in
            "  \(padded(index + 1))) \(sha.prefix(10)) \(subjects[sha] ?? "")"
        }.joined(separator: "\n")
        guard ctx.console.stdinIsTerminal, ctx.console.stdoutIsTerminal else {
            throw CLIFailure("""
                no TTY — pass boundaries as arguments: stack split <name>:<commit> ...
                commits on '\(current)' (oldest first):
                \(listing)
                """)
        }
        ctx.console.print("commits on '\(current)' (oldest first):\n\(listing)")
        guard let raw = ctx.console.readLine(
            prompt: "boundary commit numbers, space-separated oldest first (1-\(commits.count - 1); '\(current)' keeps the rest): "
        ) else { throw CLIFailure("cancelled") }
        var indices: [Int] = []
        for token in raw.split(whereSeparator: \.isWhitespace) {
            guard token.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(token), (1 ... commits.count - 1).contains(number) else {
                throw CLIFailure("invalid boundary: '\(token)'")
            }
            indices.append(number - 1)
        }
        if indices.isEmpty || Array(Set(indices)).sorted() != indices {
            throw CLIFailure("boundaries must be distinct and ascending")
        }
        return try indices.map { index in
            let sha = commits[index]
            guard let name = ctx.console.readLine(prompt: "branch name ending at \(sha.prefix(10)) (\(subjects[sha] ?? "")): ") else {
                throw CLIFailure("cancelled")
            }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { throw CLIFailure("empty branch name") }
            return (trimmed, sha)
        }
    }

    /// Tracks `branch` under `parent`, or moves it there when tracked.
    static func trackWithParent(
        _ ctx: StackContext,
        _ branches: inout StackBranches,
        _ branch: String,
        _ parent: String,
        announce: Bool = true
    ) throws {
        if parent == branch { throw CLIFailure("a branch cannot be its own parent") }
        if parent != ctx.trunk, !ctx.git.branchExists(parent) { throw CLIFailure("no local branch '\(parent)'") }
        if parent != ctx.trunk, branches[parent] == nil {
            throw CLIFailure("parent '\(parent)' is not tracked — `stack track \(parent)` first")
        }
        let parentTip = branches[parent] != nil ? try ctx.rev(parent) : try ctx.trunkTip()
        guard let base = ctx.git.mergeBase(parentTip, try ctx.rev(branch)) else {
            throw CLIFailure("'\(branch)' shares no history with '\(parent)'")
        }
        if branches[branch] == nil {
            branches[branch] = StackEntry(parent: parent, base: base)
        } else {
            if StackGraph.subtree(branches, of: branch).contains(parent) {
                throw CLIFailure("'\(parent)' is stacked on top of '\(branch)' — that would be a cycle")
            }
            branches[branch]?.parent = parent
            branches[branch]?.base = base
        }
        if announce { ctx.console.print("tracking '\(branch)' (parent: \(parent))") }
    }

    /// Tracks `branch` plus every untracked local branch whose tip sits
    /// between the trunk and it, in ancestry order.
    private static func trackChain(_ ctx: StackContext, _ branches: inout StackBranches, _ branch: String) throws {
        let branchTip = try ctx.rev(branch)
        guard let trunkBase = ctx.git.mergeBase(try ctx.trunkTip(), branchTip) else {
            throw CLIFailure("'\(branch)' shares no history with trunk '\(ctx.trunk)'")
        }
        var candidates: [(name: String, tip: String)] = []
        for local in try ctx.git.localBranches() where local != branch && local != ctx.trunk {
            let tip = try ctx.rev(local)
            if tip != branchTip, ctx.git.isAncestor(tip, branchTip), !ctx.git.isAncestor(tip, trunkBase) {
                candidates.append((local, tip))
            }
        }
        let distances = try candidates.map { try ctx.git.revListCount("\(trunkBase)..\($0.tip)") }
        candidates = zip(candidates, distances).enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
            .map(\.element.0)
        for (lower, upper) in zip(candidates, candidates.dropFirst())
        where lower.tip == upper.tip || !ctx.git.isAncestor(lower.tip, upper.tip) {
            throw CLIFailure(
                "branches between trunk and '\(branch)' don't form a single chain "
                    + "(\(candidates.map(\.name).joined(separator: ", "))) — use `stack track --parent <p>` explicitly"
            )
        }
        var previous = (name: ctx.trunk, tip: try ctx.trunkTip())
        var newlyTracked: [String] = []
        for candidate in candidates + [(branch, branchTip)] {
            if branches[candidate.name] == nil {
                guard let base = ctx.git.mergeBase(previous.tip, candidate.tip) else {
                    throw CLIFailure("'\(candidate.name)' shares no history with '\(previous.name)'")
                }
                branches[candidate.name] = StackEntry(parent: previous.name, base: base)
                newlyTracked.append("\(candidate.name) (parent: \(previous.name))")
            }
            previous = candidate
        }
        ctx.console.print("tracking: " + newlyTracked.joined(separator: ", "))
    }

    static func track(_ ctx: StackContext, _ arguments: [String]) throws {
        var parent: String?
        var named: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--parent" {
                index += 1
                guard index < arguments.count else { throw CLIFailure("--parent needs a value") }
                parent = arguments[index]
            } else if argument.hasPrefix("-") {
                throw CLIFailure("unknown flag: \(argument)")
            } else if named == nil {
                named = argument
            } else {
                throw CLIFailure("too many arguments (usage: stack track [<branch>] [--parent <p>])")
            }
            index += 1
        }
        guard let branch = named ?? ctx.git.currentBranch() else { throw CLIFailure("detached HEAD — pass a branch name") }
        if !ctx.git.branchExists(branch) { throw CLIFailure("no local branch '\(branch)'") }
        if branch == ctx.trunk { throw CLIFailure("'\(branch)' is the trunk — it can't be part of a stack") }
        try ctx.state.withLock {
            var branches = try ctx.loadAndFlushLocked()
            if let parent {
                try trackWithParent(ctx, &branches, branch, parent)
            } else {
                if let entry = branches[branch] {
                    ctx.console.print("'\(branch)' is already tracked (parent: \(entry.parent)) — use --parent to move it")
                    return
                }
                try trackChain(ctx, &branches, branch)
            }
            try ctx.saveState(branches)
        }
    }

    static func untrack(_ ctx: StackContext, _ arguments: [String]) throws {
        if arguments.count > 1 { throw CLIFailure("too many arguments (usage: stack untrack [<branch>])") }
        guard let branch = arguments.first ?? ctx.git.currentBranch() else {
            throw CLIFailure("detached HEAD — pass a branch name")
        }
        let untracked = try ctx.state.withLock { () throws -> Bool in
            var branches = try ctx.loadAndFlushLocked()
            guard let entry = branches[branch] else {
                ctx.console.print("'\(branch)' is not tracked — nothing to do")
                return false
            }
            // Children keep their base: it still names this branch's old tip.
            for child in branches.keys where branches[child]?.parent == branch {
                branches[child]?.parent = entry.parent
            }
            branches[branch] = nil
            try ctx.saveState(branches)
            return true
        }
        if untracked { ctx.console.print("untracked '\(branch)' (git branch left intact)") }
    }

    static func checkout(_ ctx: StackContext, _ arguments: [String]) throws {
        if arguments.count > 1 { throw CLIFailure("too many arguments (usage: stack checkout [<branch>])") }
        if let branch = arguments.first {
            if !ctx.git.branchExists(branch) { throw CLIFailure("no local branch '\(branch)'") }
            try ctx.git.switchTo(branch)
            return
        }
        let branches = try ctx.loadAndFlush()
        if branches.isEmpty { throw CLIFailure("no stacks tracked yet") }
        let current = ctx.git.currentBranch()
        let depths = StackGraph.depths(branches)
        let candidates = StackGraph.roots(branches).flatMap { root in
            StackGraph.subtree(branches, of: root).map { branch in
                let indent = String(repeating: "  ", count: (depths[branch] ?? 1) - 1)
                return (value: branch, display: indent + branch + (branch == current ? "  ← current" : ""))
            }
        }
        try ctx.git.switchTo(try pick(ctx, candidates, what: "branch"))
    }

    static func navigate(_ ctx: StackContext, _ which: StackNavigation, _ arguments: [String]) throws {
        if !arguments.isEmpty { throw CLIFailure("stack \(which.rawValue) takes no arguments") }
        let all = try ctx.loadAndFlush()
        guard let current = ctx.git.currentBranch() else { throw CLIFailure("detached HEAD — check out a branch first") }
        let entry = all[current]
        let branches: StackBranches
        if entry != nil {
            branches = StackGraph.stack(all, of: current)
        } else {
            if all.isEmpty { throw CLIFailure("no stacks tracked yet") }
            let roots = StackGraph.roots(all)
            if roots.count != 1 {
                throw CLIFailure("'\(current)' is not in a stack and there are several — `stack co <branch>` (roots: \(roots.joined(separator: ", ")))")
            }
            branches = StackGraph.stack(all, of: roots[0])
        }
        switch which {
        case .prev:
            guard let entry else { throw CLIFailure("'\(current)' is not in a stack") }
            if branches[entry.parent] != nil || ctx.git.branchExists(entry.parent) {
                try ctx.git.switchTo(entry.parent)
                return
            }
            throw CLIFailure("parent '\(entry.parent)' has no local branch")
        case .next:
            let candidates = entry == nil ? StackGraph.roots(branches) : StackGraph.children(branches, of: current)
            if candidates.isEmpty { throw CLIFailure("'\(current)' has no child — it's the tip") }
            if candidates.count > 1 {
                throw CLIFailure("multiple children: \(candidates.joined(separator: ", ")) — use `stack co <branch>`")
            }
            try ctx.git.switchTo(candidates[0])
        case .first:
            let roots = StackGraph.roots(branches)
            if roots.count > 1 { throw CLIFailure("multiple roots: \(roots.joined(separator: ", ")) — use `stack co <branch>`") }
            try ctx.git.switchTo(roots[0])
        case .last:
            let leaves = StackGraph.topologicalOrder(branches).filter { StackGraph.children(branches, of: $0).isEmpty }
            if leaves.count > 1 { throw CLIFailure("multiple tips: \(leaves.joined(separator: ", ")) — use `stack co <branch>`") }
            try ctx.git.switchTo(leaves[0])
        }
    }

    /// A value from `candidates`: through fzf when installed, else a
    /// numbered prompt. Without a terminal it fails listing the candidates,
    /// so a script can pass one instead.
    static func pick(_ ctx: StackContext, _ candidates: [(value: String, display: String)], what: String) throws -> String {
        if candidates.isEmpty { throw CLIFailure("no \(what) to pick from") }
        guard ctx.console.stdinIsTerminal, ctx.console.stdoutIsTerminal else {
            let names = candidates.map { "  \($0.value)" }.joined(separator: "\n")
            throw CLIFailure("no TTY — pass the \(what) as an argument. Candidates:\n\(names)")
        }
        if let fzf = ctx.fzfPath {
            let result = try CLIProcess.run(
                [fzf, "--height=40%", "--reverse", "--prompt", "\(what)> "],
                check: false,
                input: candidates.map(\.display).joined(separator: "\n")
            )
            let selection = result.stdout.trimmingCharacters(in: .newlines)
            guard result.status == 0, !selection.isEmpty,
                  let chosen = candidates.first(where: { $0.display == selection })
            else { throw CLIFailure("cancelled") }
            return chosen.value
        }
        ctx.console.print("pick a \(what):")
        for (index, candidate) in candidates.enumerated() {
            ctx.console.print("  \(padded(index + 1))) \(candidate.display)")
        }
        guard let raw = ctx.console.readLine(prompt: "> ")?.trimmingCharacters(in: .whitespaces) else {
            throw CLIFailure("cancelled")
        }
        guard raw.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(raw), (1 ... candidates.count).contains(number) else {
            throw CLIFailure("invalid choice: '\(raw)'")
        }
        return candidates[number - 1].value
    }

    /// `%2d`.
    static func padded(_ number: Int) -> String {
        let text = String(number)
        return text.count < 2 ? " " + text : text
    }
}
