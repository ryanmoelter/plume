import Foundation
import SwiftData
import Testing
@testable import Plume

/// Sorting live agent tabs into Home's sections: what needs the user (named
/// requests first, then unread turns), what is running, and what can be
/// resumed. Everything else stays off Home.
struct HomeFeedTests {
    private func entry(
        task: UUID = UUID(),
        title: String = "Task",
        tab: String = "Tab",
        _ status: TaskStatus,
        isUnread: Bool = false,
        isDormant: Bool = false,
        hasSession: Bool = false,
        permission: String? = nil,
        started: Date? = nil,
        preview: String? = nil
    ) -> HomeFeed.Entry {
        HomeFeed.Entry(
            taskID: task,
            tabID: UUID(),
            taskTitle: title,
            tabTitle: tab,
            status: status,
            isUnread: isUnread,
            isDormant: isDormant,
            hasSession: hasSession,
            permissionToolName: permission,
            workStartedAt: started,
            preview: preview
        )
    }

    // MARK: Sections

    @Test func everyAttentionStateNeedsYou() {
        let feed = HomeFeed(entries: [
            entry(.planApproval), entry(.questionAsked), entry(.permissionNeeded), entry(.needsTerminalInput),
        ])
        #expect(feed.needsYou.count == 4)
        #expect(feed.running.isEmpty)
        #expect(feed.notStarted.isEmpty)
    }

    @Test func anUnreadTurnNeedsYou() {
        let feed = HomeFeed(entries: [entry(.awaitingReply, isUnread: true)])
        #expect(feed.needsYou.map(\.isUnread) == [true])
    }

    @Test func aReadFinishedTurnIsNotListed() {
        let feed = HomeFeed(entries: [entry(.awaitingReply), entry(.error), entry(.notStarted)])
        #expect(feed.needsYou.isEmpty && feed.running.isEmpty && feed.notStarted.isEmpty)
    }

    @Test func workingAndWaitingOnSubagentsAreRunning() {
        let started = Date(timeIntervalSince1970: 1_000)
        let feed = HomeFeed(entries: [entry(.working, started: started), entry(.waitingOnSubagents, started: started)])
        #expect(feed.running.count == 2)
        #expect(feed.running.allSatisfy { $0.workStartedAt == started })
    }

    @Test func aStaleStartIsDroppedOnceNotActive() {
        let feed = HomeFeed(entries: [entry(.questionAsked, started: Date())])
        #expect(feed.needsYou.first?.workStartedAt == nil)
    }

    @Test func aResumableDormantTabIsNotStarted() {
        let feed = HomeFeed(entries: [entry(.notStarted, isDormant: true, hasSession: true)])
        #expect(feed.notStarted.count == 1)
    }

    @Test func aDormantTabWithoutASessionIsNotListed() {
        let feed = HomeFeed(entries: [entry(.notStarted, isDormant: true)])
        #expect(feed.notStarted.isEmpty)
    }

    @Test func anInterruptedTabIsNotStarted() {
        let feed = HomeFeed(entries: [entry(.interrupted)])
        #expect(feed.notStarted.map(\.status) == [.interrupted])
    }

    // MARK: Ordering

    @Test func namedRequestsOutrankUnreadByPriority() {
        let feed = HomeFeed(entries: [
            entry(title: "unread", .awaitingReply, isUnread: true),
            entry(title: "terminal", .needsTerminalInput),
            entry(title: "permission", .permissionNeeded),
            entry(title: "question", .questionAsked),
            entry(title: "plan", .planApproval),
        ])
        #expect(feed.needsYou.map(\.taskTitle) == ["plan", "question", "permission", "terminal", "unread"])
    }

    @Test func tiesKeepSidebarOrder() {
        let feed = HomeFeed(entries: [
            entry(title: "a", .awaitingReply, isUnread: true),
            entry(title: "b", .questionAsked),
            entry(title: "c", .awaitingReply, isUnread: true),
            entry(title: "d", .questionAsked),
        ])
        #expect(feed.needsYou.map(\.taskTitle) == ["b", "d", "a", "c"])
    }

    // MARK: Reasons

    @Test(arguments: [
        (TaskStatus.planApproval, "Plan ready for review"),
        (.questionAsked, "Asked a question"),
        (.needsTerminalInput, "Waiting for terminal input"),
    ])
    func reasonPerStatus(status: TaskStatus, reason: String) {
        #expect(HomeFeed.reason(for: entry(status)) == reason)
    }

    @Test func aPermissionNamesItsTool() {
        #expect(HomeFeed.reason(for: entry(.permissionNeeded, permission: "Bash")) == "Wants to run Bash")
    }

    @Test func aPermissionWithNoKnownToolStillSaysWhy() {
        #expect(HomeFeed.reason(for: entry(.permissionNeeded)) == "Wants permission to continue")
    }

    @Test func anUnreadTurnShowsItsPreview() {
        #expect(HomeFeed.reason(for: entry(.awaitingReply, isUnread: true, preview: "All done.")) == "All done.")
    }

    @Test func anUnreadTurnWithoutAPreviewSaysItFinished() {
        #expect(HomeFeed.reason(for: entry(.awaitingReply, isUnread: true)) == "Finished a turn you haven't read")
    }

    @Test func aRunningTabHasNoReason() {
        #expect(HomeFeed.reason(for: entry(.working)) == nil)
    }

    // MARK: Tab titles

    @Test func theTabTitleShowsOnlyWhenATaskHasSeveralAgentTabs() {
        let shared = UUID()
        let feed = HomeFeed(entries: [
            entry(task: shared, title: "two", tab: "first", .questionAsked),
            entry(task: shared, title: "two", tab: "second", .working),
            entry(title: "one", tab: "only", .planApproval),
        ])
        #expect(feed.needsYou.map(\.tabTitle) == [nil, "first"])
        #expect(feed.running.map(\.tabTitle) == ["second"])
    }

    // MARK: Preview

    private func message(_ role: ChatMessage.Role, _ blocks: ChatBlock...) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, role: role, blocks: blocks, timestamp: nil)
    }

    @Test func thePreviewIsTheLastAssistantProse() {
        let messages = [
            message(.assistant, .markdown("Earlier reply")),
            message(.user, .markdown("Thanks")),
            message(.assistant, .markdown("First block"), .markdown("Final block")),
            message(.assistant, .thinking("Mulling")),
        ]
        #expect(HomeFeed.preview(of: messages) == "Final block")
    }

    @Test func aConversationWithNoAssistantProseHasNoPreview() {
        #expect(HomeFeed.preview(of: [message(.user, .markdown("Hello"))]) == nil)
    }

    @Test func thePreviewFlattensBlockMarkdown() {
        let markdown = """
        ## Summary

        - Fixed the **bug**
        > quoted
        ```swift
        let hidden = true
        ```
        Done.
        """
        #expect(HomeFeed.previewText(markdown) == "Summary Fixed the **bug** quoted Done.")
    }

    @Test func aLongPreviewIsTruncated() throws {
        let long = String(repeating: "word ", count: 200)
        let preview = try #require(HomeFeed.previewText(long))
        #expect(preview.hasSuffix("…"))
        #expect(preview.count == HomeFeed.previewCharacterLimit)
    }

    @Test func onlyCodeHasNoPreview() {
        #expect(HomeFeed.previewText("```\ncode\n```") == nil)
    }
}

/// Building the feed from the sidebar's tasks: only live agent tabs of
/// unarchived tasks count, and the preview is read only for unread tabs.
@MainActor
struct HomeFeedSourceTests {
    private let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
    }

    private func source(
        status: TaskStatus = .questionAsked,
        unread: Set<UUID> = [],
        previewed: @escaping (UUID) -> Void = { _ in }
    ) -> HomeFeedSource {
        HomeFeedSource(
            status: { _ in status },
            isUnread: { unread.contains($0) },
            isDormant: { _ in false },
            workStarted: { _ in nil },
            permissionToolName: { _ in nil },
            preview: { tab in
                previewed(tab.id)
                return "preview"
            },
            taskTitle: \.title,
            tabTitle: \.displayTitle
        )
    }

    @Test func anArchivedTaskIsLeftOut() throws {
        let kept = TaskStore.createTask(in: context, siblings: [])
        kept.title = "kept"
        let archived = TaskStore.createTask(in: context, siblings: [kept])
        archived.title = "archived"
        archived.isArchived = true
        try context.save()

        let feed = HomeFeed(tasks: [kept, archived], source: source())
        #expect(feed.needsYou.map(\.taskTitle) == ["kept"])
    }

    @Test func onlyAgentTabsAreListed() throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        _ = TaskStore.addTab(to: task, kind: .terminal, in: context)
        try context.save()

        let feed = HomeFeed(tasks: [task], source: source())
        #expect(feed.needsYou.count == 1)
        #expect(feed.needsYou.first?.tabTitle == nil)
    }

    @Test func thePreviewIsReadOnlyForUnreadTabs() throws {
        let read = TaskStore.createTask(in: context, siblings: [])
        let unread = TaskStore.createTask(in: context, siblings: [read])
        try context.save()
        let unreadTab = try #require(unread.tabs.first)

        var previewed: [UUID] = []
        let feed = HomeFeed(
            tasks: [read, unread],
            source: source(status: .awaitingReply, unread: [unreadTab.id]) { previewed.append($0) }
        )
        #expect(previewed == [unreadTab.id])
        #expect(feed.needsYou.map(\.reason) == ["preview"])
    }
}
