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
        for fixture in SidebarFixtureCatalog.cases {
            tasks.append(seedTask(for: fixture, in: context, group: group, siblings: tasks))
        }
        tasks.append(seedMultiDirectoryTask(in: context, group: group, siblings: tasks))
    }

    private static func seedTask(
        for fixture: SidebarFixtureCase,
        in context: ModelContext,
        group: TaskGroup,
        siblings: [WorkTask]
    ) -> WorkTask {
        let task = TaskStore.createTask(in: context, title: fixture.name, group: group, siblings: siblings)
        task.workingDirectoryPath = "/tmp/plume-fixtures/\(fixture.directory)"
        task.workspaceKind = .directory
        task.branchName = fixture.branch
        task.lastStatus = fixture.status
        if let agentTab = task.orderedTabs.first(where: { $0.kind == .agent }) {
            StatusEngine.shared.setStatus(fixture.status, taskID: task.id, tabID: agentTab.id)
        }
        if let directory = task.workingDirectoryPath {
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
        }
        return task
    }

    /// One task with several agent tabs pointed at different directories, so
    /// the sidebar's repeated per-directory groups have more than one
    /// directory to repeat over.
    private static func seedMultiDirectoryTask(
        in context: ModelContext,
        group: TaskGroup,
        siblings: [WorkTask]
    ) -> WorkTask {
        let task = TaskStore.createTask(in: context, title: "multi-directory", group: group, siblings: siblings)
        task.workspaceKind = .directory

        let directories = [
            "fixture-multi-dir-alpha",
            "fixture-multi-dir-beta",
            "fixture-multi-dir-gamma",
        ]
        task.workingDirectoryPath = "/tmp/plume-fixtures/\(directories[0])"

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
}
#endif
