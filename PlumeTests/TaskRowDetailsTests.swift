import Testing
import Foundation
@testable import Plume

@MainActor
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

@MainActor
struct TaskRowDirectoryGroupingTests {
    @Test func twoTabsInOneFolderCollapseToOneGroup() {
        let directories = TaskRowDetails.distinctDirectories(
            agentTabDirectories: ["/Users/me/Plume", "/Users/me/Plume"],
            fallbackDirectory: "/Users/me/Plume"
        )
        #expect(directories == ["/Users/me/Plume"])
    }

    @Test func twoFoldersGiveTwoGroupsInTabOrder() {
        let directories = TaskRowDetails.distinctDirectories(
            agentTabDirectories: ["/Users/me/Plume", "/Users/me/Other", "/Users/me/Plume"],
            fallbackDirectory: "/Users/me/Plume"
        )
        #expect(directories == ["/Users/me/Plume", "/Users/me/Other"])
    }

    @Test func aTaskWithNoReportingAgentTabFallsBackToAnotherTabsFolder() {
        let directories = TaskRowDetails.distinctDirectories(
            agentTabDirectories: [nil, nil],
            fallbackDirectory: "/Users/me/Plume"
        )
        #expect(directories == ["/Users/me/Plume"])
    }

    @Test func aTaskWithNoFolderAtAllHasNoGroups() {
        #expect(TaskRowDetails.distinctDirectories(agentTabDirectories: [], fallbackDirectory: nil).isEmpty)
    }

    /// The row must watch the folder a folderless agent's header borrows.
    /// A terminal's folder follows `cd`, so beside an agent that has a folder,
    /// a folderless one borrows only what an agent tab saved.
    @Test func aFolderlessAgentAmongOthersTakesASavedAgentFolder() {
        let directories = TaskRowDetails.agentTabDirectories(
            ["/Users/me/Other", nil, ""],
            savedAgentDirectory: "/Users/me/Saved",
            taskDirectory: "/Users/me/Terminal"
        )
        #expect(directories == ["/Users/me/Other", "/Users/me/Saved", "/Users/me/Saved"])
        #expect(TaskRowDetails.agentTabDirectories(
            ["/Users/me/Other", nil],
            savedAgentDirectory: nil,
            taskDirectory: "/Users/me/Terminal"
        ) == ["/Users/me/Other", nil])
    }

    @Test func agentsWithNoFolderAllTakeTheTaskFolder() {
        let directories = TaskRowDetails.agentTabDirectories(
            [nil, ""],
            savedAgentDirectory: nil,
            taskDirectory: "/Users/me/Plume"
        )
        #expect(directories == ["/Users/me/Plume", "/Users/me/Plume"])
        #expect(TaskRowDetails.distinctDirectories(agentTabDirectories: directories, fallbackDirectory: "/Users/me/Plume")
            == ["/Users/me/Plume"])
    }
}

@MainActor
struct TaskRowAgentTabFilterTests {
    /// A terminal's cwd follows `cd`, so it must not contribute a group.
    @Test func terminalTabsAreExcluded() throws {
        let task = WorkTask(title: "T", orderIndex: 0)
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
            fallbackDirectory: nil
        )
        #expect(directories == ["/Users/me/Plume"])
    }
}

@MainActor
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

@MainActor
struct TaskRowLinearLinesTests {
    private func linked(_ id: String, role: LinearLinkRole = .working) -> LinkedLinearIssue {
        LinkedLinearIssue(identifier: id, role: role, sources: [.manual], subagents: [], touchedByMainAgent: false)
    }

    @Test func linearLinesCapAtTwoWithAnOverflowCount() {
        let lines = TaskRowDetails.linearLines(
            [linked("PLUME-1"), linked("PLUME-2"), linked("PLUME-3"), linked("PLUME-4")],
            states: { _ in nil }
        )
        #expect(lines == [
            .linearIssue(identifier: "PLUME-1", state: nil),
            .linearIssue(identifier: "PLUME-2", state: nil),
            .linearOverflow(2),
        ])
    }

    @Test func exactlyTwoIssuesHaveNoOverflowLine() {
        let lines = TaskRowDetails.linearLines([linked("PLUME-1"), linked("PLUME-2")], states: { _ in nil })
        #expect(lines.count == 2)
    }

    @Test func mentionedIssuesTakeNoLine() {
        let lines = TaskRowDetails.linearLines(
            [linked("PLUME-1", role: .mentioned), linked("PLUME-2")],
            states: { _ in .loading }
        )
        #expect(lines == [.linearIssue(identifier: "PLUME-2", state: .loading)])
    }

    @Test func linearAccessibilityTextNamesStateAndTitle() {
        let issue = LinearTestFixtures.issue("PLUME-102", title: "Integrate")
        #expect(TaskRowDetails.accessibilityText(.linearIssue(identifier: "PLUME-102", state: .issue(issue)))
            == "Linear PLUME-102, Todo, Integrate")
        #expect(TaskRowDetails.accessibilityText(.linearIssue(identifier: "PLUME-102", state: .failed("x")))
            == "Linear PLUME-102, offline")
        #expect(TaskRowDetails.accessibilityText(.linearIssue(identifier: "PLUME-102", state: .noWorkspace))
            == "Linear PLUME-102, no workspace")
        #expect(TaskRowDetails.accessibilityText(.linearOverflow(3)) == "3 more Linear issues")
    }

    @Test func eachFailureHasItsOwnWord() {
        #expect(TaskRowDetails.linearStatusWord(.notFound) == "not found")
        #expect(TaskRowDetails.linearStatusWord(.failed("x")) == "offline")
        #expect(TaskRowDetails.linearStatusWord(.unauthorized) == "key rejected")
        #expect(TaskRowDetails.linearStatusWord(.rateLimited(until: .now)) == "rate limited")
        #expect(TaskRowDetails.linearStatusWord(.noWorkspace) == "no workspace")
        #expect(TaskRowDetails.linearStatusWord(.stale(LinearTestFixtures.issue("PLUME-1"), reason: "x")) == nil)
    }
}

@MainActor
struct TaskRowPinnedPullRequestLinesTests {
    private func ref(_ number: Int) -> PullRequestReference {
        PullRequestReference(owner: "a", repo: "b", number: number)
    }

    private func group(_ state: PullRequestFetchState?) -> TaskRowDetails.DirectoryGroup {
        TaskRowDetails.DirectoryGroup(directory: "/a", pullRequest: state)
    }

    private func branchPullRequest(_ url: String) -> PullRequestFetchState {
        .pullRequest(PullRequest(number: 1, state: .open, isDraft: false, url: url))
    }

    @Test func pinnedPullRequestsCapAtTwoWithAnOverflowCount() {
        let lines = TaskRowDetails.pinnedPullRequestLines(
            [ref(1), ref(2), ref(3)],
            groups: [],
            details: { _ in nil }
        )
        #expect(lines == [
            .pinnedPullRequest(ref(1), detail: nil),
            .pinnedPullRequest(ref(2), detail: nil),
            .pinnedPullRequestOverflow(1),
        ])
    }

    @Test func theBranchsOwnPullRequestTakesNoSecondLine() {
        let lines = TaskRowDetails.pinnedPullRequestLines(
            [ref(1), ref(2)],
            groups: [group(branchPullRequest("https://github.com/A/B/pull/1")), group(.noPR)],
            details: { _ in .unavailable }
        )
        #expect(lines == [.pinnedPullRequest(ref(2), detail: .unavailable)])
    }

    @Test func pinnedLinesWaitForEveryBranchPullRequestToLoad() {
        for state in [nil, PullRequestFetchState.loading] {
            let lines = TaskRowDetails.pinnedPullRequestLines(
                [ref(1), ref(2)],
                groups: [group(.noPR), group(state)],
                details: { _ in nil }
            )
            #expect(lines.isEmpty)
        }
    }

    @Test func pinnedPullRequestAccessibilityText() {
        let entry = MentionCandidate.PullRequestEntry(
            number: 4, title: "Fix it", url: ref(4).url, state: .open, isDraft: false, updatedAt: nil
        )
        #expect(TaskRowDetails.accessibilityText(.pinnedPullRequest(ref(4), detail: .pullRequest(entry)))
            == "Pull request 4, Fix it")
        #expect(TaskRowDetails.accessibilityText(.pinnedPullRequest(ref(4), detail: nil)) == "Pull request 4")
        #expect(TaskRowDetails.accessibilityText(.pinnedPullRequestOverflow(2)) == "2 more pull requests")
    }
}

/// A task with one agent keeps the plain directory lines; a task with several
/// heads each agent's lines with its own header and shows only what differs
/// from the agent above.
@MainActor
struct TaskRowAgentLinesTests {
    private let open = PullRequestFetchState.pullRequest(PullRequest(number: 42, state: .open, isDraft: false))

    private func agent(
        _ title: String,
        _ directory: String?,
        branch: String? = nil,
        pullRequest: PullRequestFetchState? = nil,
        status: TaskStatus = .awaitingReply
    ) -> TaskRowDetails.AgentGroup {
        TaskRowDetails.AgentGroup(
            header: TaskRowDetails.AgentHeader(tabID: UUID(), title: title, status: status),
            workspace: TaskRowDetails.DirectoryGroup(directory: directory, branch: branch, pullRequest: pullRequest)
        )
    }

    private func headers(_ lines: [TaskRowDetails.Line]) -> [String] {
        lines.compactMap { if case .agentHeader(let header) = $0 { header.title } else { nil } }
    }

    @Test func oneAgentKeepsThePlainDirectoryLines() {
        let lines = TaskRowDetails.lines(groups: [TaskRowDetails.DirectoryGroup(
            directory: "/Users/me/Plume",
            branch: "ryanm/fix-login",
            pullRequest: open,
            checkout: CheckoutFacts(projectRoot: "/Users/me/Plume", checkoutRoot: "/Users/me/Plume")
        )])
        #expect(lines == [
            .project("Plume"),
            .branch("ryanm/fix-login", isWorktree: false, accompaniedBy: nil),
            .pullRequest(directory: "/Users/me/Plume", state: open),
        ])
    }

    @Test func aSecondAgentInTheSameFolderTakesOnlyItsHeader() {
        let first = agent("One", "/Users/me/Plume", branch: "main", pullRequest: open)
        let second = agent("Two", "/Users/me/Plume", branch: "main", pullRequest: open)
        let lines = TaskRowDetails.lines(agents: [first, second])
        #expect(lines == [
            .agentHeader(first.header),
            .project("Plume"),
            .branch("main", accompaniedBy: nil),
            .pullRequest(directory: "/Users/me/Plume", state: open),
            .agentHeader(second.header),
        ])
    }

    @Test func anAgentInAnotherFolderRepeatsProjectAndBranch() {
        let first = agent("One", "/Users/me/Plume", branch: "main")
        let second = agent("Two", "/Users/me/Other", branch: "main")
        let lines = TaskRowDetails.lines(agents: [first, second])
        #expect(lines == [
            .agentHeader(first.header), .project("Plume"), .branch("main", accompaniedBy: nil),
            .agentHeader(second.header), .project("Other"), .branch("main", accompaniedBy: nil),
        ])
    }

    /// Two worktrees of one project share the header, so only the branch and
    /// what follows it repeat.
    @Test func aDifferentBranchOfTheSameProjectRepeatsFromTheBranch() {
        let project = "/Users/me/Plume"
        func worktree(_ title: String, _ name: String, pullRequest: PullRequestFetchState?) -> TaskRowDetails.AgentGroup {
            var group = agent(title, "/wt/\(name)", branch: "ryanm/\(name)", pullRequest: pullRequest)
            group.workspace.checkout = CheckoutFacts(projectRoot: project, checkoutRoot: "/wt/\(name)")
            return group
        }
        let first = worktree("One", "a", pullRequest: nil)
        let second = worktree("Two", "b", pullRequest: open)
        let lines = TaskRowDetails.lines(agents: [first, second])
        #expect(lines == [
            .agentHeader(first.header), .project("Plume"), .branch("ryanm/a", isWorktree: true, accompaniedBy: nil),
            .agentHeader(second.header), .branch("ryanm/b", isWorktree: true, accompaniedBy: nil),
            .pullRequest(directory: "/wt/b", state: open),
        ])
    }

    @Test func returningToAnEarlierFolderRepeatsIt() {
        let lines = TaskRowDetails.lines(agents: [
            agent("One", "/Users/me/Plume"),
            agent("Two", "/Users/me/Other"),
            agent("Three", "/Users/me/Plume"),
        ])
        #expect(lines.filter { if case .project = $0 { true } else { false } }
            == [.project("Plume"), .project("Other"), .project("Plume")])
        #expect(headers(lines) == ["One", "Two", "Three"])
    }

    @Test func anAgentWithNoFolderTakesOnlyItsHeader() {
        let lone = agent("Lone", nil)
        let two = agent("Two", "/Users/me/Plume", branch: "main")
        #expect(TaskRowDetails.lines(agents: [lone, two]) == [
            .agentHeader(lone.header),
            .agentHeader(two.header), .project("Plume"), .branch("main", accompaniedBy: nil),
        ])
        #expect(TaskRowDetails.lines(agents: [lone]) == [.agentHeader(lone.header)])
    }

    @Test func anAgentWithNoFolderAfterOneWithAFolderTakesOnlyItsHeader() {
        let one = agent("One", "/Users/me/Plume", branch: "main")
        let lone = agent("Lone", nil)
        #expect(TaskRowDetails.lines(agents: [one, lone]) == [
            .agentHeader(one.header), .project("Plume"), .branch("main", accompaniedBy: nil),
            .agentHeader(lone.header),
        ])
    }

    /// Two clones on the same branch read identically, but they are not one
    /// folder, so the second must not look like it shares the first's.
    @Test func aSecondCloneThatReadsTheSameRepeatsItsLines() {
        let first = agent("One", "/Users/me/Plume", branch: "main")
        let second = agent("Two", "/Users/me/elsewhere/Plume", branch: "main")
        #expect(TaskRowDetails.lines(agents: [first, second]) == [
            .agentHeader(first.header), .project("Plume"), .branch("main", accompaniedBy: nil),
            .agentHeader(second.header), .project("Plume"), .branch("main", accompaniedBy: nil),
        ])
    }

    @Test func twoClonesWithTheSamePullRequestBothShowTheirLines() {
        let first = agent("One", "/Users/me/Plume", branch: "main", pullRequest: open)
        let second = agent("Two", "/Users/me/elsewhere/Plume", branch: "main", pullRequest: open)
        #expect(TaskRowDetails.lines(agents: [first, second]) == [
            .agentHeader(first.header), .project("Plume"), .branch("main", accompaniedBy: nil),
            .pullRequest(directory: "/Users/me/Plume", state: open),
            .agentHeader(second.header), .project("Plume"), .branch("main", accompaniedBy: nil),
            .pullRequest(directory: "/Users/me/elsewhere/Plume", state: open),
        ])
    }

    /// Only the pull request differs, but a lone pull request line under the
    /// header would read as the first clone's folder.
    @Test func aCloneWithAPullRequestTheOtherLacksShowsItsLines() {
        let first = agent("One", "/Users/me/Plume", branch: "main")
        let second = agent("Two", "/Users/me/elsewhere/Plume", branch: "main", pullRequest: open)
        #expect(TaskRowDetails.lines(agents: [first, second]) == [
            .agentHeader(first.header), .project("Plume"), .branch("main", accompaniedBy: nil),
            .agentHeader(second.header), .project("Plume"), .branch("main", accompaniedBy: nil),
            .pullRequest(directory: "/Users/me/elsewhere/Plume", state: open),
        ])
        #expect(TaskRowDetails.lines(agents: [second, first]) == [
            .agentHeader(second.header), .project("Plume"), .branch("main", accompaniedBy: nil),
            .pullRequest(directory: "/Users/me/elsewhere/Plume", state: open),
            .agentHeader(first.header), .project("Plume"), .branch("main", accompaniedBy: nil),
        ])
    }

    @Test func twoAgentsInOneFolderShareAPullRequestLine() {
        let first = agent("One", "/Users/me/Plume", branch: "main")
        let second = agent("Two", "/Users/me/Plume", branch: "main", pullRequest: open)
        #expect(TaskRowDetails.lines(agents: [first, second]) == [
            .agentHeader(first.header), .project("Plume"), .branch("main", accompaniedBy: nil),
            .agentHeader(second.header), .pullRequest(directory: "/Users/me/Plume", state: open),
        ])
    }

    @Test func repeatedTitlesAreNumberedOnEveryCopy() {
        #expect(TaskRowDetails.distinctLabels(["Chat", "Fix", "Chat", "Chat"]) == ["Chat #1", "Fix", "Chat #2", "Chat #3"])
    }

    @Test func linesDifferingKeepsEverythingFromTheFirstDifference() {
        let previous: [TaskRowDetails.Line] = [.project("P"), .branch("a"), .text("x")]
        #expect(TaskRowDetails.linesDiffering([.project("P"), .branch("b"), .text("x")], from: previous)
            == [.branch("b"), .text("x")])
        #expect(TaskRowDetails.linesDiffering(previous, from: previous).isEmpty)
        #expect(TaskRowDetails.linesDiffering(previous, from: []) == previous)
        #expect(TaskRowDetails.linesDiffering([.project("P"), .branch("a"), .text("x"), .text("y")], from: previous)
            == [.text("y")])
    }

    /// An agent with no folder never gets a pull request, so waiting on it
    /// would hide pinned lines forever.
    @Test func pinnedLinesIgnoreGroupsWithoutADirectory() {
        let reference = PullRequestReference(owner: "a", repo: "b", number: 7)
        let lines = TaskRowDetails.pinnedPullRequestLines(
            [reference],
            groups: [
                TaskRowDetails.DirectoryGroup(directory: "/a", pullRequest: .noPR),
                TaskRowDetails.DirectoryGroup(directory: nil),
                TaskRowDetails.DirectoryGroup(directory: ""),
            ],
            details: { _ in nil }
        )
        #expect(lines == [.pinnedPullRequest(reference, detail: nil)])
    }

    @Test func theHeaderReachesTheAccessibilityLabel() {
        let header = TaskRowDetails.AgentHeader(tabID: UUID(), title: "Fix login", status: .working, isUnread: true)
        #expect(header.statusText == "Working, unread")
        #expect(TaskRowDetails.accessibilityText(.agentHeader(header)) == "Fix login, Working, unread")
    }

    @Test func directoryLinesNameTheAgentTheySitUnder() {
        let first = agent("One", "/Users/me/Plume", branch: "main", pullRequest: open)
        let second = agent("Two", "/Users/me/Other", branch: "dev")
        let lines = TaskRowDetails.lines(agents: [first, second])
        let owners = TaskRowDetails.owningAgentLabels(lines)
        #expect(zip(lines, owners).map { line, owner in
            TaskRowDetails.controlLabel(line).map { "\($0) @ \(owner ?? "-")" } ?? "header"
        } == [
            "header",
            "Plume @ One",
            "main @ One",
            "\(PullRequestChipContent.accessibilityText(for: open) ?? "") @ One",
            "header",
            "Other @ Two",
            "dev @ Two",
        ])
    }

    @Test func aOneAgentRowNamesNoAgent() {
        let lines: [TaskRowDetails.Line] = [.text("note"), .project("Plume"), .branch("main")]
        #expect(TaskRowDetails.owningAgentLabels(lines) == [nil, nil, nil])
        #expect(TaskRowDetails.controlValue(.project("Plume"), owner: nil) == nil)
    }

    @Test func aLinesValueTellsTwoLinesWithTheSameTextApart() {
        #expect(TaskRowDetails.controlValue(.project("Plume"), owner: "Chat #2") == "agent: Chat #2")
        #expect(TaskRowDetails.controlValue(.branch("main", isWorktree: true, accompaniedBy: open), owner: "One")
            == "agent: One; worktree; \(PullRequestChipContent.accessibilityText(for: open) ?? "")")
        #expect(TaskRowDetails.controlValue(.pullRequest(directory: "/Users/me/Plume", state: open), owner: nil)
            == "directory: /Users/me/Plume")
        #expect(TaskRowDetails.controlLabel(.linearOverflow(2)) == nil)
    }
}
