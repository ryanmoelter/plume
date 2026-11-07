import Foundation

/// Lists and loads the changes in a `DiffRange`.
///
/// Synchronous, like `GitRunner` beneath it: callers reach it from a detached
/// task (`ReviewModel` does), never from the main actor. It deliberately does
/// not go through `GitService`, whose serial queue would hold the sidebar's
/// `git status` calls behind a large diff.
nonisolated enum GitDiffEngine {
    /// Beyond this many changed lines a file loads as `.tooLarge` unless the
    /// caller lifts the cap.
    static let defaultLineCap = 20_000

    /// Above this many bytes an untracked file is listed without counting its
    /// lines, and loads as `.tooLarge` until the cap is lifted.
    static let untrackedCountingLimit = 32 * 1024 * 1024

    /// `--literal-pathspecs` keeps a file named `*.swift` or `:x` from being
    /// read as a pattern; `core.quotePath` keeps non-ASCII names readable in
    /// patch headers.
    private static let gitPrefix = ["--literal-pathspecs", "-c", "core.quotePath=false"]

    /// `--no-relative` overrides a user's `diff.relative`, which would make
    /// paths relative to the working directory instead of the root.
    private static let diffOptions = ["diff", "--no-color", "--no-ext-diff", "--no-relative", "-M"]

    private static let noIndexOptions = ["diff", "--no-index", "--no-color", "--no-ext-diff"]

    /// What one relist reads.
    struct Snapshot: Sendable {
        let files: [DiffFileSummary]
        /// Every tracked and untracked, non-ignored file under the root.
        let listedPaths: [String]
        /// Submodules and untracked nested repositories, without a trailing
        /// slash. `ls-files` lists neither one's contents.
        let nestedRepositories: Set<String>
    }

    static let remoteDefaultBaseRef = "refs/remotes/origin/HEAD"
    /// Probed in order when `remoteDefaultBaseRef` names nothing.
    static let fallbackBaseRefs = [
        "refs/remotes/origin/main", "refs/heads/main",
        "refs/remotes/origin/master", "refs/heads/master",
    ]

    static func repositoryRoot(of directory: String) throws -> String {
        try GitRunner.run(["rev-parse", "--show-toplevel"], in: directory)
    }

    static func resolve(_ range: DiffRange, in directory: String) throws -> ResolvedDiffRange {
        let root = try repositoryRoot(of: directory)
        switch range {
        case .workingTree(let baseRef):
            return try resolveWorkingTree(baseRef: baseRef, root: root)
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

    /// `resolve` for a root already known, which costs one process.
    static func resolveWorkingTree(baseRef: String, root: String) throws -> ResolvedDiffRange {
        let base = try GitRunner.run(["merge-base", baseRef, "HEAD"], in: root)
        return ResolvedDiffRange(repositoryRoot: root, revisions: [base], includesUntracked: true, baseCommit: base)
    }

    /// The ref a working-tree review compares against, kept whole so a branch
    /// name with a slash survives.
    struct BaseRef: Hashable, Sendable {
        /// A full ref such as `refs/remotes/origin/release/2.0`, or `HEAD`.
        let ref: String

        var displayName: String {
            for prefix in ["refs/remotes/", "refs/heads/"] where ref.hasPrefix(prefix) {
                return String(ref.dropFirst(prefix.count))
            }
            return ref
        }
    }

    /// The remote's default branch where `origin/HEAD` names one, else
    /// `main` or `master`, remote before local, else `HEAD`, which narrows
    /// the review to uncommitted work.
    static func defaultBaseRef(in directory: String) -> BaseRef {
        func exists(_ ref: String) -> Bool {
            (try? GitRunner.run(["rev-parse", "--verify", "--quiet", ref], in: directory)) != nil
        }
        if let target = try? GitRunner.run(["symbolic-ref", "-q", remoteDefaultBaseRef], in: directory),
           target.hasPrefix("refs/"), exists(target) {
            return BaseRef(ref: target)
        }
        return BaseRef(ref: fallbackBaseRefs.first(where: exists) ?? "HEAD")
    }

    static func files(
        in range: ResolvedDiffRange,
        countingLimit: Int = untrackedCountingLimit,
        cache: UntrackedCountCache? = nil
    ) throws -> [DiffFileSummary] {
        try snapshot(in: range, countingLimit: countingLimit, cache: cache).files
    }

    /// The changed files and the listed paths, from two `git` processes.
    static func snapshot(
        in range: ResolvedDiffRange,
        countingLimit: Int = untrackedCountingLimit,
        cache: UntrackedCountCache? = nil
    ) throws -> Snapshot {
        let root = range.repositoryRoot
        let diff = try GitRunner.run(
            gitPrefix + diffOptions + ["-z", "--raw", "--numstat"] + range.revisions + ["--"],
            in: root,
            trimsOutput: false
        )
        let parsed = GitDiffParser.rawAndNumstat(diff)
        var files = GitDiffParser.summaries(nameStatus: parsed.nameStatus, numstat: parsed.numstat)

        let listing = try GitRunner.run(
            ["ls-files", "-z", "-t", "-s", "--cached", "--others", "--exclude-standard"],
            in: root,
            trimsOutput: false
        )
        var listed: [String] = []
        var untracked: [String] = []
        var nested: Set<String> = []
        var seen: Set<String> = []
        for entry in listing.split(separator: "\0") {
            // `? <path>` for an untracked file, `<tag> <mode> <sha> <stage>\t<path>`
            // for a tracked one.
            guard entry.count > 2 else { continue }
            let isUntracked = entry.first == "?"
            let path: String
            if isUntracked {
                path = String(entry.dropFirst(2))
                if path.hasSuffix("/") { nested.insert(String(path.dropLast())) }
            } else {
                guard let tab = entry.firstIndex(of: "\t") else { continue }
                path = String(entry[entry.index(after: tab)...])
                if entry.dropFirst(2).hasPrefix("160000 ") { nested.insert(path) }
            }
            guard seen.insert(path).inserted else { continue }
            listed.append(path)
            if isUntracked { untracked.append(path) }
        }

        if range.includesUntracked {
            // After `git rm --cached`, a path is both deleted from the index
            // and untracked on disk. One entry, diffed against the base, keeps
            // ids unique.
            var deletedIndex: [String: Int] = [:]
            for (index, file) in files.enumerated() where file.kind == .deleted {
                deletedIndex[file.path] = index
            }
            for path in untracked {
                if let index = deletedIndex[path] {
                    files[index] = overBaseSummary(path: path, in: range)
                } else if let summary = untrackedSummary(
                    path: path,
                    root: root,
                    countingLimit: countingLimit,
                    cache: cache
                ) {
                    files.append(summary)
                }
            }
            cache?.keepOnly(Set(untracked))
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return Snapshot(files: files, listedPaths: listed, nestedRepositories: nested)
    }

    /// Pass a nil `lineCap` to load a file however large it is.
    static func content(
        for file: DiffFileSummary,
        in range: ResolvedDiffRange,
        lineCap: Int? = defaultLineCap
    ) throws -> DiffFileContent {
        if file.isBinary { return .binary }
        if let lineCap {
            if file.isUncounted { return .tooLarge(changedLines: nil) }
            if file.changedLines > lineCap { return .tooLarge(changedLines: file.changedLines) }
        }

        let patch: String
        switch file.origin {
        case .untracked:
            patch = try noIndexDiff(["/dev/null", file.path], in: range.repositoryRoot)
        case .untrackedOverBase:
            patch = try withBaseCopy(of: file.path, in: range) { copy in
                try noIndexDiff([copy, file.path], in: range.repositoryRoot)
            }
        case .tracked:
            patch = try GitRunner.run(
                gitPrefix + diffOptions + range.revisions + ["--"] + [file.oldPath, file.path].compactMap { $0 },
                in: range.repositoryRoot,
                trimsOutput: false
            )
        }
        return GitDiffParser.patch(patch)
    }

    /// The paths, relative to the root, that `.gitignore` and friends don't
    /// exclude. A tracked file is never ignored, whatever the patterns say.
    static func unignoredPaths(_ paths: [String], in root: String) throws -> [String] {
        let ignored = try ignoredPaths(paths, in: root)
        return paths.filter { !ignored.contains($0) }
    }

    static func ignoredPaths(_ paths: [String], in root: String) throws -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let input = Data(paths.joined(separator: "\0").utf8 + [0])
        // Exit 1 means none of them is ignored.
        let output = try GitRunner.run(
            ["check-ignore", "--stdin", "-z"],
            in: root,
            trimsOutput: false,
            successStatuses: [0, 1],
            input: input
        )
        return Set(output.split(separator: "\0").map(String.init))
    }

    /// Counted here rather than by `git diff --no-index --numstat`, which
    /// would spawn a process per untracked file. Nil for anything that is
    /// not a regular file or a symlink: reading a FIFO would block forever.
    static func untrackedSummary(
        path: String,
        root: String,
        countingLimit: Int = untrackedCountingLimit,
        cache: UntrackedCountCache? = nil
    ) -> DiffFileSummary? {
        let url = URL(fileURLWithPath: root).appending(path: path)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            break
        case S_IFLNK:
            // git diffs a symlink as its target, one line.
            return DiffFileSummary(path: path, kind: .added, addedLines: 1, origin: .untracked)
        default:
            return nil
        }
        let stamp = UntrackedCountCache.Stamp(info)
        if let cached = cache?.summary(for: path, stamp: stamp) { return cached }
        let summary = countedSummary(path: path, url: url, size: Int(info.st_size), countingLimit: countingLimit)
        cache?.store(summary, for: path, stamp: stamp)
        return summary
    }

    private static func countedSummary(path: String, url: URL, size: Int, countingLimit: Int) -> DiffFileSummary {
        let uncounted = DiffFileSummary(path: path, kind: .added, origin: .untracked, isUncounted: true)
        guard size <= countingLimit,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return uncounted }
        // git's own heuristic: a NUL in the first 8000 bytes means binary.
        if data.prefix(8000).contains(0) {
            return DiffFileSummary(path: path, kind: .added, isBinary: true, origin: .untracked)
        }
        var lines = data.withUnsafeBytes { bytes in bytes.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } }
        if let last = data.last, last != 0x0A { lines += 1 }
        return DiffFileSummary(path: path, kind: .added, addedLines: lines, origin: .untracked)
    }

    /// A file that is untracked now but exists at the base, as a modification.
    private static func overBaseSummary(path: String, in range: ResolvedDiffRange) -> DiffFileSummary {
        let counts = try? withBaseCopy(of: path, in: range) { copy in
            try GitRunner.run(
                noIndexOptions + ["--numstat", "-z", "--", copy, path],
                in: range.repositoryRoot,
                trimsOutput: false,
                successStatuses: [0, 1]
            )
        }
        let fields = counts?.split(separator: "\0").first?.split(separator: "\t", omittingEmptySubsequences: false) ?? []
        let added = fields.count >= 2 ? Int(fields[0]) : nil
        let removed = fields.count >= 2 ? Int(fields[1]) : nil
        return DiffFileSummary(
            path: path,
            kind: .modified,
            isBinary: fields.count >= 2 && added == nil,
            addedLines: added ?? 0,
            removedLines: removed ?? 0,
            origin: .untrackedOverBase
        )
    }

    /// Writes the base's copy of `path` to a temporary file for `--no-index`,
    /// which compares only files on disk.
    private static func withBaseCopy<T>(
        of path: String,
        in range: ResolvedDiffRange,
        _ body: (String) throws -> T
    ) throws -> T {
        let blob = try GitRunner.runData(["cat-file", "blob", "\(range.baseCommit):\(path)"], in: range.repositoryRoot)
        let directory = FileManager.default.temporaryDirectory.appending(path: "plume-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appending(path: URL(fileURLWithPath: path).lastPathComponent)
        try blob.write(to: copy)
        return try body(copy.path)
    }

    /// Exit 1 is `--no-index` reporting that the files differ.
    private static func noIndexDiff(_ paths: [String], in root: String) throws -> String {
        try GitRunner.run(
            noIndexOptions + ["--"] + paths,
            in: root,
            trimsOutput: false,
            successStatuses: [0, 1]
        )
    }

    private static func commit(_ revision: String, in root: String) throws -> String {
        try GitRunner.run(["rev-parse", "--verify", "\(revision)^{commit}"], in: root)
    }

    /// Hashed rather than hardcoded, so a SHA-256 repository gets its own id.
    private static func emptyTree(in root: String) throws -> String {
        try GitRunner.run(["hash-object", "-t", "tree", "/dev/null"], in: root)
    }
}
