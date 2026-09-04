import Testing
import Foundation
import SwiftData
@testable import Plume

@MainActor
struct TitleStoreTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    @Test func aNamedTaskKeepsItsName() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, title: "Fix login", siblings: [])
        let store = TitleStore()
        store.setTitle("Debugging auth", forTab: task.tabs[0].id)

        #expect(store.displayTitle(for: task) == "Fix login")
    }

    @Test func anUnnamedTaskFallsBackToTheTabTitle() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let store = TitleStore()
        store.setTitle("Debugging auth", forTab: task.tabs[0].id)

        #expect(store.displayTitle(for: task) == "Debugging auth")
    }

    /// The snapshot on the tab is what labels a row before anything reconnects.
    @Test func theStoredSnapshotCoversTheGapBeforeALiveTitle() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.tabs[0].title = "From last launch"

        #expect(TitleStore().displayTitle(for: task) == "From last launch")
    }

    @Test func aTaskWithNoTitleAnywhereReadsAsUntitled() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])

        #expect(TitleStore().displayTitle(for: task) == "Untitled")
    }

    @Test func aWhitespaceOnlyNameCountsAsUnnamed() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, title: "   ", siblings: [])
        let store = TitleStore()
        store.setTitle("Live title", forTab: task.tabs[0].id)

        #expect(store.displayTitle(for: task) == "Live title")
    }

    /// Dipping into a terminal tab must not relabel the row.
    @Test func theLastFocusedAgentTabWinsOverASelectedTerminal() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let agent = task.tabs[0]
        let terminal = TaskStore.addTab(to: task, kind: .terminal, in: context)

        let store = TitleStore()
        store.setTitle("Agent work", forTab: agent.id)
        store.setTitle("vim", forTab: terminal.id)

        #expect(task.selectedTabID == terminal.id)
        #expect(store.displayTitle(for: task) == "Agent work")
    }

    /// With no agent tab to speak for it, the selected terminal names the task.
    @Test func aTerminalOnlyTaskUsesItsSelectedTab() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        TaskStore.closeTab(task.tabs[0], in: context)
        let terminal = TaskStore.addTab(to: task, kind: .terminal, in: context)

        let store = TitleStore()
        store.setTitle("vim", forTab: terminal.id)

        #expect(store.displayTitle(for: task) == "vim")
    }

    @Test func closingTheFocusedAgentTabFallsBackToAnother() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let first = task.tabs[0]
        let second = TaskStore.addTab(to: task, kind: .agent, in: context)

        #expect(task.lastFocusedAgentTabID == second.id)
        TaskStore.closeTab(second, in: context)
        #expect(task.lastFocusedAgentTabID == first.id)
    }

    @Test func changingATitleReportsIt() {
        let store = TitleStore()
        var reported: [String] = []
        store.onTitleChanged = { _, title in reported.append(title) }

        let tab = UUID()
        store.setTitle("One", forTab: tab)
        store.setTitle("One", forTab: tab)
        store.setTitle("Two", forTab: tab)

        #expect(reported == ["One", "Two"])
    }

    @Test func blankTitlesAreIgnored() {
        let store = TitleStore()
        let tab = UUID()
        store.setTitle("  ", forTab: tab)

        #expect(store.title(forTab: tab) == nil)
    }
}

/// `contextWindowTokens` is the same kind of durable snapshot as `title`: a
/// resumed headless session has neither until it takes a turn in this
/// process, so both are persisted so a relaunch has something to show.
@MainActor
struct TaskTabContextWindowTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    @Test func defaultsToNilForLightweightMigration() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])

        #expect(task.tabs[0].contextWindowTokens == nil)
    }

    @Test func aWrittenValueSurvivesAFetch() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.tabs[0].contextWindowTokens = 200_000
        try context.save()

        let refetched = try #require(
            try context.fetch(FetchDescriptor<WorkTask>()).first
        )
        #expect(refetched.tabs[0].contextWindowTokens == 200_000)
    }
}

@MainActor
struct TabFocusTrackingTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    @Test func selectingAnAgentTabRecordsIt() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        #expect(task.lastFocusedAgentTabID == task.tabs[0].id)
    }

    @Test func selectingATerminalTabLeavesTheAgentRecorded() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let agent = task.tabs[0]
        let terminal = TaskStore.addTab(to: task, kind: .terminal, in: context)

        TaskStore.selectTab(terminal, in: task)

        #expect(task.selectedTabID == terminal.id)
        #expect(task.lastFocusedAgentTabID == agent.id)
    }

    @Test func creationLeavesTheNameEmptyForTheAgentToFill() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        #expect(task.title.isEmpty)
    }
}
