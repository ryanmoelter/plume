import Testing
import Foundation
import SwiftData
@testable import Plume

/// What `Importer` writes into the store, and what it refuses to write twice:
/// a task per candidate, dense ordering, and at most one tab per session id.
@MainActor
struct ImporterTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    private func candidate(
        stableID: String = "cmux:one",
        title: String = "Build the widget",
        directory: String = "/Users/example/Code/widget",
        groupName: String? = nil,
        tabs: [ImportTabPlan] = [.agentPlan()],
        kind: WorkspaceKind = .directory,
        repoPath: String? = "/Users/example/Code/widget",
        branchName: String? = nil,
        rejection: ImportRejection? = nil
    ) -> ImportCandidate {
        ImportCandidate(
            stableID: stableID,
            title: title,
            workingDirectoryPath: directory,
            groupName: groupName,
            tabs: tabs,
            workspace: ImportWorkspacePlan(
                kind: kind,
                repoPath: repoPath,
                branchName: branchName,
                isValidated: true
            ),
            rejection: rejection
        )
    }

    // MARK: - Creating

    @Test func eachCandidateBecomesATask() throws {
        let context = try makeContext()

        let created = Importer.importing(
            [candidate(stableID: "cmux:one"), candidate(stableID: "cmux:two", title: "Notes")],
            into: .ungrouped,
            in: context
        )

        #expect(created.count == 2)
        #expect(created.map(\.title) == ["Build the widget", "Notes"])
        #expect(created.allSatisfy { $0.group == nil })
    }

    @Test func theWorkspaceIsAdoptedAsPlanned() throws {
        let context = try makeContext()

        let created = Importer.importing(
            [candidate(
                directory: "/Users/example/Code/widget/.worktrees/fix",
                kind: .worktree,
                repoPath: "/Users/example/Code/widget",
                branchName: "fix-crash"
            )],
            into: .ungrouped,
            in: context
        )

        let task = try #require(created.first)
        #expect(task.workspaceKind == .worktree)
        #expect(task.workingDirectoryPath == "/Users/example/Code/widget/.worktrees/fix")
        #expect(task.repoPath == "/Users/example/Code/widget")
        #expect(task.branchName == "fix-crash")
    }

    @Test func orderIndexStaysDenseAcrossABatch() throws {
        let context = try makeContext()

        let created = Importer.importing(
            (1...4).map { candidate(stableID: "cmux:\($0)") },
            into: .ungrouped,
            in: context
        )

        #expect(created.map(\.orderIndex) == [0, 1, 2, 3])
    }

    @Test func anImportedBatchOrdersAfterExistingTasks() throws {
        let context = try makeContext()
        _ = TaskStore.createTask(in: context, title: "Existing", siblings: [])

        let created = Importer.importing([candidate()], into: .ungrouped, in: context)

        #expect(created.first?.orderIndex == 1)
    }

    // MARK: - Tabs

    @Test func anAgentPlanBecomesAHeadlessAgentTab() throws {
        let context = try makeContext()

        let created = Importer.importing(
            [candidate(tabs: [.agentPlan(sessionID: "session-a", transcript: "/tmp/a.jsonl")])],
            into: .ungrouped,
            in: context
        )

        let tab = try #require(created.first?.tabs.first)
        #expect(tab.kind == .agent)
        #expect(tab.transport == .headless)
        #expect(tab.agentSessionID == "session-a")
        #expect(tab.sessionJSONLPath == "/tmp/a.jsonl")
    }

    @Test func eachTabKeepsItsOwnDirectory() throws {
        let context = try makeContext()

        let created = Importer.importing(
            [candidate(tabs: [.agentPlan(directory: "/Users/example/Code/widget/.worktrees/fix")])],
            into: .ungrouped,
            in: context
        )

        #expect(created.first?.tabs.first?.workingDirectoryPath
            == "/Users/example/Code/widget/.worktrees/fix")
    }

    @Test func tabOrderFollowsTheSourcePaneOrder() throws {
        let context = try makeContext()

        let created = Importer.importing(
            [candidate(tabs: [
                .terminalPlan(title: "server"),
                .agentPlan(sessionID: "session-a"),
                .terminalPlan(title: "logs"),
            ])],
            into: .ungrouped,
            in: context
        )

        let task = try #require(created.first)
        #expect(task.orderedTabs.map(\.title) == ["server", nil, "logs"])
        #expect(task.orderedTabs.map(\.orderIndex) == [0, 1, 2])
    }

    /// Selection opens on the conversation, not on whatever pane came first.
    @Test func selectionLandsOnTheFirstAgentTab() throws {
        let context = try makeContext()

        let created = Importer.importing(
            [candidate(tabs: [.terminalPlan(title: "server"), .agentPlan(sessionID: "session-a")])],
            into: .ungrouped,
            in: context
        )

        let task = try #require(created.first)
        let agentTab = try #require(task.orderedTabs.first { $0.kind == .agent })
        #expect(task.selectedTabID == agentTab.id)
        #expect(task.lastFocusedAgentTabID == agentTab.id)
    }

    @Test func aTaskOfOnlyTerminalsSelectsItsFirstTab() throws {
        let context = try makeContext()

        let created = Importer.importing(
            [candidate(tabs: [.terminalPlan(title: "server"), .terminalPlan(title: "logs")])],
            into: .ungrouped,
            in: context
        )

        let task = try #require(created.first)
        #expect(task.selectedTabID == task.orderedTabs.first?.id)
        #expect(task.lastFocusedAgentTabID == nil)
    }

    // MARK: - Duplicates

    @Test func reimportingTheSameCandidateCreatesNothing() throws {
        let context = try makeContext()
        let candidates = [candidate(stableID: "cmux:one")]

        _ = Importer.importing(candidates, into: .ungrouped, in: context)
        let second = Importer.importing(candidates, into: .ungrouped, in: context)

        #expect(second.isEmpty)
        let tasks = try context.fetch(FetchDescriptor<WorkTask>())
        #expect(tasks.count == 1)
    }

    /// Archiving an imported task must not make the next import bring it back.
    @Test func anArchivedImportStillCountsAsImported() throws {
        let context = try makeContext()
        let candidates = [candidate(stableID: "cmux:one")]
        let first = Importer.importing(candidates, into: .ungrouped, in: context)
        try #require(first.count == 1)
        TaskStore.archive(first[0])

        let second = Importer.importing(candidates, into: .ungrouped, in: context)

        #expect(second.isEmpty)
    }

    @Test func alreadyImportedCandidatesAreMarkedForTheSheet() throws {
        let context = try makeContext()
        _ = Importer.importing([candidate(stableID: "cmux:one")], into: .ungrouped, in: context)

        let marked = Importer.marking(
            [candidate(stableID: "cmux:one"), candidate(stableID: "cmux:two")],
            alreadyImported: Importer.alreadyImported(in: context)
        )

        #expect(marked[0].isAlreadyImported)
        #expect(!marked[1].isAlreadyImported)
        #expect(!marked[0].isImportable)
    }

    // MARK: - The resume invariant

    /// `--resume` is not a fork: a session another tab holds becomes a
    /// terminal tab rather than a second claimant.
    @Test func aSessionHeldByAnExistingTabIsNotClaimedAgain() throws {
        let context = try makeContext()
        let existing = TaskStore.createTask(in: context, siblings: [])
        existing.tabs[0].agentSessionID = "session-a"

        let created = Importer.importing(
            [candidate(tabs: [.agentPlan(sessionID: "session-a")])],
            into: .ungrouped,
            in: context
        )

        let tab = try #require(created.first?.tabs.first)
        #expect(tab.kind == .terminal)
        #expect(tab.agentSessionID == nil)
    }

    @Test func twoCandidatesClaimingOneSessionYieldOneAgentTab() throws {
        let context = try makeContext()

        let created = Importer.importing(
            [
                candidate(stableID: "cmux:one", tabs: [.agentPlan(sessionID: "shared")]),
                candidate(stableID: "cmux:two", tabs: [.agentPlan(sessionID: "shared")]),
            ],
            into: .ungrouped,
            in: context
        )

        let kinds = created.flatMap { $0.tabs.map(\.kind) }
        #expect(kinds.count { $0 == .agent } == 1)
        #expect(kinds.count { $0 == .terminal } == 1)
    }

    // MARK: - Rejection

    @Test func aRejectedCandidateIsNotImported() throws {
        let context = try makeContext()

        let created = Importer.importing(
            [
                candidate(stableID: "cmux:one", rejection: .directoryMissing("/gone")),
                candidate(stableID: "cmux:two"),
            ],
            into: .ungrouped,
            in: context
        )

        #expect(created.map(\.importedStableID) == ["cmux:two"])
    }

    // MARK: - Groups

    @Test func mirroringCreatesTheSourceGroup() throws {
        let context = try makeContext()

        let created = Importer.importing(
            [candidate(groupName: "Widgets")],
            into: .mirrorSourceGroups,
            in: context
        )

        #expect(created.first?.group?.name == "Widgets")
        let groups = try context.fetch(FetchDescriptor<TaskGroup>())
        #expect(groups.count == 1)
    }

    @Test func mirroringReusesAGroupOfTheSameName() throws {
        let context = try makeContext()
        let existing = TaskStore.createGroup(in: context, name: "widgets", existing: [])

        let created = Importer.importing(
            [candidate(groupName: "Widgets")],
            into: .mirrorSourceGroups,
            in: context
        )

        #expect(created.first?.group?.id == existing.id)
        let groups = try context.fetch(FetchDescriptor<TaskGroup>())
        #expect(groups.count == 1)
    }

    @Test func mirroringPutsOneGroupsCandidatesTogether() throws {
        let context = try makeContext()

        let created = Importer.importing(
            [
                candidate(stableID: "cmux:one", groupName: "Widgets"),
                candidate(stableID: "cmux:two", groupName: "Widgets"),
                candidate(stableID: "cmux:three", groupName: nil),
            ],
            into: .mirrorSourceGroups,
            in: context
        )

        let groups = try context.fetch(FetchDescriptor<TaskGroup>())
        #expect(groups.count == 1)
        #expect(created[0].group?.id == created[1].group?.id)
        #expect(created[2].group == nil)
        #expect(created.map(\.orderIndex) == [0, 1, 0])
    }

    @Test func anExistingGroupTakesEveryCandidate() throws {
        let context = try makeContext()
        let group = TaskStore.createGroup(in: context, name: "Inbox", existing: [])

        let created = Importer.importing(
            [candidate(stableID: "cmux:one", groupName: "Widgets")],
            into: .existing(group.id),
            in: context
        )

        #expect(created.first?.group?.id == group.id)
    }
}

private extension ImportTabPlan {
    static func agentPlan(
        sessionID: String? = "session-a",
        transcript: String? = nil,
        directory: String? = nil,
        permissionMode: PermissionMode? = nil
    ) -> ImportTabPlan {
        ImportTabPlan(
            kind: .agent,
            title: nil,
            workingDirectoryPath: directory,
            agentSessionID: sessionID,
            sessionJSONLPath: transcript,
            permissionMode: permissionMode
        )
    }

    static func terminalPlan(title: String?) -> ImportTabPlan {
        ImportTabPlan(
            kind: .terminal,
            title: title,
            workingDirectoryPath: nil,
            agentSessionID: nil,
            sessionJSONLPath: nil,
            permissionMode: nil
        )
    }
}
