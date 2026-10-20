import Foundation
import SwiftData
import Testing
@testable import Plume

/// Each pane of a split has its own strip and selected tab. Every tab sits in
/// exactly one pane, `orderIndex` stays dense within each pane, the focused
/// pane's selected tab is `selectedTabID`, and a pane left empty closes.
@MainActor
struct SplitTabsTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    /// A task with `count` tabs in one pane, the first one selected.
    private func makeTask(tabs count: Int = 3, in context: ModelContext) throws -> (WorkTask, [TaskTab]) {
        let task = TaskStore.createTask(in: context, siblings: [])
        let first = try #require(task.tabs.first)
        let rest = (1..<count).map { _ in TaskStore.addTab(to: task, kind: .terminal, in: context) }
        TaskStore.selectTab(first, in: task)
        return (task, [first] + rest)
    }

    private func ids(_ task: WorkTask) -> [[UUID]] {
        task.panes.map { $0.map(\.id) }
    }

    private func ids(_ tabs: [TaskTab]...) -> [[UUID]] {
        tabs.map { $0.map(\.id) }
    }

    /// Panes [[A, B], [C, D]] with C focused.
    private func makeSplitTask(in context: ModelContext) throws -> (WorkTask, [TaskTab]) {
        let (task, tabs) = try makeTask(tabs: 4, in: context)
        TaskStore.openInSplit(tabs[2], side: .right, in: task)
        TaskStore.moveTab(tabs[3], toPane: 1, in: task)
        TaskStore.selectTab(tabs[2], in: task)
        return (task, tabs)
    }

    @Test func aTaskStartsUnsplit() throws {
        let context = try makeContext()
        let (task, tabs) = try makeTask(in: context)

        #expect(!task.isSplit)
        #expect(ids(task) == ids(tabs))
        #expect(task.paneTabIDs == [tabs[0].id])
    }

    @Test func openingInSplitMovesOnlyThatTabIntoANewRightPane() throws {
        let context = try makeContext()
        let (task, tabs) = try makeTask(in: context)

        TaskStore.openInSplit(tabs[1], side: .right, in: task)

        #expect(ids(task) == ids([tabs[0], tabs[2]], [tabs[1]]))
        #expect(task.selectedTabID == tabs[1].id)
        #expect(task.paneTabIDs == [tabs[0].id, tabs[1].id])
        #expect(tabs[2].orderIndex == 1)
        #expect(tabs[1].paneIndex == 1)
        #expect(tabs[1].orderIndex == 0)
    }

    @Test func openingOnTheLeftPutsTheNewPaneFirst() throws {
        let context = try makeContext()
        let (task, tabs) = try makeTask(in: context)

        TaskStore.openInSplit(tabs[2], side: .left, in: task)

        #expect(ids(task) == ids([tabs[2]], [tabs[0], tabs[1]]))
        #expect(task.paneTabIDs == [tabs[2].id, tabs[0].id])
        #expect(tabs[0].paneIndex == 1)
    }

    @Test func movingTheShownTabOutLeavesItsStripShowingItsFirstTab() throws {
        let context = try makeContext()
        let (task, tabs) = try makeTask(in: context)
        TaskStore.selectTab(tabs[1], in: task)

        TaskStore.openInSplit(tabs[1], side: .right, in: task)

        #expect(task.paneTabIDs == [tabs[0].id, tabs[1].id])
    }

    @Test func aLoneTabCannotOpenInSplit() throws {
        let context = try makeContext()
        let (task, tabs) = try makeTask(tabs: 1, in: context)

        #expect(!TaskStore.canOpenInSplit(tabs[0], in: task))
        TaskStore.openInSplit(tabs[0], side: .right, in: task)
        TaskStore.splitRight(in: task)

        #expect(!task.isSplit)
    }

    @Test func splitRightMovesTheFocusedTab() throws {
        let context = try makeContext()
        let (task, tabs) = try makeTask(in: context)
        TaskStore.selectTab(tabs[1], in: task)

        TaskStore.splitRight(in: task)

        #expect(ids(task) == ids([tabs[0], tabs[2]], [tabs[1]]))
        #expect(task.selectedTabID == tabs[1].id)
    }

    @Test func openingInSplitWhileSplitMovesIntoThatSidesPane() throws {
        let context = try makeContext()
        let (task, tabs) = try makeSplitTask(in: context)

        TaskStore.openInSplit(tabs[1], side: .right, in: task)

        #expect(ids(task) == ids([tabs[0]], [tabs[2], tabs[3], tabs[1]]))
        #expect(task.selectedTabID == tabs[1].id)
    }

    @Test func aNewTabLandsInTheFocusedPaneOrTheOneAsked() throws {
        let context = try makeContext()
        let (task, tabs) = try makeSplitTask(in: context)

        let focused = TaskStore.addTab(to: task, kind: .terminal, in: context)
        let left = TaskStore.addTab(to: task, kind: .terminal, pane: 0, in: context)

        #expect(ids(task) == ids([tabs[0], tabs[1], left], [tabs[2], tabs[3], focused]))
        #expect(task.selectedTabID == left.id)
    }

    @Test func eachPaneKeepsItsOwnSelectedTab() throws {
        let context = try makeContext()
        let (task, tabs) = try makeSplitTask(in: context)
        TaskStore.selectTab(tabs[3], in: task)

        TaskStore.selectTab(tabs[1], in: task)
        #expect(task.paneTabIDs == [tabs[1].id, tabs[3].id])

        TaskStore.focusOtherPane(in: task)
        #expect(task.selectedTabID == tabs[3].id)
        #expect(task.paneTabIDs == [tabs[1].id, tabs[3].id])
    }

    @Test func numberShortcutsCountWithinTheFocusedPane() throws {
        let context = try makeContext()
        let (task, tabs) = try makeSplitTask(in: context)

        TaskStore.selectTab(atIndex: 1, in: task)
        #expect(task.selectedTabID == tabs[3].id)

        TaskStore.selectTab(atIndex: 2, in: task)
        #expect(task.selectedTabID == tabs[3].id)

        TaskStore.selectTab(tabs[1], in: task)
        TaskStore.selectTab(atIndex: 0, in: task)
        #expect(task.selectedTabID == tabs[0].id)
    }

    @Test func cyclingWrapsWithinTheFocusedPane() throws {
        let context = try makeContext()
        let (task, tabs) = try makeSplitTask(in: context)

        TaskStore.cycleTab(by: 1, in: task)
        #expect(task.selectedTabID == tabs[3].id)
        TaskStore.cycleTab(by: 1, in: task)
        #expect(task.selectedTabID == tabs[2].id)
        TaskStore.cycleTab(by: -1, in: task)
        #expect(task.selectedTabID == tabs[3].id)
        #expect(task.paneTabIDs == [tabs[0].id, tabs[3].id])
    }

    @Test func cyclingUnsplitWrapsAcrossEveryTab() throws {
        let context = try makeContext()
        let (task, tabs) = try makeTask(in: context)

        TaskStore.cycleTab(by: -1, in: task)

        #expect(task.selectedTabID == tabs[2].id)
    }

    @Test func closingTheSplitAppendsTheRightStripToTheLeft() throws {
        let context = try makeContext()
        let (task, tabs) = try makeSplitTask(in: context)

        TaskStore.closeSplit(in: task)

        #expect(ids(task) == ids(tabs))
        #expect(tabs.map(\.orderIndex) == [0, 1, 2, 3])
        #expect(tabs.allSatisfy { $0.paneIndex == 0 })
        #expect(task.selectedTabID == tabs[2].id)
        #expect(task.paneSelectedTabIDs.isEmpty)
    }

    @Test func closingAPanesLastTabCollapsesTheSplitOntoTheOtherPane() throws {
        let context = try makeContext()
        let (task, tabs) = try makeTask(in: context)
        TaskStore.selectTab(tabs[1], in: task)
        TaskStore.openInSplit(tabs[2], side: .right, in: task)

        TaskStore.closeTab(tabs[2], in: context)

        #expect(!task.isSplit)
        #expect(ids(task) == ids([tabs[0], tabs[1]]))
        #expect(task.selectedTabID == tabs[1].id)
    }

    @Test func closingTheUnfocusedPanesLastTabKeepsFocus() throws {
        let context = try makeContext()
        let (task, tabs) = try makeTask(in: context)
        TaskStore.openInSplit(tabs[2], side: .left, in: task)
        TaskStore.selectTab(tabs[1], in: task)

        TaskStore.closeTab(tabs[2], in: context)

        #expect(!task.isSplit)
        #expect(task.selectedTabID == tabs[1].id)
        #expect(tabs[0].paneIndex == 0)
    }

    @Test func closingTheFocusedTabFocusesItsPanesFirstTab() throws {
        let context = try makeContext()
        let (task, tabs) = try makeSplitTask(in: context)
        TaskStore.selectTab(tabs[3], in: task)

        TaskStore.closeTab(tabs[3], in: context)

        #expect(task.isSplit)
        #expect(task.selectedTabID == tabs[2].id)
        #expect(tabs[2].orderIndex == 0)
    }

    @Test func movingATabToTheOtherPaneInsertsItAtTheGap() throws {
        let context = try makeContext()
        let (task, tabs) = try makeSplitTask(in: context)

        TaskStore.moveTab(tabs[0], toPane: 1, at: 1, in: task)

        #expect(ids(task) == ids([tabs[1]], [tabs[2], tabs[0], tabs[3]]))
        #expect(task.selectedTabID == tabs[0].id)
        #expect(task.panes[1].map(\.orderIndex) == [0, 1, 2])
    }

    @Test func movingAPanesLastTabAwayCollapsesTheSplit() throws {
        let context = try makeContext()
        let (task, tabs) = try makeTask(in: context)
        TaskStore.openInSplit(tabs[2], side: .right, in: task)

        TaskStore.moveTab(tabs[2], toPane: 0, at: 0, in: task)

        #expect(!task.isSplit)
        #expect(ids(task) == ids([tabs[2], tabs[0], tabs[1]]))
        #expect(task.selectedTabID == tabs[2].id)
    }

    @Test func movingWithinAPaneCountsTheGapAsDrawn() throws {
        let context = try makeContext()
        let (task, tabs) = try makeTask(in: context)

        TaskStore.moveTab(tabs[0], toPane: 0, at: 2, in: task)

        #expect(ids(task) == ids([tabs[1], tabs[0], tabs[2]]))
    }

    @Test func reorderingAStripLeavesTheOtherPaneAlone() throws {
        let context = try makeContext()
        let (task, tabs) = try makeSplitTask(in: context)

        TaskStore.moveTab(tabs[3], toPane: 1, at: 0, in: task)

        #expect(ids(task) == ids([tabs[0], tabs[1]], [tabs[3], tabs[2]]))
    }

    @Test func reorderingTheUnfocusedStripKeepsFocusAndWhatEachPaneShows() throws {
        let context = try makeContext()
        let (task, tabs) = try makeSplitTask(in: context)
        let shown = task.paneTabIDs

        TaskStore.moveTab(tabs[1], toPane: 0, at: 0, in: task)

        #expect(ids(task) == ids([tabs[1], tabs[0]], [tabs[2], tabs[3]]))
        #expect(task.selectedTabID == tabs[2].id)
        #expect(task.paneTabIDs == shown)
    }

    @Test func droppingATabOnItsOwnPanesContentOnlyFocusesIt() throws {
        let context = try makeContext()
        let (task, tabs) = try makeSplitTask(in: context)

        TaskStore.openInSplit(tabs[1], side: .left, in: task)

        #expect(ids(task) == ids([tabs[0], tabs[1]], [tabs[2], tabs[3]]))
        #expect(task.selectedTabID == tabs[1].id)
    }

    @Test func splitRightNeedsASelectedTab() throws {
        let context = try makeContext()
        let (task, _) = try makeTask(in: context)
        #expect(TaskStore.canSplitRight(in: task))

        task.selectedTabID = nil
        #expect(!TaskStore.canSplitRight(in: task))

        task.selectedTabID = UUID()
        #expect(!TaskStore.canSplitRight(in: task))
    }

    @Test func aTabMovedToAnotherTaskLandsInItsLeftmostPane() throws {
        let context = try makeContext()
        let (source, tabs) = try makeTask(in: context)
        TaskStore.openInSplit(tabs[2], side: .right, in: source)
        let (destination, others) = try makeSplitTask(in: context)

        TaskStore.moveTab(tabs[2], to: destination)

        #expect(!source.isSplit)
        #expect(source.selectedTabID == tabs[0].id)
        #expect(ids(destination) == ids([others[0], others[1], tabs[2]], [others[2], others[3]]))
        #expect(destination.selectedTabID == tabs[2].id)
    }

    @Test func movingAPanedTabToANewTaskCollapsesTheSplit() throws {
        let context = try makeContext()
        let (task, tabs) = try makeTask(in: context)
        TaskStore.openInSplit(tabs[2], side: .right, in: task)

        let newTask = TaskStore.splitTabIntoNewTask(tabs[2], in: context, siblings: [task])

        #expect(!task.isSplit)
        #expect(ids(newTask) == ids([tabs[2]]))
        #expect(tabs[2].paneIndex == 0)
    }

    @Test func theSplitFractionIsClamped() throws {
        let context = try makeContext()
        let (task, _) = try makeTask(in: context)

        TaskStore.setSplitFraction(0.3, in: task)
        #expect(task.splitFraction == 0.3)

        TaskStore.setSplitFraction(-1, in: task)
        #expect(task.splitFraction == TaskStore.splitFractionRange.lowerBound)

        TaskStore.setSplitFraction(2, in: task)
        #expect(task.splitFraction == TaskStore.splitFractionRange.upperBound)
    }

    @Test func aRememberedSelectionNamingAMissingTabFallsBackToTheFirst() throws {
        let context = try makeContext()
        let (task, tabs) = try makeSplitTask(in: context)
        TaskStore.selectTab(tabs[3], in: task)
        TaskStore.selectTab(tabs[1], in: task)

        task.paneSelectedTabIDs = [nil, UUID()]

        #expect(task.paneTabIDs == [tabs[1].id, tabs[2].id])
    }
}

struct SplitLayoutTests {
    @Test func onePaneFillsTheWidth() {
        let layout = SplitLayout(paneCount: 1, fraction: 0.3, width: 1000, minimumPaneWidth: 360)

        #expect(!layout.isSplit)
        #expect(layout.pane(0) == .init(x: 0, width: 1000))
        #expect(layout.dividerX == nil)
    }

    @Test func twoPanesShareTheWidthAroundTheDivider() throws {
        let layout = SplitLayout(paneCount: 2, fraction: 0.5, width: 1001, minimumPaneWidth: 360)

        let leading = try #require(layout.pane(0))
        let trailing = try #require(layout.pane(1))
        #expect(leading.x == 0)
        #expect(leading.width == 500)
        #expect(trailing.x == 500 + SplitLayout.dividerWidth)
        #expect(leading.width + SplitLayout.dividerWidth + trailing.width == 1001)
    }

    @Test func eachPaneKeepsItsFloor() throws {
        let layout = SplitLayout(paneCount: 2, fraction: 0.1, width: 1001, minimumPaneWidth: 360)

        #expect(try #require(layout.pane(0)).width == 360)
        #expect(layout.fraction(forDividerAt: 990) == Double(1000 - 360) / 1000)
    }

    @Test func tooNarrowForBothFloorsSplitsEvenly() throws {
        let layout = SplitLayout(paneCount: 2, fraction: 0.8, width: 601, minimumPaneWidth: 360)

        #expect(try #require(layout.pane(0)).width == 300)
    }

    @Test func aDropLandsOnTheSideUnderIt() {
        let unsplit = SplitLayout(paneCount: 1, fraction: 0.5, width: 1000, minimumPaneWidth: 360)
        #expect(unsplit.side(forX: 499) == .left)
        #expect(unsplit.side(forX: 501) == .right)

        let split = SplitLayout(paneCount: 2, fraction: 0.6, width: 1001, minimumPaneWidth: 360)
        #expect(split.side(forX: 550) == .left)
        #expect(split.side(forX: 650) == .right)
    }
}
