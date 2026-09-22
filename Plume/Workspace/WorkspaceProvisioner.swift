import Foundation

/// Creates the working directories tasks run in.
///
/// Worktrees live inside the repo at `<repo>/.plume/worktrees/<branch-slug>`,
/// with a `<repo>/.plume/.gitignore` of `*` so nothing under `.plume/` is ever
/// tracked.
nonisolated enum WorkspaceProvisioner {
    static let plumeDirectoryName = ".plume"

    // MARK: - Branch naming

    static let defaultBranchPrefix = "plume/"

    /// `<prefix><slugified-title>-<4 hex chars>`. The suffix keeps two tasks
    /// with the same title from colliding.
    static func suggestedBranchName(
        for title: String,
        suffix: String = randomSuffix(),
        prefix: String = defaultBranchPrefix
    ) -> String {
        let slug = slugify(title)
        return "\(prefix)\(slug.isEmpty ? "task" : slug)-\(suffix)"
    }

    static func slugify(_ text: String) -> String {
        let lowered = text.lowercased()
        let mapped = lowered.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String(collapsed.prefix(40))
    }

    /// Directory name for a branch: `plume/fix-login` → `plume-fix-login`.
    ///
    /// `strippingPrefix` drops everything before the last `/` first, so
    /// `ryanm/plume-183` becomes `plume-183`. A branch with no `/`, and one
    /// whose last segment is empty, keep the whole name — stripping to
    /// nothing would name every such worktree `worktree`.
    static func worktreeDirectoryName(for branch: String, strippingPrefix: Bool = false) -> String {
        var name = branch
        if strippingPrefix, let lastSegment = branch.split(separator: "/").last {
            name = String(lastSegment)
        }
        let slug = slugify(name.replacingOccurrences(of: "/", with: "-"))
        return slug.isEmpty ? "worktree" : slug
    }

    /// The branch prefix the user's own tooling already uses, from
    /// `wt.branchprefix` or `stack.branchprefix` — the keys `wt` and `stack`
    /// read. Nil when neither is set, which is when Plume falls back to its
    /// own `plume/`.
    ///
    /// Read from git rather than mirrored into a setting so one answer serves
    /// every tool, and normalized to end in `/` because a prefix is a path
    /// segment whether or not the config spells the slash.
    static func configuredBranchPrefix(in repository: String? = nil) -> String? {
        for key in ["wt.branchprefix", "stack.branchprefix"] {
            guard let value = try? GitRunner.run(["config", "--get", key], in: repository) else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
        }
        return nil
    }

    static func randomSuffix() -> String {
        String(format: "%04x", Int.random(in: 0..<0x10000))
    }

    // MARK: - Provisioning

    /// Worktrees live under `<repo>/.plume/worktrees` by default, or under
    /// `basePath` when Settings overrides it — still namespaced by a
    /// repository-derived folder so worktrees from different repos can't collide.
    ///
    /// `explicitPath` is the sheet's own override, which the user typed in
    /// full and which therefore bypasses both derivations.
    static func worktreePath(
        repository: String,
        branch: String,
        basePath: String? = nil,
        strippingPrefix: Bool = false,
        explicitPath: String? = nil
    ) -> String {
        if let explicitPath {
            let trimmed = explicitPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return (trimmed as NSString).expandingTildeInPath }
        }
        let directoryName = worktreeDirectoryName(for: branch, strippingPrefix: strippingPrefix)
        guard let basePath, !basePath.isEmpty else {
            return URL(fileURLWithPath: repository)
                .appending(path: plumeDirectoryName)
                .appending(path: "worktrees")
                .appending(path: directoryName)
                .path
        }
        let repositoryName = URL(fileURLWithPath: repository).lastPathComponent
        return URL(fileURLWithPath: basePath)
            .appending(path: repositoryName)
            .appending(path: directoryName)
            .path
    }

    /// Creates `<repo>/.plume/.gitignore` containing `*` so the worktrees the
    /// app creates never show up in the user's `git status`.
    static func ensurePlumeDirectoryIgnored(in repository: String) throws {
        let plumeDirectory = URL(fileURLWithPath: repository).appending(path: plumeDirectoryName)
        try FileManager.default.createDirectory(at: plumeDirectory, withIntermediateDirectories: true)

        let gitignore = plumeDirectory.appending(path: ".gitignore")
        guard !FileManager.default.fileExists(atPath: gitignore.path) else { return }
        try "*\n".write(to: gitignore, atomically: true, encoding: .utf8)
    }

    /// Whether `path` lands inside `<repository>/.plume`, which is what
    /// decides whether the ignore file is this call's business. An explicit
    /// location may be either inside the repo or outside it, so the answer
    /// comes from the resolved path rather than from which override produced
    /// it.
    static func isInsidePlumeDirectory(path: String, repository: String) -> Bool {
        let plumeDirectory = URL(fileURLWithPath: repository)
            .appending(path: plumeDirectoryName)
            .standardizedFileURL.path
        return URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(plumeDirectory + "/")
    }

    /// Creates a branch and its worktree, returning the worktree path.
    /// Base ref is the repository's current HEAD. `basePath` overrides the
    /// default in-repo location (Settings' worktree base path override), and
    /// `explicitPath` overrides both with a location the user typed.
    @discardableResult
    static func createWorktree(
        repository: String,
        branch: String,
        basePath: String? = nil,
        strippingPrefix: Bool = false,
        explicitPath: String? = nil
    ) throws -> String {
        let path = worktreePath(
            repository: repository,
            branch: branch,
            basePath: basePath,
            strippingPrefix: strippingPrefix,
            explicitPath: explicitPath
        )
        if isInsidePlumeDirectory(path: path, repository: repository) {
            try ensurePlumeDirectoryIgnored(in: repository)
        } else {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try GitRunner.run(["worktree", "add", "-b", branch, path], in: repository)
        return path
    }

    /// Uncommitted work in a worktree, as `git status --porcelain` lines.
    ///
    /// Empty for a clean tree, and for one dirtied only by ignored files —
    /// build output is not work worth warning about, and plain porcelain
    /// leaves it out for the same reason `git worktree remove` does not count
    /// it as dirty.
    static func uncommittedChanges(in path: String) -> [String] {
        guard let output = try? GitRunner.run(["status", "--porcelain"], in: path) else { return [] }
        return output.split(separator: "\n").map(String.init)
    }

    /// Removes a worktree, and optionally its branch. Used by the delete flow,
    /// which always asks first.
    ///
    /// `--force` is what lets this proceed at all once the tree is dirty:
    /// without it git refuses. The caller is expected to have asked about
    /// anything `uncommittedChanges(in:)` reports, since nothing here can be
    /// recovered afterwards.
    static func removeWorktree(repository: String, path: String, branch: String?, deleteBranch: Bool) throws {
        try GitRunner.run(["worktree", "remove", "--force", path], in: repository)
        if deleteBranch, let branch {
            try GitRunner.run(["branch", "-D", branch], in: repository)
        }
    }
}
