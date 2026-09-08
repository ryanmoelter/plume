import Testing
import Foundation
@testable import Plume

struct TaskRowDetailsTests {
    private func group(
        _ directory: String?,
        branch: String? = nil,
        pullRequest: PullRequestFetchState? = nil,
        checkout: CheckoutFacts? = nil
    ) -> TaskRowDetails.DirectoryGroup {
        TaskRowDetails.DirectoryGroup(
            directory: directory,
            branch: branch,
            pullRequest: pullRequest,
            checkout: checkout
        )
    }

    /// The header names the project a worktree belongs to, not the folder it
    /// happens to sit in.
    @Test func aWorktreeIsLabelledWithItsProjectAndMarked() {
        let lines = TaskRowDetails.lines(groups: [group(
            "/wt/fix-login",
            branch: "ryanm/fix-login",
            checkout: CheckoutFacts(projectRoot: "/Users/me/Plume", checkoutRoot: "/wt/fix-login")
        )])
        #expect(lines == [
            .project("Plume"),
            .branch("ryanm/fix-login", isWorktree: true, accompaniedBy: nil),
        ])
    }

    @Test func theMainCheckoutIsLabelledButNotMarked() {
        let lines = TaskRowDetails.lines(groups: [group(
            "/Users/me/Plume",
            branch: "main",
            checkout: CheckoutFacts(projectRoot: "/Users/me/Plume", checkoutRoot: "/Users/me/Plume")
        )])
        #expect(lines == [.project("Plume"), .branch("main", isWorktree: false, accompaniedBy: nil)])
    }

    /// The lookup is async, so the row must read sensibly before it lands
    /// rather than showing a gap where the header goes.
    @Test func theFolderNameStandsInUntilTheLookupLands() {
        let lines = TaskRowDetails.lines(groups: [group("/wt/fix-login", branch: "main")])
        #expect(lines == [.project("fix-login"), .branch("main", isWorktree: false, accompaniedBy: nil)])
    }

    @Test func linesFollowDirectoryThenBranchOrder() {
        let lines = TaskRowDetails.lines(groups: [group("/Users/me/Plume", branch: "ryanm/fix-login")])
        #expect(lines == [.project("Plume"), .branch("ryanm/fix-login", accompaniedBy: nil)])
    }

    /// The trailing badge already says it, so no status takes a line.
    @Test(arguments: TaskStatus.allCases)
    func theAgentStatusNeverTakesALine(status: TaskStatus) {
        #expect(TaskRowDetails.lines(groups: [group(nil)]).isEmpty)
    }

    /// An unconfigured task should collapse to nothing rather than show gaps.
    @Test func absentValuesProduceNoLines() {
        #expect(TaskRowDetails.lines(groups: [group(nil)]).isEmpty)
    }

    @Test func emptyStringsCountAsAbsent() {
        #expect(TaskRowDetails.lines(groups: [group("", branch: "")]).isEmpty)
    }

    @Test func aDirectoryWithoutABranchStillShows() {
        let lines = TaskRowDetails.lines(groups: [group("/Users/me/Plume")])
        #expect(lines == [.project("Plume")])
    }

    @Test func thePullRequestLineSitsLastInItsGroup() {
        let open = PullRequestFetchState.pullRequest(PullRequest(number: 42, state: .open, isDraft: false))
        let lines = TaskRowDetails.lines(
            groups: [group("/Users/me/Plume", branch: "ryanm/fix-login", pullRequest: open)]
        )
        #expect(lines == [
            .project("Plume"),
            .branch("ryanm/fix-login", accompaniedBy: nil),
            .pullRequest(directory: "/Users/me/Plume", state: open),
        ])
    }

    @Test func everyGroupRepeatsTheDirectoryAndBranch() {
        let lines = TaskRowDetails.lines(
            groups: [
                group("/Users/me/Plume", branch: "main"),
                group("/Users/me/Other", branch: "ryanm/thing"),
            ]
        )
        #expect(lines == [
            .project("Plume"), .branch("main", accompaniedBy: nil),
            .project("Other"), .branch("ryanm/thing", accompaniedBy: nil),
        ])
    }

    /// A single faint glyph reads as dead space, so these states take no row.
    @Test(arguments: [PullRequestFetchState.noPR, .loading, .forgeUnsupported])
    func aStateWithNothingToSayTakesNoRow(state: PullRequestFetchState) {
        #expect(TaskRowDetails.showsPullRequestLine(state) == false)
        let lines = TaskRowDetails.lines(groups: [group("/Users/me/Plume", branch: "main", pullRequest: state)])
        #expect(lines == [.project("Plume"), .branch("main", accompaniedBy: nil)])
    }

    /// Having no upstream is a fact about the branch, so it survives the row
    /// being hidden by riding along on the branch line.
    @Test func localOnlyMovesOntoTheBranchLine() {
        #expect(TaskRowDetails.showsPullRequestLine(.localOnly) == false)
        let lines = TaskRowDetails.lines(
            groups: [group("/Users/me/Plume", branch: "main", pullRequest: .localOnly)]
        )
        #expect(lines == [.project("Plume"), .branch("main", accompaniedBy: .localOnly)])
    }

    /// It has nowhere to ride, so it is simply not shown.
    @Test func localOnlyWithoutABranchShowsNothing() {
        #expect(TaskRowDetails.lines(groups: [group(nil, pullRequest: .localOnly)]).isEmpty)
    }

    @Test func theBranchCompanionReachesTheAccessibilityLabel() {
        let line = TaskRowDetails.Line.branch("main", accompaniedBy: .localOnly)
        #expect(TaskRowDetails.accessibilityText(line) == "main local only")
    }

    /// Being offline must not look like a repository with no pull requests.
    @Test(arguments: [PullRequestFetchState.timedOut, .failed("offline")])
    func anUnreachableForgeStillTakesARow(state: PullRequestFetchState) {
        #expect(TaskRowDetails.showsPullRequestLine(state))
        let lines = TaskRowDetails.lines(groups: [group("/Users/me/Plume", pullRequest: state)])
        #expect(lines == [.project("Plume"), .pullRequest(directory: "/Users/me/Plume", state: state)])
    }

    /// The hidden states keep their glyphs, which the fixture view and the
    /// accessibility label both still read.
    @Test func aHiddenStateKeepsItsGlyphs() {
        #expect(PullRequestChipContent.glyphs(for: .noPR).isEmpty == false)
        #expect(PullRequestChipContent.accessibilityText(for: .noPR) == "no PR")
    }

    @Test func aPullRequestLineReachesTheAccessibilityLabel() {
        let line = TaskRowDetails.Line.pullRequest(
            directory: "/Users/me/Plume",
            state: .pullRequest(PullRequest(number: 42, state: .open, isDraft: false))
        )
        #expect(TaskRowDetails.accessibilityText(line)?.contains("PR #42") == true)
    }

    @Test func directoryUsesTheLastPathComponent() {
        #expect(TaskRowDetails.directoryName("/Users/me/Development/Plume") == "Plume")
    }
}

struct TaskRowDirectoryGroupingTests {
    @Test func twoTabsInOneFolderCollapseToOneGroup() {
        let directories = TaskRowDetails.distinctDirectories(
            agentTabDirectories: ["/Users/me/Plume", "/Users/me/Plume"],
            taskDirectory: "/Users/me/Plume"
        )
        #expect(directories == ["/Users/me/Plume"])
    }

    @Test func twoFoldersGiveTwoGroupsInTabOrder() {
        let directories = TaskRowDetails.distinctDirectories(
            agentTabDirectories: ["/Users/me/Plume", "/Users/me/Other", "/Users/me/Plume"],
            taskDirectory: "/Users/me/Plume"
        )
        #expect(directories == ["/Users/me/Plume", "/Users/me/Other"])
    }

    @Test func aTaskWithNoReportingAgentTabFallsBackToItsOwnFolder() {
        let directories = TaskRowDetails.distinctDirectories(
            agentTabDirectories: [nil, nil],
            taskDirectory: "/Users/me/Plume"
        )
        #expect(directories == ["/Users/me/Plume"])
    }

    @Test func aTaskWithNoFolderAtAllHasNoGroups() {
        #expect(TaskRowDetails.distinctDirectories(agentTabDirectories: [], taskDirectory: nil).isEmpty)
    }
}

@MainActor
struct TaskRowAgentTabFilterTests {
    /// A terminal's cwd follows `cd`, so it must not contribute a group.
    @Test func terminalTabsAreExcluded() throws {
        let task = WorkTask(title: "T", orderIndex: 0)
        task.workingDirectoryPath = "/Users/me/Plume"
        let agent = TaskTab(kind: .agent, orderIndex: 0, task: task)
        let terminal = TaskTab(kind: .terminal, orderIndex: 1, task: task)
        task.tabs = [agent, terminal]

        let store = TabDirectoryStore()
        store.setDirectory("/Users/me/Plume", forTab: agent.id)
        store.setDirectory("/tmp/wandered", forTab: terminal.id)

        let directories = TaskRowDetails.distinctDirectories(
            agentTabDirectories: task.orderedTabs
                .filter { $0.kind == .agent }
                .map { store.directory(for: $0) },
            taskDirectory: task.workingDirectoryPath
        )
        #expect(directories == ["/Users/me/Plume"])
    }
}

struct DirectoryWatchSetTests {
    @Test func addingADirectoryTakesExactlyOneNewWatch() {
        let watched = DirectoryWatchSet(git: ["/a"], pullRequests: ["/a"])
        let change = watched.change(to: ["/a", "/b"], watchesPullRequests: true)
        #expect(change.gitToWatch == ["/b"])
        #expect(change.pullRequestsToWatch == ["/b"])
        #expect(change.gitToRelease.isEmpty)
        #expect(change.pullRequestsToRelease.isEmpty)
    }

    @Test func removingADirectoryReleasesExactlyOne() {
        let watched = DirectoryWatchSet(git: ["/a", "/b"], pullRequests: ["/a", "/b"])
        let change = watched.change(to: ["/a"], watchesPullRequests: true)
        #expect(change.gitToRelease == ["/b"])
        #expect(change.pullRequestsToRelease == ["/b"])
        #expect(change.gitToWatch.isEmpty)
        #expect(change.pullRequestsToWatch.isEmpty)
    }

    @Test func anUnchangedSetTakesNothing() {
        let watched = DirectoryWatchSet(git: ["/a"], pullRequests: ["/a"])
        #expect(watched.change(to: ["/a"], watchesPullRequests: true).isEmpty)
    }

    /// The git watch is taken regardless of the setting; only the pull request
    /// watch follows it.
    @Test func turningTheSettingOffReleasesOnlyThePullRequestWatch() {
        let watched = DirectoryWatchSet(git: ["/a"], pullRequests: ["/a"])
        let change = watched.change(to: ["/a"], watchesPullRequests: false)
        #expect(change.pullRequestsToRelease == ["/a"])
        #expect(change.gitToRelease.isEmpty)
        #expect(change.gitToWatch.isEmpty)
    }

    @Test func aNewDirectoryWithTheSettingOffTakesOnlyTheGitWatch() {
        let change = DirectoryWatchSet().change(to: ["/a"], watchesPullRequests: false)
        #expect(change.gitToWatch == ["/a"])
        #expect(change.pullRequestsToWatch.isEmpty)
    }

    @Test func applyingAChangeRecordsWhatTheCallerTook() {
        var watched = DirectoryWatchSet(git: ["/a"], pullRequests: ["/a"])
        watched.apply(watched.change(to: ["/b"], watchesPullRequests: true))
        #expect(watched == DirectoryWatchSet(git: ["/b"], pullRequests: ["/b"]))
    }

    @Test func disappearingReleasesEverything() {
        let watched = DirectoryWatchSet(git: ["/a", "/b"], pullRequests: ["/a"])
        let change = watched.change(to: [], watchesPullRequests: true)
        #expect(change.gitToRelease == ["/a", "/b"])
        #expect(change.pullRequestsToRelease == ["/a"])
    }
}

/// The stores are refcounted, so a diffed change must leave them balanced.
@MainActor
struct DirectoryWatchRefcountTests {
    @Test func aBalancedDiffLeavesNoWatchBehind() {
        let store = GitStateStore()
        var watched = DirectoryWatchSet()

        func perform(_ directories: Set<String>) {
            let change = watched.change(to: directories, watchesPullRequests: false)
            for directory in change.gitToRelease { store.release(directory) }
            for directory in change.gitToWatch { store.watch(directory) }
            watched.apply(change)
        }

        perform(["/a"])
        perform(["/a", "/b"])
        perform(["/b"])
        #expect(store.state(for: "/a") == nil)
        perform([])
        #expect(watched == DirectoryWatchSet())
        store.reset()
    }
}
