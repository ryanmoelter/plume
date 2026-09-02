import Foundation

/// Runs every `git` subprocess the app issues, off the main actor.
///
/// The project defaults types to `MainActor`, so a plain call to `GitRunner`
/// from a view or store blocks the window for as long as `git` takes — tens
/// of milliseconds, on a timer, which reads as dropped frames. Marking the
/// runner `nonisolated` would fix where the work lands but not where it can
/// be called from: a synchronous `body` could still invoke it.
///
/// An actor closes that. Reaching git means `await`, which a synchronous
/// context cannot write, so the blocking call becomes a compile error rather
/// than a frame drop. Serializing on the actor also means one `git` at a time
/// per process, which is what a burst of `.git` writes needs anyway.
///
/// `GitRunner` stays synchronous underneath, for tests and for
/// `WorkspaceProvisioner`, which already runs off the main actor.
actor GitService {
    static let shared = GitService()

    func state(in directory: String) -> GitState? {
        GitRunner.state(in: directory)
    }

    func repositoryRoot(containing path: String) -> String? {
        GitRunner.repositoryRoot(containing: path)
    }

    func currentBranch(in repository: String) -> String? {
        GitRunner.currentBranch(in: repository)
    }

    func worktrees(in repository: String) -> [GitWorktree] {
        GitRunner.worktrees(in: repository)
    }

    /// Worktrees and the current branch together, so a picker populates from
    /// one hop rather than two.
    func worktreeListing(in repository: String) -> (worktrees: [GitWorktree], branch: String?) {
        (GitRunner.worktrees(in: repository), GitRunner.currentBranch(in: repository))
    }

    func createWorktree(
        repository: String,
        branch: String,
        basePath: String?
    ) throws -> String {
        try WorkspaceProvisioner.createWorktree(
            repository: repository,
            branch: branch,
            basePath: basePath
        )
    }

    func removeWorktree(
        repository: String,
        path: String,
        branch: String?,
        deleteBranch: Bool
    ) throws {
        try WorkspaceProvisioner.removeWorktree(
            repository: repository,
            path: path,
            branch: branch,
            deleteBranch: deleteBranch
        )
    }
}
