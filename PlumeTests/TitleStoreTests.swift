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
        store.setTitle("Debugging auth", forTab: task.tabs[0].id, source: .reply)

        #expect(store.displayTitle(for: task) == "Fix login")
    }

    @Test func anUnnamedTaskFallsBackToTheTabTitle() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let store = TitleStore()
        store.setTitle("Debugging auth", forTab: task.tabs[0].id, source: .reply)

        #expect(store.displayTitle(for: task) == "Debugging auth")
    }

    /// The snapshot on the tab is what labels a row before anything reconnects.
    @Test func theStoredSnapshotCoversTheGapBeforeALiveTitle() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        task.tabs[0].title = "From last launch"

        #expect(TitleStore().displayTitle(for: task) == "From last launch")
    }

    @Test func aTaskWithNoTitleAnywhereReadsAsNewTask() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])

        #expect(TitleStore().displayTitle(for: task) == "New task")
    }

    @Test func aWhitespaceOnlyNameCountsAsUnnamed() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, title: "   ", siblings: [])
        let store = TitleStore()
        store.setTitle("Live title", forTab: task.tabs[0].id, source: .reply)

        #expect(store.displayTitle(for: task) == "Live title")
    }

    /// Dipping into a terminal tab must not relabel the row.
    @Test func theLastFocusedAgentTabWinsOverASelectedTerminal() throws {
        let context = try makeContext()
        let task = TaskStore.createTask(in: context, siblings: [])
        let agent = task.tabs[0]
        let terminal = TaskStore.addTab(to: task, kind: .terminal, in: context)

        let store = TitleStore()
        store.setTitle("Agent work", forTab: agent.id, source: .reply)
        store.setTitle("vim", forTab: terminal.id, source: .reply)

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
        store.setTitle("vim", forTab: terminal.id, source: .reply)

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
        store.onTitleChanged = { _, title, _ in reported.append(title) }

        let tab = UUID()
        store.setTitle("One", forTab: tab, source: .reply)
        store.setTitle("One", forTab: tab, source: .reply)
        store.setTitle("Two", forTab: tab, source: .reply)

        #expect(reported == ["One", "Two"])
    }

    @Test func blankTitlesAreIgnored() {
        let store = TitleStore()
        let tab = UUID()
        store.setTitle("  ", forTab: tab, source: .reply)

        #expect(store.title(forTab: tab) == nil)
    }

    @Test func aFallbackNeverReplacesATranscriptTitle() {
        let store = TitleStore()
        let tab = UUID()
        store.setTitle("Largest planet in solar system", forTab: tab, source: .transcript)
        store.setTitle("Name the largest planet in our solar system, then say why…", forTab: tab, source: .fallback)

        #expect(store.title(forTab: tab) == "Largest planet in solar system")
    }

    @Test func aTranscriptTitleNeverReplacesAReplyTitle() {
        let store = TitleStore()
        let tab = UUID()
        store.setTitle("Sharper title", forTab: tab, source: .reply)
        store.setTitle("Largest planet in solar system", forTab: tab, source: .transcript)

        #expect(store.title(forTab: tab) == "Sharper title")
    }

    /// The regression this guards against: `AgentTitleMonitor` is re-watched
    /// on relaunch, on `EnterWorktree`, and on unarchive, each of which reads
    /// the transcript's `ai-title` fresh — which for a headless session can
    /// be stale, since the CLI only ever writes the *first* title to the
    /// transcript. A reply's retitle (a plan naming the work better than the
    /// opening message did) must survive that re-read.
    @Test func aReplyTitleSurvivesAStaleTranscriptAfterARewatch() {
        let store = TitleStore()
        let tab = UUID()
        store.setTitle("Add OAuth2 login with Google", forTab: tab, source: .transcript)
        store.setTitle("Add OAuth2 login with Google, rate limiting and refresh tokens", forTab: tab, source: .reply)

        // A re-watch (stopWatching + watch) re-reads the transcript's own
        // `ai-title`, which is still the stale first title.
        store.setTitle("Add OAuth2 login with Google", forTab: tab, source: .transcript)

        #expect(store.title(forTab: tab) == "Add OAuth2 login with Google, rate limiting and refresh tokens")
    }

    @Test func aSameRankedTitleCanReplaceAnEarlierOne() {
        let store = TitleStore()
        let tab = UUID()
        store.setTitle("First guess", forTab: tab, source: .reply)
        store.setTitle("Sharper title", forTab: tab, source: .reply)

        #expect(store.title(forTab: tab) == "Sharper title")
    }

    /// Switching an agent tab to the terminal transport turns off the only
    /// source of a `.reply` (the headless control plane), so a `.reply`
    /// stuck there would block every `ai-title` the TUI writes from then on.
    @Test func demotingLowersAReplySourceToTranscript() {
        let store = TitleStore()
        let tab = UUID()
        store.setTitle("Sharper title", forTab: tab, source: .reply)

        store.demoteSource(forTab: tab, to: .transcript)

        #expect(store.source(forTab: tab) == .transcript)
        #expect(store.title(forTab: tab) == "Sharper title")
    }

    @Test func demotingNeverRaisesASourceBelowTheTarget() {
        let store = TitleStore()
        let tab = UUID()
        store.setTitle("Opening line", forTab: tab, source: .fallback)

        store.demoteSource(forTab: tab, to: .transcript)

        #expect(store.source(forTab: tab) == .fallback)
    }

    @Test func demotingATabWithNoSourceYetDoesNothing() {
        let store = TitleStore()
        let tab = UUID()

        store.demoteSource(forTab: tab, to: .transcript)

        #expect(store.source(forTab: tab) == nil)
    }

    @Test func theSourceIsRecordedEvenWhenTheTextIsUnchanged() {
        let store = TitleStore()
        let tab = UUID()
        store.setTitle("Largest planet", forTab: tab, source: .fallback)
        store.setTitle("Largest planet", forTab: tab, source: .reply)

        #expect(store.source(forTab: tab) == .reply)
    }

    @Test func aSourceUpgradeWithUnchangedTextIsReported() {
        let store = TitleStore()
        var reported: [TitleSource] = []
        store.onTitleChanged = { _, _, source in reported.append(source) }
        let tab = UUID()
        store.setTitle("Largest planet", forTab: tab, source: .fallback)
        store.setTitle("Largest planet", forTab: tab, source: .reply)

        #expect(reported == [.fallback, .reply])
    }

    @Test func beginningANewConversationClearsTheTitleAndTheSource() {
        let store = TitleStore()
        let tab = UUID()
        store.setTitle("Largest planet", forTab: tab, source: .reply)

        store.beginNewConversation(forTab: tab)

        #expect(store.title(forTab: tab) == nil)
        #expect(store.source(forTab: tab) == nil)
    }

    @Test func beginningANewConversationNotifiesTheCallback() {
        let store = TitleStore()
        let tab = UUID()
        store.setTitle("Largest planet", forTab: tab, source: .reply)
        var resetTab: UUID?
        store.onConversationReset = { resetTab = $0 }

        store.beginNewConversation(forTab: tab)

        #expect(resetTab == tab)
    }

    @Test func aFallbackCanSetTheTitleAgainAfterANewConversationBegins() {
        let store = TitleStore()
        let tab = UUID()
        store.setTitle("Old conversation", forTab: tab, source: .reply)
        store.beginNewConversation(forTab: tab)

        store.setTitle("Opening line of the new one", forTab: tab, source: .fallback)

        #expect(store.title(forTab: tab) == "Opening line of the new one")
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
