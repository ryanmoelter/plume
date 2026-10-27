import Foundation

/// Every `wt` subcommand. Each takes the arguments after its name and fails
/// by throwing `CLIFailure`, which `WT.main` turns into the exit status.
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
        let currentIndex = currentRowIndex(ctx)
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
                rows, currentIndex: currentIndex, prState: resolved.state, prs: resolved.prs,
                paths: ctx.worktreePathsInListOrder(), trunkBranches: ctx.trunkBranches
            )
            ctx.console.print(payload.jsonString())
            return
        }

        let dirs = showPaths ? ctx.worktreePathsInListOrder().map { displayLocation($0, root: ctx.root) } : nil
        printListLive(
            rows, currentIndex: currentIndex, fetch: fetch, trunkBranches: ctx.trunkBranches,
            live: ctx.console.stdoutIsTerminal, dirs: dirs, ui: ctx.ui, console: ctx.console
        )
    }

    private struct CurrentPayload: Encodable {
        var worktree: String?
        var branch: String?
        var path: String?
        /// Nil only outside a repository.
        var root: String?
        var layout: WorktreeLayout?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeOrNull(worktree, forKey: .worktree)
            try container.encodeOrNull(branch, forKey: .branch)
            try container.encodeOrNull(path, forKey: .path)
            try container.encodeOrNull(root, forKey: .root)
            try container.encodeOrNull(layout, forKey: .layout)
        }

        private enum CodingKeys: String, CodingKey {
            case worktree, branch, path, root, layout
        }
    }

    /// Whether `arguments` (after `current`) ask for JSON, failing on an
    /// unknown flag.
    private static func currentWantsJSON(_ arguments: [String]) throws -> Bool {
        var asJSON = false
        for argument in arguments {
            guard argument == "--json" else { throw CLIFailure("current: unknown flag: \(argument)") }
            asJSON = true
        }
        return asJSON
    }

    /// `current --json` outside any repository: every field null, and
    /// success. False when `arguments` ask for something else.
    static func currentOutsideRepository(_ arguments: [String], console: any CLIConsole) -> Bool {
        guard (try? currentWantsJSON(arguments)) == true else { return false }
        console.print(jsonLine(CurrentPayload()))
        return true
    }

    /// `current [--json]`. Outside a worktree, `--json` reports null fields
    /// and succeeds: the Sublime status bar polls it for arbitrary files.
    static func current(_ ctx: any WTContext, _ arguments: [String]) throws {
        let asJSON = try currentWantsJSON(arguments)

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

    /// The tab flags `checkout`, `cob` and `background` share. `--surface`
    /// asks for the default, a tab, so it changes nothing; it stays accepted
    /// for scripts that pass it.
    private struct TabFlags {
        var openTab = true
        var asTask = false

        /// Consumes `argument` when it is a tab flag.
        mutating func take(_ argument: String, allowNoTab: Bool = true) -> Bool {
            switch argument {
            case "--no-tab" where allowNoTab: openTab = false
            case "--task", "--workspace": asTask = true
            case "--surface": break
            default: return false
            }
            return true
        }
    }

    /// The one positional argument, failing on a second or on an unknown flag.
    private static func takePositional(_ argument: String, into name: inout String) throws {
        if argument.hasPrefix("-") { throw CLIFailure("unknown flag: \(argument)") }
        if !name.isEmpty { throw CLIFailure("too many arguments") }
        name = argument
    }

    private static func isYes(_ reply: String) -> Bool {
        ["y", "Y", "yes", "YES"].contains(reply.trimmingCharacters(in: .whitespaces))
    }

    /// A prompt's answer; end of input aborts the command, as Ctrl-D should.
    private static func readReply(_ ctx: any WTContext, _ prompt: String) throws -> String {
        guard let reply = ctx.console.readLine(prompt: prompt) else { throw CLIFailure(nil) }
        return reply
    }

    /// `checkout|co [-b] <branch> [--no-tab|--task]`, and `cob` with
    /// `create`. Without `-b`, an existing branch is matched exactly or by a
    /// unique `/<branch>` suffix; with it, the configured prefix is added
    /// unless the name already has it.
    static func checkout(_ ctx: any WTContext, _ arguments: [String], create: Bool = false) throws {
        var create = create
        var tabs = TabFlags()
        var name = ""
        for argument in arguments {
            if argument == "-b" {
                create = true
            } else if !tabs.take(argument) {
                try takePositional(argument, into: &name)
            }
        }
        if name.isEmpty {
            throw CLIFailure(create
                ? "checkout: branch name required (e.g. `wt co -b my-feature`)"
                : "checkout: branch name required (e.g. `wt co some-branch`, or `wt co -b` to create)")
        }

        let branch: String
        if create {
            branch = try branchFor(ctx, name)
        } else {
            branch = try resolveBranch(ctx, name)
            if branch != name { ctx.console.print("\(programName): matched \(name) → \(branch)") }
        }
        let folder = folderForBranch(branch)
        let path = "\(ctx.newWorktreesDirectory)/\(folder)"
        if ctx.worktreeExists(folder) {
            throw CLIFailure("worktree already exists: \(ctx.describeExisting(folder))")
        }
        try ctx.ensureWorktreesDirectory()

        if create {
            if ctx.git.branchExists(branch) {
                throw CLIFailure("branch already exists: \(branch) (use `wt co \(branch)` to check it out)")
            }
            ctx.console.print("\(programName): fetching \(ctx.baseRef)...")
            try ctx.git.fetchBase(ctx.baseBranch, quiet: false)
            try ctx.git.worktreeAdd(path: path, branch: branch, new: true, baseRef: ctx.baseRef, fatal: true)
            ctx.console.print("\(programName): created \(path) (\(branch))")
        } else {
            // Git refuses a branch already checked out elsewhere.
            try ctx.git.worktreeAdd(path: path, branch: branch, new: false, baseRef: nil, fatal: true)
            ctx.console.print("\(programName): created \(path) (checked out \(branch))")
        }
        ctx.git.enableUntrackedCache(path)
        if tabs.openTab { ctx.tabs.open(path, asTask: tabs.asTask) }
    }

    /// `open|o <name> [--task]`.
    static func open(_ ctx: any WTContext, _ arguments: [String]) throws {
        var tabs = TabFlags()
        var name = ""
        for argument in arguments where !tabs.take(argument, allowNoTab: false) {
            try takePositional(argument, into: &name)
        }
        ctx.tabs.open(try ctx.worktreePath(name), asTask: tabs.asTask)
    }

    /// `background|bg [name] [--no-tab|--task]`: moves the current branch and
    /// its uncommitted work to a new worktree, leaving the current one on the
    /// base branch.
    static func background(_ ctx: any WTContext, _ arguments: [String]) throws {
        var tabs = TabFlags()
        var name = ""
        for argument in arguments where !tabs.take(argument) {
            try takePositional(argument, into: &name)
        }

        let cwdPath = try ctx.currentWorktreePath()
        let cwdName = (cwdPath as NSString).lastPathComponent
        let originalBranch = try ctx.git.branchOf(cwdPath)
        // `worktree add` resolves `HEAD` in the repository, not here, so a
        // detached move would take some other worktree's commit.
        if originalBranch == "HEAD" {
            throw CLIFailure("\(cwdName) is detached — check out a branch first (or use `wt co -b`)")
        }
        let clean = try ctx.git.isClean(cwdPath)
        let onBase = originalBranch == ctx.baseBranch
        if clean, onBase {
            throw CLIFailure("nothing to move: \(cwdName) is clean and on \(ctx.baseBranch) (use `wt co -b` instead)")
        }

        let prefix = try branchPrefix(ctx)
        if name.isEmpty { name = folderForBranch(originalBranch) }
        let newBranch = try branchFor(ctx, name, prefix: prefix)
        let newFolder = folderForBranch(newBranch)
        let newPath = "\(ctx.newWorktreesDirectory)/\(newFolder)"
        if ctx.worktreeExists(newFolder) {
            throw CLIFailure("worktree already exists: \(ctx.describeExisting(newFolder)) (pass a different name: `wt bg <name>`)")
        }
        if onBase, ctx.git.branchExists(newBranch) { throw CLIFailure("branch already exists: \(newBranch)") }
        try ctx.ensureWorktreesDirectory()

        // Every check that can refuse has run: from here on, a failure must
        // hand the stash back.
        var stash: String?
        if !clean {
            ctx.console.print("\(programName): stashing changes in \(cwdName)...")
            stash = try ctx.git.stashPush(cwdPath, message: "wt move from \(cwdName) \(Int(Date().timeIntervalSince1970))")
        }
        func restoreStash(in path: String, silent: Bool) -> Bool {
            stash.map { ctx.git.stashRestoreOK(path, sha: $0, silent: silent) } ?? true
        }
        func failureRestoringStash(_ what: String) -> CLIFailure {
            guard let stash else { return CLIFailure(what) }
            if restoreStash(in: cwdPath, silent: true) { return CLIFailure("\(what); changes restored in \(cwdName)") }
            return CLIFailure("\(what); \(stashKeptNote(stash))")
        }

        var unfinished: String?
        if !onBase {
            ctx.console.print("\(programName): moving \(originalBranch) out of \(cwdName)...")
            // Detached first, so the branch is free to check out elsewhere.
            do {
                try ctx.git.checkoutFatal(cwdPath, ref: originalBranch, detach: true, quietStdout: true)
            } catch {
                throw failureRestoringStash("could not detach \(cwdName)")
            }
            if !((try? ctx.git.worktreeAdd(path: newPath, branch: originalBranch, new: false, baseRef: nil, fatal: false)) ?? false) {
                let reattached = ctx.git.checkoutOK(cwdPath, ref: originalBranch, detach: false, silent: true)
                let popped = restoreStash(in: cwdPath, silent: true)
                let stashNote = popped ? nil : stash.map(stashKeptNote)
                switch (reattached, stashNote) {
                case (true, nil):
                    throw CLIFailure("failed to create new worktree; state restored in \(cwdName)")
                case let (true, note?):
                    throw CLIFailure("failed to create new worktree; branch reattached in \(cwdName), but \(note)")
                case (false, nil):
                    throw CLIFailure("failed to create new worktree; reattach of \(originalBranch) failed — \(cwdName) is left detached")
                case let (false, note?):
                    throw CLIFailure("failed to create new worktree AND recovery failed: \(cwdName) is left detached, and \(note)")
                }
            }
            // The base branch may be checked out in another worktree, which
            // leaves only a detached checkout of the base ref. A quiet fetch
            // that fails leaves the last fetched base, which still serves.
            try? ctx.git.fetchBase(ctx.baseBranch, quiet: true)
            if ctx.git.checkoutOK(cwdPath, ref: ctx.baseBranch, detach: false, silent: true) {
                ctx.console.print("\(programName): \(cwdName) now on \(ctx.baseBranch)")
            } else if ctx.git.checkoutOK(cwdPath, ref: ctx.baseRef, detach: true, silent: false) {
                ctx.console.print("\(programName): \(cwdName) now at \(ctx.baseRef) (detached; \(ctx.baseBranch) is checked out elsewhere)")
            } else {
                // The branch already lives in the new worktree, so its
                // changes still go there.
                unfinished = "could not check out \(ctx.baseBranch) or \(ctx.baseRef) in \(cwdName); it is left detached at \(originalBranch)'s commit"
            }
        } else {
            ctx.console.print("\(programName): creating new branch for moved changes...")
            try? ctx.git.fetchBase(ctx.baseBranch, quiet: true)
            if !((try? ctx.git.worktreeAdd(path: newPath, branch: newBranch, new: true, baseRef: ctx.baseRef, fatal: false)) ?? false) {
                throw failureRestoringStash("failed to create new worktree")
            }
        }

        if let stash {
            ctx.console.print("\(programName): restoring changes in \(newFolder)...")
            if !restoreStash(in: newPath, silent: false) {
                ctx.console.printError("\(programName): stash apply had conflicts in \(newPath); \(stashKeptNote(stash))")
            }
        }
        ctx.console.print("\(programName): moved to \(newPath)")
        ctx.git.enableUntrackedCache(newPath)
        if tabs.openTab { ctx.tabs.open(newPath, asTask: tabs.asTask) }
        if let unfinished { throw CLIFailure(unfinished) }
    }

    /// Where a stash that could not be restored is, and how to get it back.
    /// By SHA, since other processes push to the same stash list.
    private static func stashKeptNote(_ sha: String) -> String {
        "the changes are still stashed as \(sha) — apply them with `git stash apply \(sha)`"
    }

    /// `foreground|fg <name>`: takes another worktree's branch and changes
    /// into the current one, then removes it.
    static func foreground(_ ctx: any WTContext, _ arguments: [String]) throws {
        guard let name = arguments.first, !name.isEmpty else { throw CLIFailure("foreground: worktree name required") }

        let cwdPath = try ctx.currentWorktreePath()
        let cwdName = (cwdPath as NSString).lastPathComponent
        let sourcePath = try ctx.worktreePath(name)
        if cwdPath == sourcePath { throw CLIFailure("checkout: that's the current worktree") }
        if ctx.protected.contains(name) { throw CLIFailure("refusing to consume protected worktree: \(name)") }
        if try !ctx.git.isClean(cwdPath) { throw CLIFailure("current worktree (\(cwdName)) has uncommitted changes") }

        let sourceBranch = try ctx.git.branchOf(sourcePath)
        // Its commits are reachable from no branch, so removing it would
        // orphan them.
        if sourceBranch == "HEAD" {
            throw CLIFailure("\(name) is detached — nothing to move (check out a branch in it first)")
        }
        var stash: String?
        if try !ctx.git.isClean(sourcePath) {
            ctx.console.print("\(programName): stashing changes in \(name)...")
            stash = try ctx.git.stashPush(sourcePath, message: "wt checkout from \(name) \(Int(Date().timeIntervalSince1970))")
        }
        func restoreStash(in path: String, silent: Bool) -> Bool {
            stash.map { ctx.git.stashRestoreOK(path, sha: $0, silent: silent) } ?? true
        }

        // The source is detached first, which is reversible, and removed
        // only once the checkout here succeeds.
        do {
            try ctx.git.checkoutFatal(sourcePath, ref: sourceBranch, detach: true, quietStdout: false)
        } catch {
            guard let stash else { throw CLIFailure("could not detach \(name)") }
            if restoreStash(in: sourcePath, silent: true) { throw CLIFailure("could not detach \(name); changes restored there") }
            throw CLIFailure("could not detach \(name); \(stashKeptNote(stash))")
        }
        if !ctx.git.checkoutOK(cwdPath, ref: sourceBranch, detach: false, silent: false) {
            let reattached = ctx.git.checkoutOK(sourcePath, ref: sourceBranch, detach: false, silent: true)
            let popped = restoreStash(in: sourcePath, silent: true)
            let stashNote = popped ? nil : stash.map(stashKeptNote)
            switch (reattached, stashNote) {
            case (true, nil):
                throw CLIFailure("checkout \(sourceBranch) failed; source worktree \(name) left intact")
            case let (true, note?):
                throw CLIFailure("checkout \(sourceBranch) failed; source worktree \(name) left intact, but \(note)")
            case (false, nil):
                throw CLIFailure("checkout \(sourceBranch) failed; reattach in \(name) also failed — \(name) is left detached")
            case let (false, note?):
                throw CLIFailure("checkout \(sourceBranch) failed AND recovery failed: \(name) is left detached, and \(note)")
            }
        }

        if let stash {
            ctx.console.print("\(programName): restoring changes in \(cwdName)...")
            if !restoreStash(in: cwdPath, silent: false) {
                ctx.console.printError("\(programName): stash apply had conflicts in \(cwdPath); \(stashKeptNote(stash))")
            }
        }
        // The branch and its changes are already here, so a source git
        // refuses to remove costs nothing but a leftover folder.
        do {
            try ctx.git.worktreeRemove(path: sourcePath, force: false)
        } catch {
            throw CLIFailure("checked out \(sourceBranch) in \(cwdName), but could not remove \(name) (left detached at \(sourcePath))")
        }
        ctx.console.print("\(programName): checked out \(sourceBranch) in \(cwdName) (removed \(name))")
    }

    /// `delete|d <name> [-f|--force]`. The branch stays.
    static func delete(_ ctx: any WTContext, _ arguments: [String]) throws {
        var force = false
        var name = ""
        for argument in arguments {
            if argument == "-f" || argument == "--force" {
                force = true
            } else {
                try takePositional(argument, into: &name)
            }
        }
        if name.isEmpty { throw CLIFailure("worktree name required") }
        if ctx.protected.contains(name) { throw CLIFailure("refusing to delete protected worktree: \(name)") }

        let path = try ctx.worktreePath(name)
        let branch = try ctx.git.branchOf(path)
        if !force, try !ctx.git.isClean(path) { throw CLIFailure("\(name) has uncommitted changes (use -f to force)") }
        try ctx.git.worktreeRemove(path: path, force: force)
        ctx.console.print("\(programName): deleted worktree \(name) (branch \(branch) left intact)")
    }

    /// How long `prune` waits on the forge. Pruning is deliberate, so it
    /// waits far longer than a listing.
    static let prunePRWait: TimeInterval = 30

    /// `prune|p [-y|--yes]`: merged or closed worktrees with their branches,
    /// then merged branches that have no worktree.
    static func prune(_ ctx: any WTContext, _ arguments: [String]) throws {
        var autoYes = false
        for argument in arguments {
            guard argument == "-y" || argument == "--yes" else { throw CLIFailure("unknown flag: \(argument)") }
            autoYes = true
        }

        // A squash merge leaves no local trace, so without PR state prune
        // finds fewer branches, never wrong ones.
        var prs: PullRequestMap = [:]
        var numberPrefix = "#"
        var forgeIcon: String?
        if let fetch = ctx.startPRFetch(allBranches: true) {
            numberPrefix = fetch.numberPrefix
            forgeIcon = fetch.forgeIcon
            _ = fetch.completion.wait(timeout: prunePRWait)
            if let fetched = fetch.completion.result {
                prs = fetched
            } else {
                ctx.console.printError("\(programName): could not fetch PR/MR status — only locally merged branches will be found")
            }
        } else {
            ctx.console.printError("\(programName): no PR/MR status (no forge configured or gh/glab missing) — only locally merged branches will be found")
        }

        try ctx.git.fetchBase(ctx.baseBranch, quiet: true)
        let baseRef = ctx.git.refExists(GitRef.origin(ctx.baseBranch)) ? GitRef.origin(ctx.baseBranch) : GitRef.local(ctx.baseBranch)
        let locallyMerged = { (branch: String) in isMergedLocally(ctx.git, branch: branch, baseRef: baseRef) }
        let withinPRHead = { (branch: String, headOid: String) in isWithinPRHead(ctx.git, branch: branch, headOid: headOid) }

        let records = ctx.git.worktreeRecords()
        let candidates = pruneCandidates(
            records: records, prs: prs, protected: ctx.protected, cwdName: ctx.currentWorktreeNameOrNone(),
            baseBranch: ctx.baseBranch, locallyMerged: locallyMerged, withinPRHead: withinPRHead
        )
        func chip(_ pr: PullRequest?) -> String {
            pr.map { ctx.ui.prChip($0, numberPrefix: numberPrefix, forgeIcon: forgeIcon).text } ?? ""
        }

        var deletedBranches: Set<String> = []
        var skipped: [String] = []
        var failed: [String] = []
        for candidate in candidates {
            let prChip = chip(candidate.pr)
            if let note = candidate.skipNote {
                ctx.console.print("  skip \(candidate.name)  \(prChip)  (\(note))")
                continue
            }
            let clean: Bool
            do {
                clean = try ctx.git.isClean(candidate.path)
            } catch {
                ctx.console.printError("\(programName): skip \(candidate.name): could not read its status at \(candidate.path)")
                continue
            }
            if !clean {
                skipped.append(candidate.name)
                ctx.console.print("  skip \(candidate.name)  \(prChip)  (uncommitted changes)")
                continue
            }
            if !autoYes {
                let reply = try readReply(ctx, "  delete \(candidate.name) (\(candidate.branch))  \(prChip) \(candidate.reason)? [y/N]> ")
                if !isYes(reply) { continue }
            }
            // One worktree git refuses to remove shouldn't abandon the rest.
            do {
                try ctx.git.worktreeRemove(path: candidate.path, force: false)
            } catch {
                failed.append(candidate.name)
                ctx.console.printError("\(programName): could not remove worktree \(candidate.name) at \(candidate.path); skipping it")
                continue
            }
            do {
                try ctx.git.branchDelete(candidate.branch, force: true)
            } catch {
                failed.append(candidate.branch)
                ctx.console.printError("\(programName): deleted worktree \(candidate.name), but could not delete branch \(candidate.branch)")
                continue
            }
            deletedBranches.insert(candidate.branch)
            ctx.console.print("\(programName): deleted worktree \(candidate.name) and branch \(candidate.branch)")
        }
        if !skipped.isEmpty {
            ctx.console.print("\(programName): skipped (uncommitted changes): \(skipped.joined(separator: ", "))")
        }

        // A branch whose worktree is gone, or never existed, is invisible to
        // the pass above.
        let currentBranch = try ctx.currentWorktree().map { try ctx.git.branchOf($0.path) }
        let bare = bareBranchCandidates(
            branches: ctx.git.localBranches(),
            worktreeBranches: records.map(\.branch).filter { !deletedBranches.contains($0) },
            prs: prs, currentBranch: currentBranch, trunkBranches: ctx.trunkBranches,
            baseBranch: ctx.baseBranch, locallyMerged: locallyMerged, withinPRHead: withinPRHead
        )
        if candidates.isEmpty, bare.isEmpty {
            ctx.console.print("\(programName): nothing to prune")
            return
        }
        for candidate in bare {
            if let note = candidate.skipNote {
                ctx.console.print("  skip branch \(candidate.branch)  \(chip(candidate.pr))  (\(note))")
                continue
            }
            if !autoYes {
                let reply = try readReply(ctx, "  delete branch \(candidate.branch)  \(chip(candidate.pr)) \(candidate.reason)? [y/N]> ")
                if !isYes(reply) { continue }
            }
            if ctx.git.branchDeleteOK(candidate.branch, force: true) {
                ctx.console.print("\(programName): deleted branch \(candidate.branch)")
            } else {
                failed.append(candidate.branch)
                ctx.console.printError("\(programName): could not delete branch \(candidate.branch); skipping it")
            }
        }
        if !failed.isEmpty {
            throw CLIFailure("could not prune: \(failed.joined(separator: ", "))")
        }
    }

    /// `rename|r [name] <new> [-f|--folder]`. The folder moves first, so a
    /// failure leaves the branch name unchanged and easy to retry.
    static func rename(_ ctx: any WTContext, _ arguments: [String]) throws {
        var renameFolder = false
        var positional: [String] = []
        for argument in arguments {
            if argument == "-f" || argument == "--folder" {
                renameFolder = true
            } else if argument.hasPrefix("-") {
                throw CLIFailure("unknown flag: \(argument)")
            } else {
                positional.append(argument)
            }
        }

        let targetName: String
        let newName: String
        switch positional.count {
        case 1: (targetName, newName) = (try ctx.currentWorktreeName(), positional[0])
        case 2: (targetName, newName) = (positional[0], positional[1])
        default: throw CLIFailure("rename: usage: wt rename [name] <new-name> [-f|--folder]")
        }
        if ctx.protected.contains(targetName) { throw CLIFailure("refusing to rename protected worktree: \(targetName)") }

        var oldPath = try ctx.worktreePath(targetName)
        let oldBranch = try ctx.git.branchOf(oldPath)
        let detached = oldBranch == "HEAD"
        let newBranch = try branchFor(ctx, newName)
        let newFolder = folderForBranch(newBranch)
        let newPath = "\(ctx.newWorktreesDirectory)/\(newFolder)"

        if detached, !renameFolder {
            throw CLIFailure("\(targetName) is detached — nothing to rename (pass -f to move its folder)")
        }
        if !detached {
            if oldBranch == newBranch { throw CLIFailure("branch is already \(oldBranch)") }
            if ctx.git.branchExists(newBranch) { throw CLIFailure("branch already exists: \(newBranch)") }
        }

        if renameFolder, oldPath != newPath {
            if ctx.worktreeExists(newFolder) { throw CLIFailure("worktree already exists: \(ctx.describeExisting(newFolder))") }
            try ctx.git.worktreeMove(from: oldPath, to: newPath)
            ctx.console.print("\(programName): moved worktree folder → \(newPath)")
            oldPath = newPath
        }
        if detached { return }
        try ctx.git.branchMove(oldPath, from: oldBranch, to: newBranch)
        ctx.console.print("\(programName): renamed branch \(oldBranch) → \(newBranch)")
    }

    /// `commit|cm <name> [git-args]`: `git commit -a` in another worktree,
    /// exiting with git's status.
    static func commit(_ ctx: any WTContext, _ arguments: [String]) throws {
        guard let name = arguments.first, !name.isEmpty else {
            throw CLIFailure("commit: worktree name required (use plain `git commit` for the current one)")
        }
        let status = ctx.git.commitAll(try ctx.worktreePath(name), extraArguments: Array(arguments.dropFirst()))
        if status != 0 { throw CLIFailure(nil, code: status) }
    }

    /// A worktree's path by name, else the worktree with that branch out.
    private static func resolvePath(_ ctx: any WTContext, _ name: String) throws -> String {
        if ctx.worktreeExists(name) { return try ctx.worktreePath(name) }
        if let branchPath = pathForBranch(ctx, name) { return branchPath }
        throw CLIFailure("no worktree or checked-out branch matching: \(name)")
    }

    /// `path <name|branch>`: prints the path, preferring a worktree name over
    /// a checked-out branch.
    static func path(_ ctx: any WTContext, _ arguments: [String]) throws {
        guard let name = arguments.first, !name.isEmpty else {
            throw CLIFailure("path: worktree name or branch required")
        }
        ctx.console.print(try resolvePath(ctx, name))
    }

    /// `switch|s <name|branch>`. The `plume init zsh` wrapper turns this into
    /// a `cd`, so reaching the binary means the wrapper is absent: inside
    /// Plume it opens a tab there, otherwise it fails naming the wrapper.
    static func switchTo(_ ctx: any WTContext, _ arguments: [String]) throws {
        guard ctx.tabs.canOpenTabs else {
            throw CLIFailure("""
                switch needs a shell wrapper to cd this shell, which a subprocess cannot do. Add to ~/.zshrc:

                  eval "$(plume init zsh --aliases)"

                That wraps `plume wt switch`; `--aliases` also defines a bare `wt` that goes
                through the wrapper, so leave it off if you only run `plume wt`. Then reload.
                For a plain path (scripts, other shells), use `plume wt path`.
                """)
        }
        guard let name = arguments.first, !name.isEmpty else {
            throw CLIFailure("switch: worktree name or branch required")
        }
        ctx.tabs.open(try resolvePath(ctx, name), asTask: false)
    }

    /// `setup`: opens Settings ▸ Projects when Plume runs, else says where
    /// the settings live.
    static func setup(_ ctx: any WTContext, _ arguments: [String]) throws {
        if !arguments.isEmpty { throw CLIFailure("setup: takes no arguments") }
        if ctx.tabs.openSettings(section: "projects") {
            ctx.console.print("\(programName): opened Plume's Settings ▸ Projects")
            return
        }
        ctx.console.print("""
            \(programName): project settings live in Plume's Settings ▸ Projects, for every
            repository and per repository. Open Plume and choose Settings ▸ Projects,
            then re-run `wt help` to see the resolved values.
            """)
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
        usage(console: ctx.console, ui: ui)

        let prefix: String
        switch ctx.branchPrefixResolution() {
        case nil: prefix = "(unset: git user.email missing)"
        case ""?: prefix = "(none — no prefix)"
        case let resolved?: prefix = resolved
        }
        let kind = ctx.forgeKind
        let ignored = ui.ignoredPendingChecks
        let untrackedCache = ctx.git.configGet("core.untrackedCache") ?? ""

        ctx.console.print()
        ctx.console.print(ui.glyphKey(forgeIcon: ui.forgeIcon(for: kind), numberPrefix: kind == .gitlab ? "!" : "#").joined(separator: "\n"))
        ctx.console.print("""

        Current config (resolved), set in Plume's Settings ▸ Projects (see `wt setup`):
          baseBranch           \(ctx.baseBranch)
          branchPrefix         \(prefix)
          forge                \(kind.rawValue)
          nerdFont             \(ui.glyphSet == .nerd ? "yes" : "no") (\(ctx.nerdFontMode.rawValue), set in Settings ▸ Command line)
          protectedWorktrees   \(ctx.protected.isEmpty ? "(none)" : ctx.protected.joined(separator: ", "))
          ignoredPendingChecks \(ignored.isEmpty ? "(none)" : "\(ignored.count) check(s)")
          core.untrackedCache  \(untrackedCache.isEmpty ? "(unset — `git config core.untrackedCache true` speeds up `wt list`)" : untrackedCache)
        """)
    }

    /// Only the commands, for outside a repository, where there are no
    /// settings to resolve.
    static func usage(console: any CLIConsole, ui: TerminalUI) {
        let b = ui.bold, r = ui.reset, d = ui.dim
        console.print("""
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
    }
}
