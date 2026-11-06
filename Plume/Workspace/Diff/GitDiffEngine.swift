import Foundation

/// Lists and loads the changes in a `DiffRange`.
///
/// Synchronous, like `GitRunner` beneath it: callers reach it from a detached
/// task (`ReviewStore` does), never from the main actor. It deliberately does
/// not go through `GitService`, whose serial queue would hold the sidebar's
/// `git status` calls behind a large diff.
nonisolated enum GitDiffEngine {
    /// Beyond this many changed lines a file loads as `.tooLarge` unless the
    /// caller lifts the cap.
    static let defaultLineCap = 20_000

    /// Above this an untracked file is listed without counting its lines.
    static let untrackedCountingLimit = 32 * 1024 * 1024

    /// `--literal-pathspecs` keeps a file named `*.swift` or `:x` from being
    /// read as a pattern; `core.quotePath` keeps non-ASCII names readable in
    /// patch headers.
    private static let gitPrefix = ["--literal-pathspecs", "-c", "core.quotePath=false"]

    /// `--no-relative` overrides a user's `diff.relative`, which would make
    /// paths relative to the working directory instead of the root.
    private static let diffOptions = ["diff", "--no-color", "--no-ext-diff", "--no-relative", "-M"]

    static func resolve(_ range: DiffRange, in directory: String) throws -> ResolvedDiffRange {
        let root = try GitRunner.run(["rev-parse", "--show-toplevel"], in: directory)
        switch range {
        case .workingTree(let baseRef):
            let base = try GitRunner.run(["merge-base", baseRef, "HEAD"], in: root)
            return ResolvedDiffRange(repositoryRoot: root, revisions: [base], includesUntracked: true, baseCommit: base)
        case .commits(let base, let head):
            let baseCommit = try commit(base, in: root)
            let headCommit = try commit(head, in: root)
            return ResolvedDiffRange(
                repositoryRoot: root,
                revisions: [baseCommit, headCommit],
                includesUntracked: false,
                baseCommit: baseCommit
            )
        case .commit(let revision):
            let target = try commit(revision, in: root)
            let parent = try (try? GitRunner.run(["rev-parse", "--verify", "--quiet", "\(target)^"], in: root))
                ?? emptyTree(in: root)
            return ResolvedDiffRange(
                repositoryRoot: root,
                revisions: [parent, target],
                includesUntracked: false,
                baseCommit: parent
            )
        }
    }

    /// The ref a working-tree review compares against: the remote's default
    /// branch where it exists, else a local branch of the same name, else
    /// `HEAD`, which narrows the review to uncommitted work.
    static func defaultBaseRef(in directory: String) -> String {
        let candidates = [GitRunner.defaultBranch(in: directory)].compactMap { $0 } + ["main", "master"]
        for name in candidates {
            for ref in ["refs/remotes/origin/\(name)", "refs/heads/\(name)"] {
                if (try? GitRunner.run(["rev-parse", "--verify", "--quiet", ref], in: directory)) != nil {
                    return ref.hasPrefix("refs/remotes/") ? "origin/\(name)" : name
                }
            }
        }
        return "HEAD"
    }

    static func files(in range: ResolvedDiffRange) throws -> [DiffFileSummary] {
        let root = range.repositoryRoot
        let nameStatus = try GitRunner.run(
            gitPrefix + diffOptions + ["-z", "--name-status"] + range.revisions + ["--"],
            in: root,
            trimsOutput: false
        )
        let numstat = try GitRunner.run(
            gitPrefix + diffOptions + ["-z", "--numstat"] + range.revisions + ["--"],
            in: root,
            trimsOutput: false
        )
        var files = GitDiffParser.summaries(
            nameStatus: GitDiffParser.nameStatus(nameStatus),
            numstat: GitDiffParser.numstat(numstat)
        )
        if range.includesUntracked {
            files += try untrackedPaths(in: root).map { untrackedSummary(path: $0, root: root) }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Pass a nil `lineCap` to load a file however large it is.
    static func content(
        for file: DiffFileSummary,
        in range: ResolvedDiffRange,
        lineCap: Int? = defaultLineCap
    ) throws -> DiffFileContent {
        if file.isBinary { return .binary }
        if let lineCap, file.changedLines > lineCap { return .tooLarge(changedLines: file.changedLines) }

        let patch: String
        if file.isUntracked {
            // Exit 1 is `--no-index` reporting that the files differ.
            patch = try GitRunner.run(
                ["diff", "--no-index", "--no-color", "--no-ext-diff", "--", "/dev/null", file.path],
                in: range.repositoryRoot,
                trimsOutput: false,
                successStatuses: [0, 1]
            )
        } else {
            patch = try GitRunner.run(
                gitPrefix + diffOptions + range.revisions + ["--"] + [file.oldPath, file.path].compactMap { $0 },
                in: range.repositoryRoot,
                trimsOutput: false
            )
        }
        return GitDiffParser.patch(patch)
    }

    /// Every tracked and untracked, non-ignored file under the root, for a
    /// file tree.
    static func listedPaths(in repositoryRoot: String) throws -> [String] {
        let output = try GitRunner.run(
            ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            in: repositoryRoot,
            trimsOutput: false
        )
        return output.split(separator: "\0").map(String.init)
    }

    private static func untrackedPaths(in root: String) throws -> [String] {
        let output = try GitRunner.run(
            ["ls-files", "-z", "--others", "--exclude-standard"],
            in: root,
            trimsOutput: false
        )
        return output.split(separator: "\0").map(String.init)
    }

    /// Counted here rather than by `git diff --no-index --numstat`, which
    /// would spawn a process per untracked file.
    static func untrackedSummary(path: String, root: String) -> DiffFileSummary {
        let url = URL(fileURLWithPath: root).appending(path: path)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= untrackedCountingLimit,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else {
            return DiffFileSummary(path: path, kind: .added, isUntracked: true)
        }
        // git's own heuristic: a NUL in the first 8000 bytes means binary.
        if data.prefix(8000).contains(0) {
            return DiffFileSummary(path: path, kind: .added, isBinary: true, isUntracked: true)
        }
        var lines = data.withUnsafeBytes { bytes in bytes.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } }
        if let last = data.last, last != 0x0A { lines += 1 }
        return DiffFileSummary(path: path, kind: .added, addedLines: lines, isUntracked: true)
    }

    private static func commit(_ revision: String, in root: String) throws -> String {
        try GitRunner.run(["rev-parse", "--verify", "\(revision)^{commit}"], in: root)
    }

    /// Hashed rather than hardcoded, so a SHA-256 repository gets its own id.
    private static func emptyTree(in root: String) throws -> String {
        try GitRunner.run(["hash-object", "-t", "tree", "/dev/null"], in: root)
    }
}
