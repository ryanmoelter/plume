import Foundation

/// Every `wt` subcommand. Each takes the arguments after its name and throws
/// `CLIFailure` where the Python tool called `die` or `sys.exit`.
nonisolated extension WT {
    /// `list|l [--json] [--paths]`.
    static func list(_ ctx: any WTContext, _ arguments: [String]) throws {
        // TODO(PLUME-316 group C)
    }

    /// `current [--json]`. Outside a worktree, `--json` reports null fields
    /// and succeeds: the Sublime status bar polls it for arbitrary files.
    static func current(_ ctx: any WTContext, _ arguments: [String]) throws {
        // TODO(PLUME-316 group C)
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
        // TODO(PLUME-316 group B)
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
        // TODO(PLUME-316 group B)
    }

    /// The help page: commands, the symbol key, then the resolved settings.
    static func usage(_ ctx: any WTContext) {
        // TODO(PLUME-316 group C)
    }
}
