import Foundation

/// What a row currently holds watches on, and what changing that set costs.
///
/// Both stores are refcounted, so an unbalanced call silently leaks a poll.
/// Pure so the diff is testable without a view.
struct DirectoryWatchSet: Equatable {
    /// Directories holding a git watch. Taken regardless of the setting — the
    /// row needs a branch either way.
    var git: Set<String> = []
    /// Directories holding a pull request watch, which the setting can turn
    /// off without the directory set changing.
    var pullRequests: Set<String> = []

    struct Change: Equatable {
        var gitToRelease: Set<String> = []
        var gitToWatch: Set<String> = []
        var pullRequestsToRelease: Set<String> = []
        var pullRequestsToWatch: Set<String> = []

        var isEmpty: Bool {
            gitToRelease.isEmpty && gitToWatch.isEmpty
                && pullRequestsToRelease.isEmpty && pullRequestsToWatch.isEmpty
        }
    }

    func change(to directories: Set<String>, watchesPullRequests: Bool) -> Change {
        let wanted = watchesPullRequests ? directories : []
        return Change(
            gitToRelease: git.subtracting(directories),
            gitToWatch: directories.subtracting(git),
            pullRequestsToRelease: pullRequests.subtracting(wanted),
            pullRequestsToWatch: wanted.subtracting(pullRequests)
        )
    }

    /// Records a change the caller has performed, so the set never claims a
    /// watch the caller did not take.
    mutating func apply(_ change: Change) {
        git.subtract(change.gitToRelease)
        git.formUnion(change.gitToWatch)
        pullRequests.subtract(change.pullRequestsToRelease)
        pullRequests.formUnion(change.pullRequestsToWatch)
    }
}
