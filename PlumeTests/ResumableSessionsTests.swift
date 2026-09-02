import Testing
import Foundation
@testable import Plume

/// Which directories the resume picker searches. Kept separate from the
/// `git` call so the rule is testable without a repository.
@MainActor
struct ResumableSessionsTests {
    @Test func theTabsOwnDirectoryComesFirst() {
        let directories = ResumableSessions.searchDirectories(
            workingDirectory: "/Users/me/Repo/.worktrees/feature",
            worktreePaths: ["/Users/me/Repo", "/Users/me/Repo/.worktrees/feature"]
        )
        #expect(directories.first == "/Users/me/Repo/.worktrees/feature")
    }

    /// The tab's directory is normally one of the repository's worktrees, so
    /// it would otherwise be searched twice.
    @Test func theWorktreeListDoesNotRepeatTheTabsDirectory() {
        let directories = ResumableSessions.searchDirectories(
            workingDirectory: "/Users/me/Repo",
            worktreePaths: ["/Users/me/Repo", "/Users/me/Repo/.worktrees/feature"]
        )
        #expect(directories == ["/Users/me/Repo", "/Users/me/Repo/.worktrees/feature"])
    }

    @Test func pathsThatDifferOnlyInFormAreOneDirectory() {
        let directories = ResumableSessions.searchDirectories(
            workingDirectory: "/Users/me/Repo",
            worktreePaths: ["/Users/me/Repo/"]
        )
        #expect(directories.count == 1)
    }

    @Test func withoutARepositoryOnlyTheTabsDirectoryIsSearched() {
        let directories = ResumableSessions.searchDirectories(
            workingDirectory: "/Users/me/notes",
            worktreePaths: []
        )
        #expect(directories == ["/Users/me/notes"])
    }
}
