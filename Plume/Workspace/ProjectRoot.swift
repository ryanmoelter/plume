import Foundation

/// The key Settings ▸ Projects stores a repository's settings under: the one
/// `plume wt` looks up, through the same `WorktreeContext.locate`. That is
/// the main worktree, or the folder holding `.bare`, from any checkout.
///
/// Not `CheckoutFacts.projectRoot`, whose standardizing strips `/private`
/// from paths git reports with it.
nonisolated enum ProjectRoot {
    /// Nil outside a git repository. Blocks on `git`, so call it off the
    /// main actor.
    static func containing(_ path: String) -> String? {
        try? WorktreeContext.locate(git: ProcessWorktreeGit(workingDirectory: path)).root
    }

    /// Where git runs repository-wide commands for `root`: its `.bare` in the
    /// bare layout, where the root itself is no repository, else `root`.
    /// This is what a task records as its `repoPath`.
    static func repositoryDirectory(forRoot root: String) -> String {
        let bare = (root as NSString).appendingPathComponent(".bare")
        return FileManager.default.fileExists(atPath: bare) ? bare : root
    }

    /// Whether `repository` is the bare layout's `.bare`, whose worktrees
    /// belong beside it in the project folder, never inside it.
    static func isBareLayoutRepository(_ repository: String) -> Bool {
        (repository as NSString).lastPathComponent == ".bare"
    }
}

/// What a project's unset fields fall back to, as `plume wt` derives them
/// from git. Shown as placeholders in Settings ▸ Projects.
nonisolated struct ProjectFallbacks: Equatable, Sendable {
    /// Nil when `user.email` is missing.
    var branchPrefix: String?
    var baseBranch: String
    var forge: ForgeKind

    static let unloaded = ProjectFallbacks(branchPrefix: nil, baseBranch: "main", forge: .none)

    /// Blocks on `git`, so call it off the main actor. A nil `root`, the
    /// defaults row, reads only global config and has no origin.
    static func load(root: String?) -> ProjectFallbacks {
        let git = ProcessWorktreeGit(workingDirectory: root == nil ? NSHomeDirectory() : nil)
        if let root { git.repoDir = ProjectRoot.repositoryDirectory(forRoot: root) }
        return ProjectFallbacks(
            branchPrefix: WTSettings.branchPrefix(configured: nil, userEmail: git.configGet("user.email")),
            baseBranch: WTSettings.baseBranch(configured: nil, originHead: root == nil ? nil : git.originHead()),
            forge: root == nil ? .none : ForgeKind.sniffing(originURL: git.originURL())
        )
    }
}
