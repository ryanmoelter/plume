import Foundation

/// Past conversations a tab could resume.
///
/// Claude Code files transcripts by working directory, and every worktree of
/// a repository is its own directory — so the conversation you want is often
/// filed under a sibling worktree rather than the one the tab is in.
/// Resuming one of those runs it in *this* tab's directory, which is why the
/// picker labels them.
nonisolated enum ResumableSessions {
    /// The tab's own directory first, then its repository's other worktrees.
    static func searchDirectories(
        workingDirectory: String,
        worktreePaths: [String]
    ) -> [String] {
        var seen: Set<String> = []
        return ([workingDirectory] + worktreePaths).filter { seen.insert(standardized($0)).inserted }
    }

    /// Reads every transcript in range, so it stays off the main actor: the
    /// worktree list comes from `GitService` and the scan runs in a detached
    /// task. Transcripts are mapped and both their scans are capped, which is
    /// what keeps a directory of large sessions affordable to label.
    static func load(workingDirectory: String, repoPath: String?) async -> [StoredSession] {
        let worktrees = if let repoPath {
            await GitService.shared.worktrees(in: repoPath).map(\.path)
        } else {
            [String]()
        }
        let directories = searchDirectories(workingDirectory: workingDirectory, worktreePaths: worktrees)

        return await Task.detached {
            directories
                .flatMap { SessionJSONLReader.storedSessions(inDirectory: $0) }
                .sorted { $0.lastModified > $1.lastModified }
        }.value
    }

    /// Drops conversations a tab already holds — resuming one twice would
    /// point two tabs at a single conversation, and `--resume` is not a fork.
    static func excludingOpen(_ sessions: [StoredSession], openSessionIDs: Set<String>) -> [StoredSession] {
        sessions.filter { !openSessionIDs.contains($0.sessionID) }
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
