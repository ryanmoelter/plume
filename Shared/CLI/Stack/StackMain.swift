import Foundation

/// `plume stack`: stacked branches for a squash-merge PR/MR workflow.
nonisolated enum Stack {
    static let programName = "stack"
    /// A restack stopped on a rebase conflict.
    static let conflictExitCode: Int32 = 3
    /// The listing paints at once and never waits on the forge, so its fetch
    /// gets a budget well past what a blocking wait could afford.
    static let listPRBudget: TimeInterval = 8
    /// A mutating command has committed to the forge, so it waits rather
    /// than degrade to a partial answer.
    static let blockingPRBudget: TimeInterval = 30

    static let commands = [
        "list", "l", "la", "create", "c", "split", "track", "untrack",
        "checkout", "co", "prev", "next", "first", "last",
        "restack", "submit", "sync", "setup", "help",
    ]

    static let helpCommands: Set<String> = ["help", "-h", "--help"]

    /// Every command `run` dispatches, aliases and the hidden completion
    /// helper included.
    static let dispatchable: Set<String> = Set(commands).union(["ls", "__complete"]).subtracting(helpCommands)

    /// `plume stack …`, and `stack …` through the opt-in link. Returns the
    /// exit status.
    static func main(
        _ arguments: [String],
        environment: [String: String],
        console: any CLIConsole,
        version: String?,
        workingDirectory: String? = nil,
        settingsSource: (any ProjectSettingsSource)? = nil
    ) -> Int32 {
        if let first = arguments.first, ["--version", "-V", "version"].contains(first) {
            console.print("\(programName) \(version ?? "(not inside Plume.app)")")
            return CLIExitCode.success
        }
        let settingsSource = settingsSource ?? UserDefaultsProjectSettingsSource(environment: environment)
        do {
            // Runs at shell startup from any directory, so it answers before
            // the repository is looked up.
            if arguments.first == "init" {
                throw CLIFailure(#"shell integration moved to plume: eval "$(plume init zsh)""#)
            }
            let command = arguments.first ?? "help"
            let isHelp = helpCommands.contains(command)
            if !isHelp, !dispatchable.contains(command) {
                throw CLIFailure("unknown command: \(command) (see `stack help`)")
            }
            let ctx: StackContext
            do {
                ctx = try StackContext.detect(
                    workingDirectory: workingDirectory,
                    settingsSource: settingsSource,
                    console: console,
                    environment: environment
                )
            } catch is CLIFailure where isHelp {
                let ui = WTSettings.terminalUI(
                    settings: settingsSource.load().defaults,
                    nerdFont: settingsSource.nerdFontMode(),
                    stdoutIsTerminal: console.stdoutIsTerminal,
                    environment: environment
                )
                usage(console: console, ui: ui, forgeKind: .none)
                return CLIExitCode.success
            } catch is CLIFailure where command == "__complete" {
                // Completion runs on every Tab press, in any directory.
                return CLIExitCode.success
            }
            if isHelp {
                usage(ctx)
            } else {
                try run(ctx, arguments)
            }
            return CLIExitCode.success
        } catch let failure as CLIFailure {
            if let message = failure.message { console.printError("\(programName): \(message)") }
            return failure.code
        } catch {
            console.printError("\(programName): \(error.localizedDescription)")
            return CLIExitCode.failure
        }
    }

    static func run(_ ctx: StackContext, _ arguments: [String]) throws {
        let command = arguments.first ?? "help"
        let rest = Array(arguments.dropFirst())
        switch command {
        case "list", "l", "ls": try list(ctx, rest)
        case "la": try list(ctx, ["--all"] + rest)
        case "create", "c": try create(ctx, rest)
        case "split": try split(ctx, rest)
        case "track": try track(ctx, rest)
        case "untrack": try untrack(ctx, rest)
        case "checkout", "co": try checkout(ctx, rest)
        case "prev": try navigate(ctx, .prev, rest)
        case "next": try navigate(ctx, .next, rest)
        case "first": try navigate(ctx, .first, rest)
        case "last": try navigate(ctx, .last, rest)
        case "restack": try restack(ctx, rest)
        case "submit": try submit(ctx, rest)
        case "sync": try sync(ctx, rest)
        case "setup": try setup(ctx, rest)
        case "__complete": try complete(ctx, rest)
        case "help", "-h", "--help": usage(ctx)
        default: throw CLIFailure("unknown command: \(command) (see `stack help`)")
        }
    }

    /// `setup`: opens Settings ▸ Projects when Plume runs, else says where
    /// the settings live.
    static func setup(_ ctx: StackContext, _ arguments: [String]) throws {
        if !arguments.isEmpty { throw CLIFailure("setup takes no arguments") }
        if ctx.app.openSettings(section: "projects") {
            ctx.console.print("\(programName): opened Plume's Settings ▸ Projects")
            return
        }
        ctx.console.print("""
            \(programName): project settings live in Plume's Settings ▸ Projects, for every
            repository and per repository. Open Plume and choose Settings ▸ Projects,
            then re-run `stack help` to see the resolved values.
            """)
    }

    /// Hidden `__complete commands|stack-branches|all-branches`, for the zsh
    /// completion. Silent and read-only: it runs on every Tab press.
    static func complete(_ ctx: StackContext, _ arguments: [String]) throws {
        ctx.quiet = true
        switch arguments.first {
        case "commands":
            ctx.console.print(commands.joined(separator: "\n"))
        case "stack-branches":
            for branch in try ctx.loadState().keys.sorted(by: StackJSON.codePointPrecedes) {
                ctx.console.print(branch)
            }
        case "all-branches":
            for branch in ctx.git.localBranches() { ctx.console.print(branch) }
        default:
            break
        }
    }

    /// The help page: commands, the symbol key, then the resolved settings.
    static func usage(_ ctx: StackContext) {
        let ui = ctx.ui
        usage(console: ctx.console, ui: ui, forgeKind: ctx.forgeKind)
        let ignored = ui.ignoredPendingChecks
        ctx.console.print("""

            Current config (resolved), set in Plume's Settings ▸ Projects (see `stack setup`):
              baseBranch           \(ctx.trunk)
              branchPrefix         \(ctx.branchPrefix.isEmpty ? "(none — no prefix)" : ctx.branchPrefix)
              forge                \(ctx.forgeKind.rawValue)
              nerdFont             \(ui.glyphSet == .nerd ? "yes" : "no") (\(ctx.nerdFontMode.rawValue), set in Settings ▸ Command line)
              ignoredPendingChecks \(ignored.isEmpty ? "(none)" : "\(ignored.count) check(s)")
            """)
    }

    /// The commands and the symbol key, for outside a repository too.
    static func usage(console: any CLIConsole, ui: TerminalUI, forgeKind: ForgeKind) {
        let b = ui.bold, r = ui.reset, d = ui.dim
        console.print("""
            \(b)stack\(r) — stacked-branch helper for a squash-merge PR/MR workflow (also `plume stack`)

            usage: \(b)stack <command> [args]\(r)

            Inspect
              \(b)list|l [--all] [--json] [--no-pr]\(r)
                    Show the current stack (--all: every stack). PR/MR info comes from
                    gh/glab when installed and authenticated; --no-pr skips the network.
              \(b)la\(r)    Shorthand for `list --all`.

            Build
              \(b)create|c <name> [--insert]\(r)
                    Create <name> on top of the current branch and switch to it
                    (uncommitted changes ride along). The current branch must be the
                    trunk or tracked. The branch prefix from Settings ▸ Projects is
                    prepended to <name>. --insert: existing children of the current
                    branch are reparented onto <name>.
              \(b)split <name>:<commit> [<name>:<commit> ...]\(r)
                    Split the current branch at commit boundaries, oldest first: each
                    <name> is created ending at <commit> (inclusive); the current branch
                    keeps the commits above the last boundary. Never rewrites history —
                    branches are planted at existing commits. New names get the branch
                    prefix. With no args on a TTY, pick boundaries interactively.
              \(b)track [<branch>] [--parent <p>]\(r)
                    Start tracking <branch> (default: current). Without --parent, any
                    untracked local branches whose tips sit between the trunk and
                    <branch> are tracked too, in ancestry order. --parent skips
                    discovery; on an already-tracked branch it moves the branch (and
                    its descendants) under <p>.
              \(b)untrack [<branch>]\(r)
                    Stop tracking (the git branch is untouched; children are reparented
                    onto its parent).

            Navigate (plain `git switch` — never creates or rewrites anything)
              \(b)checkout|co [<branch>]\(r)    Switch to a stack branch (picker without an arg).
              \(b)prev\(r)                      Parent branch (trunk when at the root).
              \(b)next\(r)                      Child branch (errors listing children if >1).
              \(b)first\(r)                     Root of the stack (closest to trunk).
              \(b)last\(r)                      Tip of the stack (errors if >1 leaf).

            Maintain
              \(b)restack [--all] [--trunk] [-i] [--dry-run]\(r)
                    Rebase the current branch and its ancestors (down to trunk) onto
                    their parents, parents first. Branches stacked above the current one
                    are left untouched — run restack from there when you're ready (they're
                    named in a note if they need it). --all does the whole stack tree
                    instead. By default the stack root is left where it sits relative to
                    trunk (being behind a fast-moving trunk isn't a restack). --trunk
                    also rebases the root onto the latest trunk. A root whose base has
                    fallen off trunk (squash-merged/rewritten) is moved onto trunk
                    regardless. -i (interactive) runs `git rebase -i` on just the current
                    branch's own commits — the git rebase todo editor, to drop/reorder/
                    squash/edit them — then heals the stored base so branches above it
                    restack cleanly onto the new tip (they're named in a note; -i can't be
                    combined with --all/--trunk/--dry-run). A branch whose last-fetched
                    origin/<branch> already holds that rebase (e.g. GitHub restacked it
                    after a parent merged) is moved there instead, keeping any unpushed
                    commits on top, so pushing it is a no-op. A branch checked out in
                    another clean worktree is rebased there. Local only — no fetch, no
                    forge. On a conflict: exits 3; resolve, `git rebase --continue`, then
                    re-run `stack restack` (it resumes where it stopped; `git rebase
                    --abort` backs out of the current step only).
              \(b)submit [--all] [--ready] [--dry-run]\(r)
                    Push the current branch and its ancestors (force-with-lease), create
                    PRs/MRs for branches that lack one (base = parent; DRAFT unless
                    --ready), and retarget existing open ones whose base is wrong.
                    Branches stacked above the current one are left untouched; --all
                    submits the whole stack tree. On GitHub repos with native stacked PRs
                    enabled, the chain is also registered as a GitHub stack (giving
                    reviewers the stack navigator in the PR UI) and extended as it grows;
                    a forking stack or one whose order disagrees with GitHub's is left
                    alone with a note. Best-effort — the PRs are unaffected if it fails.
              \(b)sync [--all] [--trunk] [--push] [--dry-run]\(r)
                    Fetch; start tracking local branches that have open PRs/MRs; absorb
                    squash-merged ones (delete the local branch, reparent children onto
                    its parent). Then restack — by default only the current branch and its
                    ancestors (down to trunk), leaving branches above it untouched (named
                    in a note); --all restacks every stack. Tracking and absorption always
                    scan every stack (they only add tracking or drop already-merged
                    branches).
                    As with `restack`, the stack root is left where it sits relative to
                    trunk unless --trunk is given; a root whose base has fallen off trunk
                    is moved regardless. With --push, also force-push and retarget bases
                    for the same scoped branches, skipping any already up to date on
                    origin, such as ones adopted from the remote (never creates PRs/MRs —
                    that's `submit`).

              \(b)setup\(r)                     Open Plume's Settings ▸ Projects.
              \(b)help\(r)                      Show this text.

            Exit codes: 0 ok · 1 error · 3 restack stopped on a rebase conflict

            State: .git/stack/branches.json (shared by all worktrees); stacks are trees
            derived from per-branch parent pointers.
            Trunk: the base branch from Settings ▸ Projects, else origin/HEAD, else main.
            PRs/MRs: GitHub via gh or GitLab via glab (detected from origin; Settings ▸
            Projects can set the forge for a self-hosted host). Local commands work
            without a forge. Settings live in Plume's Settings ▸ Projects, shared with
            `wt`; \(d)`.git/stack/github-stacks-enabled` caches whether the repository has
            native stacked PRs — delete it to re-probe.\(r)
            """)
        console.print()
        console.print(ui.glyphKey(
            forgeIcon: ui.forgeIcon(for: forgeKind),
            numberPrefix: forgeKind == .gitlab ? "!" : "#",
            extra: [
                GlyphKeyEntry(currentNodeGlyph, color: ui.bold + ui.cyan, "the current branch"),
                GlyphKeyEntry(nodeGlyph, "a branch or trunk commit"),
                GlyphKeyEntry(gap, "trunk commits elided between fork points"),
                GlyphKeyEntry(restackGlyph, color: ui.yellow, "needs restack, or behind trunk"),
                GlyphKeyEntry(stackGlyph(ui), color: ui.dim, "member of a GitHub native stack"),
            ]
        ).joined(separator: "\n"))
    }
}

nonisolated enum StackNavigation: String, Sendable {
    case prev
    case next
    case first
    case last
}
