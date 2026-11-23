import Foundation

/// One numbered piece of the uncommitted changes: a hunk, or a whole file
/// when its change can't be cut into hunks (binary, a mode change).
nonisolated struct StackHunkUnit: Equatable, Sendable {
    var id: Int
    var file: StackDiffFile
    /// Nil for the whole file.
    var hunk: StackHunk?
}

/// One new branch of `split --hunks`, oldest first.
nonisolated struct StackHunkAssignment: Equatable, Sendable {
    var branch: String
    var units: [Int]
    var message: String?
}

nonisolated enum StackHunkSplit {
    static func units(_ files: [StackDiffFile]) -> [StackHunkUnit] {
        var units: [StackHunkUnit] = []
        for file in files {
            switch file.kind {
            case .modified, .added, .deleted:
                for hunk in file.hunks { units.append(StackHunkUnit(id: units.count + 1, file: file, hunk: hunk)) }
            case .unsupported:
                units.append(StackHunkUnit(id: units.count + 1, file: file, hunk: nil))
            }
        }
        return units
    }

    /// `[{"branch": name, "hunks": [id or path, …], "message": optional}, …]`.
    /// A path stands for every unit of that file.
    static func parseMap(_ text: String, units: [StackHunkUnit]) throws -> [StackHunkAssignment] {
        let document: StackJSON
        do {
            document = try StackJSON.parse(Data(text.utf8))
        } catch let error as StackJSON.ParseError {
            throw CLIFailure("--map is not valid JSON: \(error.message)")
        }
        guard case .array(let entries) = document, !entries.isEmpty else {
            throw CLIFailure(#"--map must be a non-empty array of {"branch": <name>, "hunks": [<id or path>, ...]}"#)
        }
        var claimed: [Int: String] = [:]
        return try entries.map { entry in
            guard case .string(let branch)? = entry["branch"], !branch.isEmpty,
                  case .array(let selectors)? = entry["hunks"], !selectors.isEmpty
            else { throw CLIFailure(#"each --map entry needs a "branch" and a non-empty "hunks" list"#) }
            var message: String?
            switch entry["message"] {
            case nil, .null?: break
            case .string(let text)?: message = text
            default: throw CLIFailure("'\(branch)': \"message\" must be a string")
            }
            var ids: [Int] = []
            for selector in selectors {
                let matched: [Int]
                switch selector {
                case .int(let id):
                    guard units.contains(where: { $0.id == id }) else { throw CLIFailure("'\(branch)': no hunk \(id)") }
                    matched = [id]
                case .string(let path):
                    matched = units.filter { $0.file.path == path }.map(\.id)
                    if matched.isEmpty { throw CLIFailure("'\(branch)': no uncommitted changes in \(path)") }
                default:
                    throw CLIFailure("'\(branch)': a hunk is a number from the listing or a file path")
                }
                for id in matched {
                    if let owner = claimed[id] { throw CLIFailure("hunk \(id) is assigned to both '\(owner)' and '\(branch)'") }
                    claimed[id] = branch
                    ids.append(id)
                }
            }
            return StackHunkAssignment(branch: branch, units: ids.sorted(), message: message)
        }
    }

    /// One patch of `units`, by file in diff order. A whole-file unit carries
    /// the file's header and every hunk.
    static func patch(_ units: [StackHunkUnit]) -> String {
        var order: [String] = []
        var byFile: [String: [StackHunkUnit]] = [:]
        for unit in units {
            if byFile[unit.file.path] == nil { order.append(unit.file.path) }
            byFile[unit.file.path, default: []].append(unit)
        }
        return order.map { path in
            let units = byFile[path]!
            let file = units[0].file
            return units.contains { $0.hunk == nil } ? file.patch(file.hunks) : file.patch(units.compactMap(\.hunk))
        }.joined()
    }

    static func listing(_ units: [StackHunkUnit]) -> [String] {
        units.map { unit in
            let what = unit.hunk.map { "\($0.range)  (+\($0.added) -\($0.removed))" } ?? "whole file (\(reason(unit.file.kind)))"
            return "  \(Stack.padded(unit.id))  \(unit.file.path) \(what)"
        }
    }

    static func json(_ units: [StackHunkUnit]) -> String {
        let items = units.map { unit in
            StackJSON.object([
                StackJSONMember("id", .int(unit.id)),
                StackJSONMember("file", .string(unit.file.path)),
                StackJSONMember("header", unit.hunk.map { .string($0.range) } ?? .null),
                StackJSONMember("whole_file", .bool(unit.hunk == nil)),
                StackJSONMember("added", .int(unit.hunk?.added ?? 0)),
                StackJSONMember("removed", .int(unit.hunk?.removed ?? 0)),
                StackJSONMember("lines", .array((unit.hunk?.lines ?? []).map(StackJSON.string))),
            ])
        }
        return StackJSON.object([StackJSONMember("hunks", .array(items))]).rendered()
    }

    private static func reason(_ kind: StackDiffFile.Kind) -> String {
        if case .unsupported(let why) = kind { return why }
        return "text"
    }
}

nonisolated extension Stack {
    static let splitHunksUsage = "usage: stack split --hunks [--json] | stack split --hunks --map <json|file|->"

    /// `split --hunks`: lists the uncommitted changes as numbered hunks, or
    /// with `--map` commits them onto new branches stacked on the current
    /// one. Unassigned hunks stay uncommitted on the top new branch.
    static func splitHunks(_ ctx: StackContext, _ arguments: [String]) throws {
        var map: String?
        var json = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json": json = true
            case "--map":
                index += 1
                guard index < arguments.count else { throw CLIFailure("--map needs a value — \(splitHunksUsage)") }
                map = arguments[index]
            default: throw CLIFailure("unknown argument: \(arguments[index]) — \(splitHunksUsage)")
            }
            index += 1
        }
        guard let current = ctx.git.currentBranch() else { throw CLIFailure("detached HEAD — check out a branch first") }
        if try rebaseInProgress(ctx) {
            throw CLIFailure("a rebase is in progress — `git rebase --continue` or `git rebase --abort` first")
        }
        let units = StackHunkSplit.units(try uncommittedChanges(ctx))
        if units.isEmpty { throw CLIFailure("no uncommitted changes to split") }
        guard let map else {
            if json {
                ctx.console.print(StackHunkSplit.json(units))
            } else {
                ctx.console.print("uncommitted hunks on '\(current)' (assign them with `stack split --hunks --map <json>`):")
                for line in StackHunkSplit.listing(units) { ctx.console.print(line) }
            }
            return
        }
        if json { throw CLIFailure("--json lists hunks; it can't be combined with --map") }
        let assignments = try StackHunkSplit.parseMap(try readMap(map), units: units).map { assignment in
            var named = assignment
            named.branch = ctx.applyPrefix(assignment.branch)
            return named
        }
        if Set(assignments.map(\.branch)).count != assignments.count { throw CLIFailure("duplicate branch names") }
        for assignment in assignments {
            if ctx.git.branchExists(assignment.branch) { throw CLIFailure("branch '\(assignment.branch)' already exists") }
            if !ctx.git.succeeds("check-ref-format", GitRef.local(assignment.branch)) {
                throw CLIFailure("'\(assignment.branch)' is not a valid branch name")
            }
        }
        try ctx.state.withLock {
            var branches = try ctx.loadAndFlushLocked()
            if branches[current] == nil, current != ctx.trunk {
                throw CLIFailure("'\(current)' is not in a stack — run `stack track` first")
            }
            let byID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
            var parent = (name: current, sha: try ctx.rev(current))
            var tree = try ctx.git.git("rev-parse", "\(parent.sha)^{tree}")
            var planned: [(name: String, sha: String, base: (name: String, sha: String))] = []
            for assignment in assignments {
                let patch = StackHunkSplit.patch(assignment.units.compactMap { byID[$0] })
                guard let next = try ctx.applying(patch, to: tree) else {
                    throw CLIFailure("the hunks for '\(assignment.branch)' don't apply on top of the ones before them — nothing was created")
                }
                let message = assignment.message ?? String(assignment.branch.dropFirst(ctx.branchPrefix.count))
                let result = try ctx.git.run(["commit-tree", next, "-p", parent.sha, "-F", "-"], capture: true, input: message + "\n")
                guard result.status == 0 else {
                    throw CLIFailure("`git commit-tree` failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                let commit = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                planned.append((assignment.branch, commit, parent))
                parent = (assignment.branch, commit)
                tree = next
            }
            _ = try ctx.recordUndo(undoLabel("split", ["--hunks"]), branches, keepsIndex: true)
            for branch in planned {
                try ctx.git.git("branch", branch.name, branch.sha)
                branches[branch.name] = StackEntry(parent: branch.base.name, base: branch.base.sha)
            }
            // Moves the checkout without touching the working tree, which
            // already holds every hunk; the index follows the new tip.
            try ctx.git.git("symbolic-ref", "HEAD", GitRef.local(parent.name))
            try ctx.git.git("reset", "-q")
            try ctx.saveState(branches)
            let assigned = assignments.reduce(0) { $0 + $1.units.count }
            let made = zip(planned, assignments).map { "\($0.name) (\($1.units.count) hunk(s))" }
            ctx.console.print("split the uncommitted changes into: \(made.joined(separator: " ← "))")
            if assigned < units.count {
                ctx.console.print("\(units.count - assigned) hunk(s) left uncommitted on '\(parent.name)'")
            }
            let root = StackGraph.root(branches, of: parent.name)
            ctx.console.print(try render(ctx, branches, roots: [root], current: parent.name, prs: [:], prState: .off))
        }
    }

    /// Staged, unstaged and untracked changes against `HEAD`, as one diff.
    private static func uncommittedChanges(_ ctx: StackContext) throws -> [StackDiffFile] {
        let top = try ctx.git.git("rev-parse", "--show-toplevel")
        let tracked = try ctx.git.run(["-C", top] + StackPatch.diffArguments + ["--binary", "HEAD"])
        guard tracked.status == 0 else { throw CLIFailure("`git diff HEAD` failed: \(tracked.stderr)") }
        var files = StackPatch.parse(tracked.stdout)
        let others = try ctx.git.run(["-C", top, "ls-files", "--others", "--exclude-standard", "-z"]).stdout
        for path in others.split(separator: "\0").map(String.init) {
            // --no-index exits 1 when the files differ, which they always do.
            let diff = try ctx.git.run(["-C", top] + StackPatch.diffArguments + ["--binary", "--no-index", "--", "/dev/null", path])
            guard diff.status <= 1 else { throw CLIFailure("could not diff untracked \(path): \(diff.stderr)") }
            files += StackPatch.parse(diff.stdout)
        }
        return files
    }

    /// Inline JSON, `-` for stdin, or a file path.
    private static func readMap(_ value: String) throws -> String {
        if value.hasPrefix("[") || value.hasPrefix("{") { return value }
        if value == "-" {
            return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        guard let data = FileManager.default.contents(atPath: value) else { throw CLIFailure("cannot read --map file \(value)") }
        return String(decoding: data, as: UTF8.self)
    }
}
