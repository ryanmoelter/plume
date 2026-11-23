import Foundation

/// Every local branch tip and the stack state, recorded before a command
/// that moves refs, so `stack undo` can put them back.
nonisolated struct StackUndoSnapshot: Equatable, Sendable {
    /// The file name without `.json`; sorts oldest first.
    var id: String
    var command: String
    var created: Date
    /// The worktree the command ran in, whose checkout `undo` restores.
    var worktree: String
    var current: String?
    /// Every local branch, not just tracked ones: a command such as `sync`
    /// can track a branch and then move it.
    var tips: [String: String]
    var state: StackBranches
    /// Restoring touches neither the index nor the working tree: the
    /// checked-out branch moves with `reset --soft` and the checkout with
    /// `symbolic-ref`, so changes the command committed from the tree
    /// (`absorb`, `split --hunks`) come back staged.
    var keepsIndex = false
    /// The branch the command left checked out, recorded once it finishes.
    /// An index-keeping restore is only right from that checkout, since it
    /// keeps whatever index it finds.
    var leftOn: String?
}

nonisolated enum StackUndoCodec {
    static let currentVersion = 1

    static func encode(_ snapshot: StackUndoSnapshot) throws -> String {
        let state = try StackJSON.parse(Data(StackStateCodec.encode(snapshot.state).utf8))
        let document = StackJSON.object([
            StackJSONMember("version", .int(currentVersion)),
            StackJSONMember("command", .string(snapshot.command)),
            StackJSONMember("created", .string(timestampFormatter().string(from: snapshot.created))),
            StackJSONMember("worktree", .string(snapshot.worktree)),
            StackJSONMember("current", snapshot.current.map(StackJSON.string) ?? .null),
            StackJSONMember("tips", .object(snapshot.tips.map { StackJSONMember($0.key, .string($0.value)) })),
            StackJSONMember("state", state),
        ] + (snapshot.keepsIndex ? [StackJSONMember("keepsIndex", .bool(true))] : [])
            + (snapshot.leftOn.map { [StackJSONMember("leftOn", .string($0))] } ?? []))
        return document.rendered(sortKeys: true) + "\n"
    }

    static func decode(_ data: Data, id: String) throws -> StackUndoSnapshot {
        let document = try StackJSON.parse(data)
        guard case .int(let version)? = document["version"], version <= currentVersion,
              case .string(let command)? = document["command"],
              case .string(let createdText)? = document["created"],
              let created = timestampFormatter().date(from: createdText),
              case .string(let worktree)? = document["worktree"],
              case .object(let tipMembers)? = document["tips"],
              let stateDocument = document["state"]
        else { throw CLIFailure("unreadable undo snapshot \(id)") }
        var tips: [String: String] = [:]
        for member in tipMembers {
            guard case .string(let sha) = member.value else { throw CLIFailure("unreadable undo snapshot \(id)") }
            tips[member.key] = sha
        }
        var state: StackBranches = [:]
        for record in try StackStateCodec.decode(Data(stateDocument.rendered().utf8)) where state[record.name] == nil {
            state[record.name] = record.entry
        }
        let current: String? = if case .string(let name)? = document["current"] { name } else { nil }
        let leftOn: String? = if case .string(let name)? = document["leftOn"] { name } else { nil }
        return StackUndoSnapshot(
            id: id, command: command, created: created, worktree: worktree, current: current, tips: tips, state: state,
            keepsIndex: document["keepsIndex"] == .bool(true), leftOn: leftOn
        )
    }

    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

/// `<state directory>/undo`, one file per snapshot. A subdirectory, because
/// the state store merges every `*.json` beside `branches.json`.
nonisolated struct StackUndoStore {
    static let retained = 20

    let directory: String

    /// Newest first; unreadable files are skipped.
    func list() -> [StackUndoSnapshot] {
        ids().compactMap { id in
            guard let data = FileManager.default.contents(atPath: path(id)) else { return nil }
            return try? StackUndoCodec.decode(data, id: id)
        }
    }

    /// Writes `snapshot` under a fresh id, drops all but the newest
    /// `retained`, and returns the id.
    @discardableResult
    func save(_ snapshot: StackUndoSnapshot) throws -> String {
        let manager = FileManager.default
        try manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let stem = Self.idFormatter().string(from: snapshot.created)
        var counter = 0
        var id: String { "\(stem)-\(String(format: "%03d", counter))" }
        while manager.fileExists(atPath: path(id)) { counter += 1 }
        var stored = snapshot
        stored.id = id
        try StackUndoCodec.encode(stored).write(toFile: path(id), atomically: true, encoding: .utf8)
        for old in ids().dropFirst(Self.retained) { remove(old) }
        return stored.id
    }

    /// Newest first. The fixed-width counter keeps two snapshots from the
    /// same millisecond in order.
    private func ids() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted { StackJSON.codePointPrecedes($1, $0) }
    }

    func replace(_ snapshot: StackUndoSnapshot) throws {
        try StackUndoCodec.encode(snapshot).write(toFile: path(snapshot.id), atomically: true, encoding: .utf8)
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(atPath: path(id))
    }

    private func path(_ id: String) -> String { "\(directory)/\(id).json" }

    private static func idFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }
}

/// What restoring a snapshot does to the branches.
nonisolated enum StackUndoChange: Equatable, Sendable {
    case move(branch: String, from: String, to: String)
    case create(branch: String, at: String)
    case delete(branch: String, at: String)

    var branch: String {
        switch self {
        case .move(let branch, _, _), .create(let branch, _), .delete(let branch, _): branch
        }
    }

    /// The tip the branch ends with, or nil when it is deleted.
    var target: String? {
        switch self {
        case .move(_, _, let to): to
        case .create(_, let at): at
        case .delete: nil
        }
    }

    static func plan(_ snapshot: StackUndoSnapshot, state: StackBranches, tips: [String: String]) -> [StackUndoChange] {
        let involved = Set(snapshot.state.keys).union(state.keys)
        return involved.sorted(by: StackJSON.codePointPrecedes).compactMap { branch in
            switch (snapshot.tips[branch], tips[branch]) {
            case let (then?, now?) where then != now: .move(branch: branch, from: now, to: then)
            case let (then?, nil): .create(branch: branch, at: then)
            case let (nil, now?): .delete(branch: branch, at: now)
            default: nil
            }
        }
    }
}

nonisolated extension StackContext {
    var undoStore: StackUndoStore { StackUndoStore(directory: "\(state.directory)/undo") }

    func localTips() throws -> [String: String] {
        var tips: [String: String] = [:]
        for line in try git.git("for-each-ref", "refs/heads", "--format=%(objectname) %(refname:lstrip=2)").split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            tips[String(line[line.index(after: space)...])] = String(line[..<space])
        }
        return tips
    }

    /// Records the branches and `branches` before a command moves refs. The
    /// caller holds the state lock, and passes the result to
    /// `finishUndo` once the command succeeds.
    func recordUndo(_ command: String, _ branches: StackBranches, keepsIndex: Bool = false) throws -> StackUndoSnapshot {
        var snapshot = StackUndoSnapshot(
            id: "",
            command: command,
            created: Date(),
            worktree: try git.git("rev-parse", "--show-toplevel"),
            current: git.currentBranch(),
            tips: try localTips(),
            state: branches,
            keepsIndex: keepsIndex
        )
        do {
            snapshot.id = try undoStore.save(snapshot)
        } catch let failure as CLIFailure {
            throw failure
        } catch {
            throw CLIFailure("could not record an undo snapshot in \(undoStore.directory): \(error.localizedDescription)")
        }
        return snapshot
    }

    /// Runs `body`, finishing `snapshot` when it throws, so a failed command
    /// leaves no no-op snapshot ahead of the real previous one. A conflict
    /// stop keeps it: the stopped rebase moves the branch only later.
    func guardingUndo<T>(_ snapshot: StackUndoSnapshot, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            if (error as? CLIFailure)?.code != Stack.conflictExitCode, let state = try? loadState() {
                try? finishUndo(snapshot, state)
            }
            throw error
        }
    }

    /// Drops a snapshot whose command changed nothing, so `undo` never
    /// restores a no-op, and records where an index-keeping one left the
    /// checkout.
    func finishUndo(_ snapshot: StackUndoSnapshot, _ branches: StackBranches) throws {
        let changes = StackUndoChange.plan(snapshot, state: branches, tips: try localTips())
        if changes.isEmpty, snapshot.state == branches {
            undoStore.remove(snapshot.id)
        } else if snapshot.keepsIndex {
            var finished = snapshot
            finished.leftOn = git.currentBranch()
            try undoStore.replace(finished)
        }
    }
}

nonisolated extension Stack {
    static func undoLabel(_ command: String, _ arguments: [String]) -> String {
        ([command] + arguments).joined(separator: " ")
    }

    static func undo(_ ctx: StackContext, _ arguments: [String]) throws {
        var listing = false
        var dryRun = false
        var number: Int?
        for argument in arguments {
            switch argument {
            case "--list": listing = true
            case "--dry-run": dryRun = true
            default:
                guard number == nil, let value = Int(argument), value >= 1 else {
                    throw CLIFailure(argument.hasPrefix("-") ? "unknown flag: \(argument)" : "usage: stack undo [<n>] [--list] [--dry-run]")
                }
                number = value
            }
        }
        let snapshots = ctx.undoStore.list()
        if snapshots.isEmpty { throw CLIFailure("nothing to undo — no snapshots in \(ctx.undoStore.directory)") }
        let rows = snapshots.enumerated().map { index, snapshot in
            (value: String(index + 1), display: describe(snapshot, number: index + 1))
        }
        let chosen: StackUndoSnapshot
        if let number {
            guard number <= snapshots.count else { throw CLIFailure("no snapshot \(number) — `stack undo --list` shows \(snapshots.count)") }
            chosen = snapshots[number - 1]
        } else if listing {
            guard ctx.console.stdinIsTerminal, ctx.console.stdoutIsTerminal else {
                ctx.console.print("snapshots, newest first (restore one with `stack undo <n>`):")
                for row in rows { ctx.console.print(row.display) }
                return
            }
            chosen = snapshots[Int(try pick(ctx, rows, what: "snapshot"))! - 1]
        } else {
            chosen = snapshots[0]
        }
        if !dryRun {
            if chosen.keepsIndex {
                if ctx.git.currentBranch() == nil { throw CLIFailure("detached HEAD — check out a branch first") }
                if try rebaseInProgress(ctx) {
                    throw CLIFailure("a rebase is in progress — `git rebase --continue` or `git rebase --abort` first")
                }
            } else {
                try restackPreflight(ctx)
            }
        }
        try ctx.state.withLock {
            let branches = try ctx.loadAndFlushLocked()
            let changes = StackUndoChange.plan(chosen, state: branches, tips: try ctx.localTips())
            ctx.console.print("\(dryRun ? "would restore" : "restoring") the state from before `stack \(chosen.command)` (\(formatted(chosen.created)))")
            if dryRun {
                for change in changes { ctx.console.print("  " + describe(change, dryRun: true)) }
                if changes.isEmpty { ctx.console.print("  (no branch moves)") }
                return
            }
            let here = try ctx.git.git("rev-parse", "--show-toplevel")
            if chosen.keepsIndex {
                let leftOn = chosen.leftOn ?? chosen.current
                guard here == chosen.worktree, let leftOn, ctx.git.currentBranch() == leftOn else {
                    throw CLIFailure("`stack \(chosen.command)` keeps the index, so undo it from \(chosen.worktree) on '\(leftOn ?? "?")', where it left the checkout")
                }
            }
            let worktrees = try otherWorktrees(ctx, changes, here: here)
            let preUndo = try ctx.recordUndo("undo", branches, keepsIndex: chosen.keepsIndex)
            try restore(ctx, chosen, changes, here: here, worktrees: worktrees)
            try ctx.saveState(chosen.state)
            ctx.undoStore.remove(chosen.id)
            try ctx.finishUndo(preUndo, chosen.state)
            for change in changes { ctx.console.print("  " + describe(change, dryRun: false)) }
            if changes.isEmpty { ctx.console.print("  (no branch moves)") }
        }
    }

    /// The other worktrees the changed branches are checked out in. Fails
    /// before anything moves on one `restore` can't reset there.
    private static func otherWorktrees(_ ctx: StackContext, _ changes: [StackUndoChange], here: String) throws -> [String: String] {
        let worktrees = ctx.git.worktreeMap().filter { $0.value != here }
        for change in changes {
            guard let worktree = worktrees[change.branch] else { continue }
            if case .delete = change {
                throw CLIFailure("'\(change.branch)' is checked out in \(worktree) — switch away from it there, then re-run")
            }
            if !(try ctx.git.git("-C", worktree, "status", "--porcelain", "--untracked-files=no")).isEmpty {
                throw CLIFailure("'\(change.branch)' is checked out in \(worktree) with uncommitted changes — commit or stash there, then re-run")
            }
        }
        return worktrees
    }

    /// A branch checked out in another worktree is reset there, as
    /// `restack` rebases it there.
    private static func restore(
        _ ctx: StackContext,
        _ snapshot: StackUndoSnapshot,
        _ changes: [StackUndoChange],
        here: String,
        worktrees: [String: String]
    ) throws {
        let byBranch = Dictionary(uniqueKeysWithValues: changes.map { ($0.branch, $0) })
        let checkedOut = ctx.git.currentBranch()
        let survives = { (branch: String) -> Bool in
            byBranch[branch].map { $0.target != nil } ?? ctx.git.branchExists(branch)
        }
        // The checkout goes back to where the command found it, when that
        // was this worktree.
        var target = snapshot.worktree == here ? snapshot.current : checkedOut
        if let wanted = target, !survives(wanted) || worktrees[wanted] != nil { target = checkedOut }
        if let wanted = target, !survives(wanted) { target = ctx.trunk }
        var switched: String?
        if let target, target != checkedOut {
            if let sha = byBranch[target]?.target { try ctx.git.git("branch", "-f", target, sha) }
            if snapshot.keepsIndex {
                try ctx.git.git("symbolic-ref", "HEAD", GitRef.local(target))
            } else {
                try ctx.git.switchTo(target, quiet: true)
            }
            switched = target
        }
        let now = ctx.git.currentBranch()
        for change in changes where change.branch != switched {
            switch change {
            case .move(let branch, _, let to):
                if branch == now {
                    try ctx.git.git("reset", "-q", snapshot.keepsIndex ? "--soft" : "--keep", to)
                } else if let worktree = worktrees[branch] {
                    try ctx.git.git("-C", worktree, "reset", "-q", "--keep", to)
                } else {
                    try ctx.git.git("branch", "-f", branch, to)
                }
            case .create(let branch, let at):
                try ctx.git.git("branch", branch, at)
            case .delete(let branch, _):
                try ctx.git.git("branch", "-D", branch)
            }
        }
    }

    private static func describe(_ change: StackUndoChange, dryRun: Bool) -> String {
        switch change {
        case .move(let branch, let from, let to):
            "\(branch): \(dryRun ? "would move" : "moved") \(from.prefix(10)) → \(to.prefix(10))"
        case .create(let branch, let at):
            "\(branch): \(dryRun ? "would recreate" : "recreated") at \(at.prefix(10))"
        case .delete(let branch, let at):
            "\(branch): \(dryRun ? "would delete" : "deleted") (was \(at.prefix(10)); `git branch \(branch) \(at.prefix(10))` brings it back)"
        }
    }

    private static func describe(_ snapshot: StackUndoSnapshot, number: Int) -> String {
        let on = snapshot.current.map { ", on \($0)" } ?? ""
        return "  \(padded(number))) \(formatted(snapshot.created))  before `stack \(snapshot.command)`\(on) — \(snapshot.state.count) tracked"
    }

    private static func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
