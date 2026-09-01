import Foundation

/// Creates the working directories tasks run in.
///
/// Worktrees live inside the repo at `<repo>/.plume/worktrees/<branch-slug>`,
/// with a `<repo>/.plume/.gitignore` of `*` so nothing under `.plume/` is ever
/// tracked.
enum WorkspaceProvisioner {
    static let plumeDirectoryName = ".plume"

    // MARK: - Branch naming

    /// `plume/<slugified-title>-<4 hex chars>`. The suffix keeps two tasks
    /// with the same title from colliding.
    static func suggestedBranchName(for title: String, suffix: String = randomSuffix()) -> String {
        let slug = slugify(title)
        return "plume/\(slug.isEmpty ? "task" : slug)-\(suffix)"
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

    /// Directory name for a branch: `plume/fix-login` → `fix-login`.
    static func worktreeDirectoryName(for branch: String) -> String {
        let slug = slugify(branch.replacingOccurrences(of: "/", with: "-"))
        return slug.isEmpty ? "worktree" : slug
    }

    static func randomSuffix() -> String {
        String(format: "%04x", Int.random(in: 0..<0x10000))
    }

    // MARK: - Provisioning

    static func worktreePath(repository: String, branch: String) -> String {
        URL(fileURLWithPath: repository)
            .appending(path: plumeDirectoryName)
            .appending(path: "worktrees")
            .appending(path: worktreeDirectoryName(for: branch))
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

    /// Creates a branch and its worktree, returning the worktree path.
    /// Base ref is the repository's current HEAD.
    @discardableResult
    static func createWorktree(repository: String, branch: String) throws -> String {
        try ensurePlumeDirectoryIgnored(in: repository)
        let path = worktreePath(repository: repository, branch: branch)
        try GitRunner.run(["worktree", "add", "-b", branch, path], in: repository)
        return path
    }

    /// Removes a worktree, and optionally its branch. Used by the delete flow,
    /// which always asks first.
    static func removeWorktree(repository: String, path: String, branch: String?, deleteBranch: Bool) throws {
        try GitRunner.run(["worktree", "remove", "--force", path], in: repository)
        if deleteBranch, let branch {
            try GitRunner.run(["branch", "-D", branch], in: repository)
        }
    }
}
