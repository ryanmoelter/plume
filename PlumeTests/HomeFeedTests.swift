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

    @Test func aReadFinishedTurnIsIdle() {
        let feed = HomeFeed(entries: [entry(.awaitingReply, hasSession: true), entry(.done, hasSession: true)])
        #expect(feed.idle.map(\.status) == [.awaitingReply, .done])
        #expect(feed.needsYou.isEmpty && feed.running.isEmpty && feed.notStarted.isEmpty)
    }

    @Test func anErroredTabNeedsYouBeforeTheAttentionStates() {
        let feed = HomeFeed(entries: [
            entry(.awaitingReply, isUnread: true), entry(.error), entry(.questionAsked),
        ])
        #expect(feed.needsYou.map(\.status) == [.error, .questionAsked, .awaitingReply])
        #expect(feed.needsYou[0].reason == "Stopped with an error")
    }

    @Test func aNeverStartedTabIsNotStarted() {
        let feed = HomeFeed(entries: [entry(.notStarted)])
        #expect(feed.notStarted.count == 1)
    }

    @Test func aDormantTabWithASessionIsIdle() {
        let feed = HomeFeed(entries: [entry(.notStarted, hasSession: true)])
        #expect(feed.idle.count == 1)
        #expect(feed.notStarted.isEmpty)
    }

    @Test func anUnreadTabIsNotIdle() {
        let feed = HomeFeed(entries: [entry(.awaitingReply, isUnread: true, hasSession: true)])
        #expect(feed.idle.isEmpty)
        #expect(feed.needsYou.count == 1)
    }

    @Test func aWorkingTabBeatsUnread() {
        let feed = HomeFeed(entries: [entry(.working, isUnread: true), entry(.waitingOnSubagents, isUnread: true)])
        #expect(feed.running.count == 2)
        #expect(feed.needsYou.isEmpty)
        #expect(HomeFeed.needsYou(status: .working, isUnread: true) == false)
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

    @Test func anInterruptedTabIsNotStarted() {
        let feed = HomeFeed(entries: [entry(.interrupted)])
        #expect(feed.notStarted.map(\.status) == [.interrupted])
        #expect(feed.idle.isEmpty)
    }

    // MARK: Ordering

    @Test func needsYouOrderIsErrorPermissionTerminalQuestionPlanUnread() {
        let feed = HomeFeed(entries: [
            entry(title: "unread", .awaitingReply, isUnread: true),
            entry(title: "error", .error),
            entry(title: "terminal", .needsTerminalInput),
            entry(title: "permission", .permissionNeeded),
            entry(title: "question", .questionAsked),
            entry(title: "plan", .planApproval),
        ])
        #expect(feed.needsYou.map(\.taskTitle) == ["error", "permission", "terminal", "question", "plan", "unread"])
    }

    @Test func appearanceCarriesThroughToTheItem() {
        var tinted = entry(.questionAsked)
        tinted.iconName = "star"
        tinted.iconTint = .text
        tinted.barTint = .text
        let item = HomeFeed(entries: [tinted]).needsYou[0]
        #expect(item.iconName == "star" && item.iconTint == .text && item.barTint == .text)
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
        #expect(feed.needsYou.map(\.tabTitle) == ["first", nil])
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
        let long = String(repeating: "abcdefghij ", count: 100)
        let preview = try #require(HomeFeed.previewText(long))
        #expect(preview.hasSuffix("…"))
        #expect(preview.count <= HomeFeed.previewCharacterLimit)
        #expect(preview.dropLast().hasSuffix("abcdefghij"))
    }

    @Test func aHeadingOrQuoteMarkerIsStrippedOnlyBeforeASpace() {
        #expect(HomeFeed.previewText("## Title") == "Title")
        #expect(HomeFeed.previewText("> quoted") == "quoted")
        #expect(HomeFeed.previewText("#123 is merged") == "#123 is merged")
        #expect(HomeFeed.previewText(">=2 tests fail") == ">=2 tests fail")
    }

    @Test func crlfTextSplitsIntoLinesAroundACodeFence() {
        let markdown = "Intro\r\n```\r\ncode\r\n```\r\nOutro"
        #expect(HomeFeed.previewText(markdown) == "Intro Outro")
    }

    @Test func orderedListAndNestedMarkersAreStripped() {
        #expect(HomeFeed.previewText("1. first\n12) second") == "first second")
        #expect(HomeFeed.previewText("> - item") == "item")
        #expect(HomeFeed.previewText("1.5 is a number") == "1.5 is a number")
    }

    @Test func rulesAndTableSeparatorsAreDropped() {
        #expect(HomeFeed.previewText("Above\n---\n***\n___\n| a | b |\n|---|:-:|\n| 1 | 2 |\nBelow") == "Above | a | b | | 1 | 2 | Below")
    }

    @Test func spacedRulesAreDroppedNotReadAsBullets() {
        #expect(HomeFeed.previewText("Above\n* * *\n- - -\n_ _ _\nBelow") == "Above Below")
    }

    @Test func aLineOfOnlyHashesIsDropped() {
        #expect(HomeFeed.previewText("Above\n##\n#\nBelow") == "Above Below")
    }

    @Test func aFenceClosesOnlyOnTheSameCharacterAtLeastAsLong() {
        #expect(HomeFeed.previewText("A\n````\n```\nstill code\n~~~~\n````\nB") == "A B")
        #expect(HomeFeed.previewText("A\n~~~\n```\nstill code\n~~~\nB") == "A B")
        #expect(HomeFeed.previewText("A\n```\n```js\nstill code\n```\nB") == "A B")
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
