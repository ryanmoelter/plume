import Foundation

/// A worktree Plume created for one of a task's tabs. Only these are ever
/// offered for removal when the task is archived or deleted: a tab's folder
/// moves with every `cd` and is copied between tabs, so it says nothing
/// about who made the worktree it is in.
nonisolated struct OwnedWorktree: Codable, Hashable, Sendable {
    let path: String
    let repoPath: String
    /// The branch Plume created along with the worktree.
    let branch: String?

    init(path: String, repoPath: String, branch: String?) {
        self.path = Self.standardized(path)
        self.repoPath = repoPath
        self.branch = branch
    }

    /// Symlinks resolved, so `/tmp/x` and `/private/tmp/x` compare equal.
    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Whether `folder` is this worktree or inside it.
    func contains(_ folder: String) -> Bool {
        let folder = Self.standardized(folder)
        return folder == path || folder.hasPrefix(path + "/")
    }
}
