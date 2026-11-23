import Foundation

/// Where one staged hunk goes: a commit of the current stack, or nowhere
/// and why.
nonisolated struct StackAbsorbTarget: Equatable, Sendable {
    var file: String
    var hunk: StackHunk
    /// Index into the stack's commits, oldest first, or nil when unclear.
    var commit: Int?
    var reason: String?
}

nonisolated enum StackAbsorbPlanner {
    /// Picks each hunk's commit from `blame`, the stack commit (by index,
    /// oldest first) that last touched each old-side line. A hunk goes to the
    /// newest commit among the lines it removes, or among its context when it
    /// only adds. Every line of its old side, context included, must be
    /// unchanged since that commit, or the fixup wouldn't apply there.
    static func target(_ hunk: StackHunk, file: String, blame: [Int: String], stackIndex: [String: Int]) -> StackAbsorbTarget {
        let span = hunk.oldCount > 0 ? Array(hunk.oldStart ..< hunk.oldStart + hunk.oldCount) : []
        let removed = hunk.removedOldLines
        let decisive = removed.isEmpty ? span : removed
        func unclear(_ reason: String) -> StackAbsorbTarget {
            StackAbsorbTarget(file: file, hunk: hunk, commit: nil, reason: reason)
        }
        if decisive.isEmpty { return unclear("no existing lines to blame") }
        guard let commit = decisive.compactMap({ blame[$0].flatMap { stackIndex[$0] } }).max() else {
            return unclear("lines last touched outside the stack")
        }
        if let later = span.compactMap({ blame[$0].flatMap { stackIndex[$0] } }).first(where: { $0 > commit }) {
            let sha = stackIndex.first { $0.value == later }?.key.prefix(10) ?? ""
            return unclear("its context was changed again later, in \(sha)")
        }
        return StackAbsorbTarget(file: file, hunk: hunk, commit: commit, reason: nil)
    }

    /// `git blame --porcelain`: final line number to commit.
    static func parseBlame(_ output: String) -> [Int: String] {
        var lines: [Int: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: " ")
            guard fields.count >= 3, fields[0].count >= 40,
                  fields[0].allSatisfy(\.isHexDigit),
                  let final = Int(fields[2])
            else { continue }
            lines[final] = String(fields[0])
        }
        return lines
    }
}

nonisolated extension Stack {
    static func absorb(_ ctx: StackContext, _ arguments: [String]) throws {
        if let leftover = arguments.first(where: { $0 != "--dry-run" }) { throw CLIFailure("unknown argument: \(leftover)") }
        let dryRun = arguments.contains("--dry-run")
        if ctx.git.currentBranch() == nil { throw CLIFailure("detached HEAD — check out a branch first") }
        if try rebaseInProgress(ctx) {
            throw CLIFailure("a rebase is in progress — `git rebase --continue` or `git rebase --abort` first")
        }
        try ctx.state.withLock {
            var branches = try ctx.loadAndFlushLocked()
            let current = try requireCurrentTracked(ctx, branches)
            let path = StackGraph.path(branches, to: current)
            let stack = try stackCommits(ctx, branches, path)
            let files = StackPatch.parse(try ctx.git.run(StackPatch.diffArguments + ["--cached"]).stdout)
            if files.isEmpty { throw CLIFailure("nothing staged — `git add` the changes to absorb first") }
            let targets = try plan(ctx, files, stack)
            let absorbed = targets.filter { $0.commit != nil }
            let left = targets.filter { $0.commit == nil }
            let subjects = try commitSubjects(ctx, Set(absorbed.compactMap(\.commit)).map { stack.commits[$0] })
            for target in absorbed {
                let commit = stack.commits[target.commit!]
                ctx.console.print("\(dryRun ? "would absorb" : "absorbed") \(target.file) \(target.hunk.range) → \(commit.prefix(10)) (\(stack.owner[commit] ?? "")) \(subjects[commit] ?? "")")
            }
            if !left.isEmpty {
                ctx.console.print("left staged (no clear target):")
                for target in left {
                    let place = [target.file, target.hunk.range].filter { !$0.isEmpty }.joined(separator: " ")
                    ctx.console.print("  \(place): \(target.reason ?? "")")
                }
            }
            if absorbed.isEmpty { throw CLIFailure("no staged hunk has a clear target in the stack") }
            if dryRun { return }
            let snapshot = try ctx.recordUndo(undoLabel("absorb", arguments), branches, keepsIndex: true)
            let moved = try rewrite(ctx, &branches, path, stack, files, absorbed)
            try ctx.saveState(branches)
            try restackForks(ctx, &branches, path: path, moved: moved, current: current)
            try ctx.discardUndoIfUnchanged(snapshot, branches)
        }
    }

    /// The commits of the branches on `path`, oldest first, with the branch
    /// that owns each.
    struct StackCommits {
        var commits: [String] = []
        var owner: [String: String] = [:]
        var index: [String: Int] = [:]
    }

    private static func stackCommits(_ ctx: StackContext, _ branches: StackBranches, _ path: [String]) throws -> StackCommits {
        var stack = StackCommits()
        for (position, branch) in path.enumerated() {
            let parentTip = try ctx.parentTip(branches, branch)
            let floor: String
            if position == 0 {
                floor = try ctx.replayFloor(branches, branch, parentTip: parentTip)
            } else {
                guard ctx.git.isAncestor(parentTip, try ctx.rev(branch)) else {
                    throw CLIFailure("'\(branch)' isn't on its parent's tip — run `stack restack` first")
                }
                floor = parentTip
            }
            let range = "\(floor)..\(GitRef.local(branch))"
            if !(try ctx.git.git("rev-list", "--merges", range)).isEmpty {
                throw CLIFailure("'\(branch)' has merge commits — absorb only rewrites linear history")
            }
            for commit in try ctx.git.git("rev-list", "--reverse", range).split(separator: "\n").map(String.init) {
                stack.index[commit] = stack.commits.count
                stack.commits.append(commit)
                stack.owner[commit] = branch
            }
        }
        return stack
    }

    private static func plan(_ ctx: StackContext, _ files: [StackDiffFile], _ stack: StackCommits) throws -> [StackAbsorbTarget] {
        try files.flatMap { file -> [StackAbsorbTarget] in
            let reason: String? = switch file.kind {
            case .modified, .deleted: nil
            case .added: "a new file"
            case .unsupported(let why): why
            }
            if let reason {
                let hunks = file.hunks.isEmpty ? [StackHunk(header: "", lines: [], oldStart: 0, oldCount: 0, newStart: 0, newCount: 0)] : file.hunks
                return hunks.map { StackAbsorbTarget(file: file.path, hunk: $0, commit: nil, reason: reason) }
            }
            let top = try ctx.git.git("rev-parse", "--show-toplevel")
            let blame = StackAbsorbPlanner.parseBlame(try ctx.git.git("-C", top, "blame", "--porcelain", "HEAD", "--", file.path))
            return file.hunks.map { StackAbsorbPlanner.target($0, file: file.path, blame: blame, stackIndex: stack.index) }
        }
    }

    private static func commitSubjects(_ ctx: StackContext, _ commits: [String]) throws -> [String: String] {
        var subjects: [String: String] = [:]
        for commit in commits { subjects[commit] = try ctx.git.git("log", "-1", "--format=%s", commit) }
        return subjects
    }

    /// Rebuilds the stack from the oldest target up with each fixup squashed
    /// in, without touching the index or the working tree, then moves the
    /// branches. Returns the branches that moved.
    private static func rewrite(
        _ ctx: StackContext,
        _ branches: inout StackBranches,
        _ path: [String],
        _ stack: StackCommits,
        _ files: [StackDiffFile],
        _ absorbed: [StackAbsorbTarget]
    ) throws -> Set<String> {
        let here = try ctx.git.git("rev-parse", "--show-toplevel")
        let worktrees = ctx.git.worktreeMap().filter { $0.value != here }
        let lowest = absorbed.compactMap(\.commit).min()!
        for branch in Set(stack.commits[lowest...].compactMap { stack.owner[$0] }) {
            if let worktree = worktrees[branch] {
                throw CLIFailure("'\(branch)' is checked out in \(worktree) — absorb can't rewrite it from here")
            }
        }
        let patches = Dictionary(grouping: absorbed, by: { $0.commit! }).mapValues { patch(files, $0) }
        var mapping: [String: String] = [:]
        var parent = try ctx.git.git("rev-parse", "\(stack.commits[lowest])^")
        for index in lowest ..< stack.commits.count {
            let commit = stack.commits[index]
            let originalParent = try ctx.git.git("rev-parse", "\(commit)^")
            let originalTree = try ctx.git.git("rev-parse", "\(commit)^{tree}")
            guard var tree = parent == originalParent ? originalTree : try ctx.replayTree(commit, onto: parent) else {
                throw CLIFailure("replaying \(commit.prefix(10)) over the fixups conflicts — nothing was moved")
            }
            if let patch = patches[index] {
                guard let fixed = try ctx.applying(patch, to: tree) else {
                    throw CLIFailure("the fixup for \(commit.prefix(10)) doesn't apply there — nothing was moved")
                }
                tree = fixed
            }
            parent = parent == originalParent && tree == originalTree ? commit : try ctx.recommit(commit, tree: tree, parent: parent)
            mapping[commit] = parent
        }
        let head = try ctx.rev(path.last!)
        let expected = try ctx.applying(patch(files, absorbed), to: try ctx.git.git("rev-parse", "\(head)^{tree}"))
        guard let expected, expected == (try ctx.git.git("rev-parse", "\(parent)^{tree}")) else {
            throw CLIFailure("absorbing would change the stack's final tree — nothing was moved")
        }
        var moved = Set<String>()
        var newTips: [String: String] = [:]
        for branch in path {
            let old = try ctx.rev(branch)
            guard let new = mapping[old], new != old else { continue }
            try ctx.git.git("update-ref", GitRef.local(branch), new, old)
            newTips[branch] = new
            moved.insert(branch)
        }
        for branch in path {
            if let parent = branches[branch]?.parent, let tip = newTips[parent] { branches[branch]?.base = tip }
        }
        return moved
    }

    /// One patch holding `targets`' hunks, grouped by file in diff order.
    private static func patch(_ files: [StackDiffFile], _ targets: [StackAbsorbTarget]) -> String {
        files.compactMap { file in
            let hunks = file.hunks.filter { hunk in targets.contains { $0.file == file.path && $0.hunk == hunk } }
            return hunks.isEmpty ? nil : file.patch(hunks)
        }.joined()
    }

    /// Restacks the branches forking off a moved branch of `path`. A
    /// restack checks them out, so it waits for a clean tree.
    private static func restackForks(
        _ ctx: StackContext,
        _ branches: inout StackBranches,
        path: [String],
        moved: Set<String>,
        current: String
    ) throws {
        let onPath = Set(path)
        let forks = StackGraph.subtree(branches, of: path[0]).filter { branch in
            guard !onPath.contains(branch) else { return false }
            var ancestor = branches[branch]?.parent
            while let name = ancestor, branches[name] != nil {
                if moved.contains(name) { return true }
                ancestor = branches[name]?.parent
            }
            return false
        }
        if forks.isEmpty { return }
        if !(try ctx.git.git("status", "--porcelain", "--untracked-files=no")).isEmpty {
            ctx.warn("branches stacked on the absorbed ones need a restack: \(forks.joined(separator: ", ")) (commit what's left, then `stack restack --all`)")
            return
        }
        var adopted = Set<String>()
        do {
            for result in try restackStack(ctx, &branches, forks, dryRun: false, adopted: &adopted) {
                ctx.console.print("  \(result.branch): \(result.action)")
            }
        } catch {
            returnToStartingBranch(ctx, current, after: error, dryRun: false)
            throw error
        }
        try ctx.saveState(branches)
        if ctx.git.currentBranch() != current { try ctx.git.switchTo(current, quiet: true) }
    }
}
