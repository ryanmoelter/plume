#if DEBUG
import Foundation
import SwiftData

/// Seeds a "Fixtures" group covering every sidebar row state at once, from
/// `SidebarFixtureCatalog`, so every visual state can be eyeballed without a
/// network call or a real repository.
///
/// Adding a new fixture — a new PR state, a problematic chat transcript —
/// means adding a new `SidebarFixtureCase` (or, for a transcript, a sibling
/// seeding step here that points an agent tab's `sessionJSONLPath` at a
/// bundled `.jsonl`); this file's job is only to turn the catalog into store
/// state.
@MainActor
enum SidebarFixtures {
    static let groupName = "Fixtures (Debug)"

    /// Re-running drops the previous "Fixtures" group first, so pressing the
    /// button twice replaces rather than duplicates.
    static func seed(in context: ModelContext, existingGroups: [TaskGroup]) {
        if let existing = existingGroups.first(where: { $0.name == groupName }) {
            for task in existing.tasks {
                TaskStore.delete(task, in: context)
            }
            context.delete(existing)
        }

        let group = TaskStore.createGroup(in: context, name: groupName, existing: existingGroups)

        var tasks: [WorkTask] = []
        if ProcessInfo.processInfo.environment["PLUME_SEED_SIDEBAR_FIXTURES"] != "linear" {
            for fixture in SidebarFixtureCatalog.cases {
                tasks.append(seedTask(for: fixture, in: context, group: group, siblings: tasks))
            }
            tasks.append(seedMultiDirectoryTask(in: context, group: group, siblings: tasks))
            tasks.append(seedSameDirectoryTask(in: context, group: group, siblings: tasks))
            tasks.append(seedMixedDirectoryTask(in: context, group: group, siblings: tasks))
        }
        tasks.append(contentsOf: seedLinearTasks(in: context, group: group, siblings: tasks))
    }

    private static func seedTask(
        for fixture: SidebarFixtureCase,
        in context: ModelContext,
        group: TaskGroup,
        siblings: [WorkTask]
    ) -> WorkTask {
        let task = TaskStore.createTask(in: context, title: fixture.name, group: group, siblings: siblings)
        let directory = "/tmp/plume-fixtures/\(fixture.directory)"
        task.tabs.first?.workspace = .directory(directory, branchName: fixture.branch)
        task.lastStatus = fixture.status
        if let agentTab = task.orderedTabs.first(where: { $0.kind == .agent }) {
            StatusEngine.shared.setStatus(fixture.status, taskID: task.id, tabID: agentTab.id)
        }
        if let state = fixture.pullRequestState {
            PullRequestStore.shared.seedFixture(directory: directory, state: state)
        }
        if let checkout = fixture.checkout {
            CheckoutFactsStore.shared.seedFixture(directory: directory, facts: checkout)
        }
        // Without this the row takes a real git watch on a path that does
        // not exist, and the failed lookup publishes a nil branch over the
        // fixture's.
        GitStateStore.shared.seedFixture(
            directory: directory,
            state: GitState(
                branch: fixture.branch,
                upstream: fixture.pullRequestState == .localOnly ? nil : "origin/\(fixture.branch ?? "")",
                ahead: 0,
                behind: 0,
                isDirty: false
            )
        )
        return task
    }

    /// One task with several agent tabs in different directories, so every
    /// folder line shows under its own agent's header.
    private static func seedMultiDirectoryTask(
        in context: ModelContext,
        group: TaskGroup,
        siblings: [WorkTask]
    ) -> WorkTask {
        let task = TaskStore.createTask(in: context, title: "multi-directory", group: group, siblings: siblings)

        let directories = [
            "fixture-multi-dir-alpha",
            "fixture-multi-dir-beta",
            "fixture-multi-dir-gamma",
        ]
        task.tabs.first?.workspace = .directory("/tmp/plume-fixtures/\(directories[0])")

        let firstTab = task.orderedTabs.first(where: { $0.kind == .agent })
        let tabs = [firstTab].compactMap { $0 }
            + (1..<directories.count).map { _ in TaskStore.addTab(to: task, kind: .agent, in: context) }

        for (tab, name) in zip(tabs, directories) {
            let path = "/tmp/plume-fixtures/\(name)"
            TabDirectoryStore.shared.setDirectory(path, forTab: tab)
            PullRequestStore.shared.seedFixture(directory: path, state: .pullRequest(
                PullRequest(
                    number: 900 + (directories.firstIndex(of: name) ?? 0),
                    state: .open,
                    isDraft: false,
                    title: "Fixture PR for \(name)",
                    checkContexts: [CheckContext(name: "build", conclusion: "SUCCESS")]
                )
            ))
            GitStateStore.shared.seedFixture(
                directory: path,
                state: GitState(
                    branch: "ryanm/\(name)",
                    upstream: "origin/ryanm/\(name)",
                    ahead: 0,
                    behind: 0,
                    isDirty: false
                )
            )
        }
        return task
    }

    /// One task with three agent tabs in one folder, each with its own title
    /// and status, so the row shows the folder once at the task level and
    /// bare agent headers under it.
    private static func seedSameDirectoryTask(
        in context: ModelContext,
        group: TaskGroup,
        siblings: [WorkTask]
    ) -> WorkTask {
        let shared = "/tmp/plume-fixtures/fixture-same-dir-shared"
        return seedAgentsTask(
            "same-directory",
            agents: [
                (shared, "Refactor the sidebar row", .working),
                (shared, "Write the sidebar tests", .questionAsked),
                (shared, "Update the docs", .awaitingReply),
            ],
            folders: [shared: ("ryanm/same-dir-shared", fixturePullRequest(910, "Fixture PR for the shared folder"), nil)],
            in: context,
            group: group,
            siblings: siblings
        )
    }

    /// Two worktrees of one project, so the row shows the project once and
    /// each agent's branch and pull request under its own header.
    private static func seedMixedDirectoryTask(
        in context: ModelContext,
        group: TaskGroup,
        siblings: [WorkTask]
    ) -> WorkTask {
        let project = "/tmp/plume-fixtures/fixture-mixed-project"
        let first = "/tmp/plume-fixtures/fixture-mixed-wt-alpha"
        let second = "/tmp/plume-fixtures/fixture-mixed-wt-beta"
        return seedAgentsTask(
            "mixed-directory",
            agents: [
                (first, "Build the parser", .working),
                (second, "Wire up the view", .done),
            ],
            folders: [
                first: ("ryanm/mixed-alpha", fixturePullRequest(920, "Fixture PR for alpha"),
                        CheckoutFacts(projectRoot: project, checkoutRoot: first)),
                second: ("ryanm/mixed-beta", .noPR, CheckoutFacts(projectRoot: project, checkoutRoot: second)),
            ],
            in: context,
            group: group,
            siblings: siblings
        )
    }

    private static func fixturePullRequest(_ number: Int, _ title: String) -> PullRequestFetchState {
        .pullRequest(PullRequest(
            number: number,
            state: .open,
            isDraft: false,
            title: title,
            checkContexts: [CheckContext(name: "build", conclusion: "SUCCESS")]
        ))
    }

    private static func seedAgentsTask(
        _ title: String,
        agents: [(directory: String, title: String, status: TaskStatus)],
        folders: [String: (branch: String, pullRequest: PullRequestFetchState, checkout: CheckoutFacts?)],
        in context: ModelContext,
        group: TaskGroup,
        siblings: [WorkTask]
    ) -> WorkTask {
        let task = TaskStore.createTask(in: context, title: title, group: group, siblings: siblings)
        if let first = agents.first {
            task.tabs.first?.workspace = .directory(first.directory, branchName: folders[first.directory]?.branch)
        }

        let firstTab = task.orderedTabs.first(where: { $0.kind == .agent })
        let tabs = [firstTab].compactMap { $0 }
            + (1..<agents.count).map { _ in TaskStore.addTab(to: task, kind: .agent, in: context) }

        for (tab, agent) in zip(tabs, agents) {
            tab.title = agent.title
            tab.lastStatus = agent.status
            TabDirectoryStore.shared.setDirectory(agent.directory, forTab: tab)
            StatusEngine.shared.setStatus(agent.status, taskID: task.id, tabID: tab.id)
        }
        for (directory, folder) in folders {
            PullRequestStore.shared.seedFixture(directory: directory, state: folder.pullRequest)
            if let checkout = folder.checkout {
                CheckoutFactsStore.shared.seedFixture(directory: directory, facts: checkout)
            }
            GitStateStore.shared.seedFixture(
                directory: directory,
                state: GitState(
                    branch: folder.branch,
                    upstream: "origin/\(folder.branch)",
                    ahead: 0,
                    behind: 0,
                    isDirty: false
                )
            )
        }
        return task
    }

    /// A task whose branch names an issue, and one with three manual links,
    /// to show the line cap and the overflow count.
    private static func seedLinearTasks(
        in context: ModelContext,
        group: TaskGroup,
        siblings: [WorkTask]
    ) -> [WorkTask] {
        LinearStore.shared.seedFixtureTeamKeys(["PLUME"])
        func issue(_ identifier: String, _ title: String, _ name: String, _ type: LinearStateType, _ color: String) {
            LinearStore.shared.seedFixture(
                identifier: identifier,
                state: .issue(LinearIssue(
                    identifier: identifier,
                    title: title,
                    url: "https://linear.app/fixture/issue/\(identifier)",
                    stateName: name,
                    stateType: type,
                    stateColor: color,
                    assigneeName: nil,
                    teamKey: "PLUME"
                ))
            )
        }
        issue("PLUME-102", "Integrate with Linear", "In Progress", .started, "#f2c94c")
        issue("PLUME-103", "Fixture todo", "Todo", .unstarted, "#e2e2e2")
        issue("PLUME-104", "Fixture done", "Done", .completed, "#5e6ad2")
        LinearStore.shared.seedFixture(identifier: "PLUME-105", state: .failed("Fixture: offline"))

        func seed(_ name: String, branch: String) -> WorkTask {
            let task = TaskStore.createTask(in: context, title: name, group: group, siblings: siblings)
            let directory = "/tmp/plume-fixtures/fixture-\(name)"
            task.tabs.first?.workspace = .directory(directory, branchName: branch)
            GitStateStore.shared.seedFixture(
                directory: directory,
                state: GitState(branch: branch, upstream: nil, ahead: 0, behind: 0, isDirty: false)
            )
            return task
        }

        let branched = seed("linear-branch", branch: "ryanm/plume-102-integrate-with-linear")
        let overflow = seed("linear-overflow", branch: "ryanm/linear-overflow")
        for identifier in ["PLUME-103", "PLUME-104", "PLUME-105"] {
            _ = TaskStore.linkLinearIssue(identifier, to: overflow)
        }
        return [branched, overflow]
    }
}
#endif
