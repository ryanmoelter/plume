import Foundation

/// Every `wt` subcommand. Each takes the arguments after its name and throws
/// `CLIFailure` where the Python tool called `die` or `sys.exit`.
nonisolated extension WT {
    /// `list|l [--json] [--paths]`.
    static func list(_ ctx: any WTContext, _ arguments: [String]) throws {
        var asJSON = false
        var showPaths = false
        for argument in arguments {
            switch argument {
            case "--json": asJSON = true
            case "--paths", "--dirs": showPaths = true
            default: throw CLIFailure("list: unknown flag: \(argument)")
            }
        }

        // Started first, so the network round trip overlaps the status scan.
        let fetch = ctx.startPRFetch(allBranches: false)
        let cwdName = ctx.currentWorktreeNameOrNone()
        let rows = buildRows(ctx)
        if rows.isEmpty {
            if asJSON {
                ctx.console.print(WorktreeListPayload(prState: .off, worktrees: []).jsonString())
            } else {
                ctx.console.print("\(programName): no worktrees for \(ctx.root)")
            }
            return
        }

        if asJSON {
            // The payload is parsed, not watched, so it waits once and never redraws.
            let resolved = fetch.map { collectPRs($0, timeout: jsonPRWait) } ?? (state: .off, prs: [:])
            let payload = buildListJSON(
                rows, cwdName: cwdName, prState: resolved.state, prs: resolved.prs,
                paths: ctx.worktreePathsInListOrder(), trunkBranches: ctx.trunkBranches
            )
            ctx.console.print(payload.jsonString())
            return
        }

        let dirs = showPaths ? ctx.worktreePathsInListOrder().map { displayLocation($0, root: ctx.root) } : nil
        printListLive(
            rows, cwdName: cwdName, fetch: fetch, trunkBranches: ctx.trunkBranches,
            live: ctx.console.stdoutIsTerminal, dirs: dirs, ui: ctx.ui, console: ctx.console
        )
    }

    private struct CurrentPayload: Encodable {
        var worktree: String?
        var branch: String?
        var path: String?
        var root: String
        var layout: WorktreeLayout

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeOrNull(worktree, forKey: .worktree)
            try container.encodeOrNull(branch, forKey: .branch)
            try container.encodeOrNull(path, forKey: .path)
            try container.encode(root, forKey: .root)
            try container.encode(layout, forKey: .layout)
        }

        private enum CodingKeys: String, CodingKey {
            case worktree, branch, path, root, layout
        }
    }

    /// `current [--json]`. Outside a worktree, `--json` reports null fields
    /// and succeeds: the Sublime status bar polls it for arbitrary files.
    static func current(_ ctx: any WTContext, _ arguments: [String]) throws {
        var asJSON = false
        for argument in arguments {
            guard argument == "--json" else { throw CLIFailure("current: unknown flag: \(argument)") }
            asJSON = true
        }

        let current = ctx.currentWorktree()
        let branch = try current.map { try ctx.git.branchOf($0.path) }

        if asJSON {
            let payload = CurrentPayload(worktree: current?.name, branch: branch, path: current?.path, root: ctx.root, layout: ctx.layout)
            ctx.console.print(jsonLine(payload))
        } else if let current, let branch {
            ctx.console.print("\(current.name)  \(branch)")
        } else {
            throw CLIFailure("not in a wt-managed worktree")
        }
    }

    /// `checkout|co [-b] <branch> [--no-tab|--task]`, and `cob` with
    /// `create`.
    static func checkout(_ ctx: any WTContext, _ arguments: [String], create: Bool = false) throws {
        // TODO(PLUME-316 group D)
    }

    /// `open|o <name> [--task]`.
    static func open(_ ctx: any WTContext, _ arguments: [String]) throws {
        // TODO(PLUME-316 group D)
    }

    /// `background|bg [name] [--no-tab|--task]`: moves the current branch and
    /// its uncommitted work to a new worktree.
    static func background(_ ctx: any WTContext, _ arguments: [String]) throws {
        // TODO(PLUME-316 group D)
    }

    /// `foreground|fg <name>`: takes another worktree's branch and changes
    /// into the current one, then removes it.
    static func foreground(_ ctx: any WTContext, _ arguments: [String]) throws {
        // TODO(PLUME-316 group D)
    }

    /// `delete|d <name> [-f|--force]`.
    static func delete(_ ctx: any WTContext, _ arguments: [String]) throws {
        // TODO(PLUME-316 group D)
    }

    /// `prune|p [-y|--yes]`.
    static func prune(_ ctx: any WTContext, _ arguments: [String]) throws {
        // TODO(PLUME-316 group D)
    }

    /// `rename|r [name] <new> [-f|--folder]`.
    static func rename(_ ctx: any WTContext, _ arguments: [String]) throws {
        // TODO(PLUME-316 group D)
    }

    /// `commit|cm <name> [git-args]`.
    static func commit(_ ctx: any WTContext, _ arguments: [String]) throws {
        // TODO(PLUME-316 group D)
    }

    /// `path <name|branch>`: prints the path, preferring a worktree name over
    /// a checked-out branch.
    static func path(_ ctx: any WTContext, _ arguments: [String]) throws {
        guard let name = arguments.first, !name.isEmpty else {
            throw CLIFailure("path: worktree name or branch required")
        }
        let path: String
        if ctx.worktreeExists(name) {
            path = try ctx.worktreePath(name)
        } else if let branchPath = pathForBranch(ctx, name) {
            path = branchPath
        } else {
            throw CLIFailure("no worktree or checked-out branch matching: \(name)")
        }
        ctx.console.print(path)
    }

    /// `switch|s <name|branch>`. The `plume init zsh` wrapper turns this into
    /// a `cd`, so reaching the binary means the wrapper is absent: inside
    /// Plume it opens a tab there, otherwise it fails naming the wrapper.
    static func switchTo(_ ctx: any WTContext, _ arguments: [String]) throws {
        // TODO(PLUME-316 group D)
    }

    /// `setup`: opens Settings ▸ Projects when Plume runs, else says where
    /// the settings live.
    static func setup(_ ctx: any WTContext, _ arguments: [String]) throws {
        // TODO(PLUME-316 group D)
    }

    /// Hidden `__complete worktrees|branches|checkoutable`, for the zsh
    /// completion. Prints one candidate per line.
    static func complete(_ ctx: any WTContext, _ arguments: [String]) throws {
        switch arguments.first {
        case "worktrees":
            ctx.listWorktreeNames().forEach { ctx.console.print($0) }
        case "branches":
            ctx.git.worktreeRecords().forEach { ctx.console.print($0.branch) }
        case "checkoutable":
            let checkedOut = Set(ctx.git.worktreeRecords().map(\.branch))
            ctx.git.localBranches().filter { !checkedOut.contains($0) }.forEach { ctx.console.print($0) }
        default:
            break
        }
    }

    /// The help page: commands, the symbol key, then the resolved settings.
    static func usage(_ ctx: any WTContext) {
        let ui = ctx.ui
        let b = ui.bold, r = ui.reset, d = ui.dim
        ctx.console.print("""
        \(b)wt\(r) — worktree helper (also `plume wt`)

        usage: \(b)wt <command> [args]\(r)

          \(b)wt list|l        [--json] [--paths]\(r)    show worktrees + statuses
                                                 \(d)(incl. PR/MR status when gh/glab is installed;
                                                  --paths adds each worktree's directory)\(r)
          \(b)wt checkout|co   [-b] <branch> [--no-tab|--task]\(r)
                                                 check out a branch in a new worktree; -b creates it
          \(b)wt cob           <branch> [--no-tab|--task]\(r)
                                                 shorthand for `co -b` (create + check out)
          \(b)wt background|bg [name] [--no-tab|--task]\(r)
                                                 move current branch+changes to a new worktree
          \(b)wt foreground|fg <name>\(r)                move a worktree's branch+changes into current
          \(b)wt rename|r      [name] <new> [-f|--folder]\(r)
                                                 rename branch; -f also renames the folder
          \(b)wt commit|cm     <name> [git-args...]\(r)  commit -a in another worktree
          \(b)wt open|o        <name> [--task]\(r)       open a worktree in a new Plume tab
          \(b)wt switch|s      <name|branch>\(r)         cd to that worktree (via `plume init zsh`)
          \(b)wt path          <name|branch>\(r)         print its path (scripts, other shells)
          \(b)wt current       [--json]\(r)              report the cwd's worktree + branch
          \(b)wt delete|d      <name> [-f|--force]\(r)   remove worktree (branch left intact)
          \(b)wt prune|p       [-y|--yes]\(r)            delete merged worktrees, then merged branches
          \(b)wt setup\(r)                               open Plume's Settings ▸ Projects
          \(b)wt help\(r)                                show this message

        Tab flags: inside Plume a worktree opens as a tab in the current task.
        --no-tab opens nothing; --task (or --workspace) opens it as a new task
        instead. Outside Plume, wt prints the directory to cd into.
        Shell integration: eval "$(plume init zsh)" in .zshrc.
        """)

        let prefix: String
        switch ctx.branchPrefixResolution() {
        case nil: prefix = "(unset: git user.email missing)"
        case ""?: prefix = "(none — no prefix)"
        case let resolved?: prefix = resolved
        }
        let kind = ctx.forgeKind
        let ignored = ctx.settings.ignoredPendingChecks ?? []
        let untrackedCache = ctx.git.configGet("core.untrackedCache") ?? ""

        ctx.console.print()
        ctx.console.print(ui.glyphKey(forgeIcon: ui.forgeIcon(for: kind), numberPrefix: kind == .gitlab ? "!" : "#").joined(separator: "\n"))
        ctx.console.print("""

        Current config (resolved), set in Plume's Settings ▸ Projects (`wt setup` opens it):
          baseBranch           \(ctx.baseBranch)
          branchPrefix         \(prefix)
          forge                \(kind.rawValue)
          nerdFont             \(ctx.settings.nerdFont == true ? "yes" : "no")
          protectedWorktrees   \(ctx.protected.isEmpty ? "(none)" : ctx.protected.joined(separator: ", "))
          ignoredPendingChecks \(ignored.isEmpty ? "(none)" : "\(ignored.count) check(s)")
          core.untrackedCache  \(untrackedCache.isEmpty ? "(unset — `git config core.untrackedCache true` speeds up `wt list`)" : untrackedCache)
        """)
    }
}
