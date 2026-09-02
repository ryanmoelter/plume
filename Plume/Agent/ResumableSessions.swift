import Foundation

/// Past conversations a tab could resume.
///
/// Claude Code files transcripts by working directory, and every worktree of
/// a repository is its own directory — so the conversation you want is often
/// filed under a sibling worktree rather than the one the tab is in.
/// Resuming one of those runs it in *this* tab's directory, which is why the
/// picker labels them.
enum ResumableSessions {
    /// The tab's own directory first, then its repository's other worktrees.
    static func searchDirectories(
        workingDirectory: String,
        worktreePaths: [String]
    ) -> [String] {
        var seen: Set<String> = []
        return ([workingDirectory] + worktreePaths).filter { seen.insert(standardized($0)).inserted }
    }

    /// Runs a `git` subprocess and reads every transcript in range, so call
    /// it once when a view appears rather than from `body`. Transcripts are
    /// mapped and their prose scan is capped, which is what keeps a directory
    /// of large sessions affordable to label.
    static func load(workingDirectory: String, repoPath: String?) -> [StoredSession] {
        let worktrees = repoPath.map { GitRunner.worktrees(in: $0).map(\.path) } ?? []
        return searchDirectories(workingDirectory: workingDirectory, worktreePaths: worktrees)
            .flatMap { SessionJSONLReader.storedSessions(inDirectory: $0) }
            .sorted { $0.lastModified > $1.lastModified }
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
