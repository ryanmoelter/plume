import Foundation
import SwiftData
import Testing
@testable import Plume

/// A strip groups a tab with the unbroken run of its descendants after it,
/// counting ancestry only within the pane. Collapsing a group hides its
/// descendants' chips, moves a pane off a tab it hides, and selecting a
/// hidden tab expands the groups hiding it.
@MainActor
struct TabStripGroupingTests {
    private typealias Entry = TabStripGrouping.Entry

    @Test func aParentGroupsItsChildrenAndGrandchildren() {
        let parent = UUID(), child = UUID(), grandchild = UUID(), second = UUID(), other = UUID()
        let grouping = TabStripGrouping([
            Entry(id: parent, parentID: nil),
            Entry(id: child, parentID: parent),
            Entry(id: grandchild, parentID: child),
            Entry(id: second, parentID: parent),
            Entry(id: other, parentID: nil)
        ])

        #expect(grouping.groups == [
            .init(parentID: parent, range: 0...3, depth: 0, isCollapsed: false),
            .init(parentID: child, range: 1...2, depth: 1, isCollapsed: false)
        ])
        #expect(grouping.hidden.isEmpty)
    }

    @Test func aChildAwayFromItsParentIsNotGrouped() {
        let parent = UUID(), other = UUID(), child = UUID()
        let grouping = TabStripGrouping([
            Entry(id: parent, parentID: nil),
            Entry(id: other, parentID: nil),
            Entry(id: child, parentID: parent)
        ])
        #expect(grouping.groups.isEmpty)
    }

    /// The grandchild's parent sits in the other pane, so this pane sees no
    /// line from it to the grandparent.
    @Test func ancestryInAnotherPaneDoesNotGroup() {
        let parent = UUID(), childInOtherPane = UUID(), grandchild = UUID()
        let grouping = TabStripGrouping([
            Entry(id: parent, parentID: nil, childrenCollapsed: true),
            Entry(id: grandchild, parentID: childInOtherPane)
        ])
        #expect(grouping.groups.isEmpty)
        #expect(grouping.hidden.isEmpty)
    }

    @Test func collapsingHidesEveryDescendantButNotWhatFollows() {
        let parent = UUID(), child = UUID(), grandchild = UUID(), other = UUID()
        let grouping = TabStripGrouping([
            Entry(id: parent, parentID: nil, childrenCollapsed: true),
            Entry(id: child, parentID: parent),
            Entry(id: grandchild, parentID: child),
            Entry(id: other, parentID: nil)
        ])

        #expect(grouping.hidden == [child, grandchild])
        #expect(grouping.visibleIDs == [parent, other])
        #expect(grouping.visibleGroups.map(\.parentID) == [parent])
        #expect(grouping.lastVisibleID(in: grouping.groups[0]) == parent)
        #expect(grouping.collapsedParentsHiding(grandchild) == [parent])
        #expect(grouping.collapsedParentsHiding(other).isEmpty)
    }

    @Test func aCollapsedInnerGroupShortensTheOuterBar() {
        let parent = UUID(), child = UUID(), grandchild = UUID()
        let grouping = TabStripGrouping([
            Entry(id: parent, parentID: nil),
            Entry(id: child, parentID: parent, childrenCollapsed: true),
            Entry(id: grandchild, parentID: child)
        ])

        #expect(grouping.hidden == [grandchild])
        #expect(grouping.lastVisibleID(in: grouping.groups[0]) == child)
        #expect(grouping.collapsedParentsHiding(grandchild) == [child])
    }

    @Test func aDropGapCountsShownChipsAndSkipsHiddenOnes() {
        let parent = UUID(), child = UUID(), other = UUID()
        let grouping = TabStripGrouping([
            Entry(id: parent, parentID: nil, childrenCollapsed: true),
            Entry(id: child, parentID: parent),
            Entry(id: other, parentID: nil)
        ])

        #expect(grouping.paneIndex(forVisibleGap: 0) == 0)
        #expect(grouping.paneIndex(forVisibleGap: 1) == 2)
        #expect(grouping.paneIndex(forVisibleGap: 2) == 3)
    }

    @Test func collapsingMovesOnlyAHiddenShownTabToTheParent() {
        let parent = UUID(), child = UUID(), other = UUID()
        let grouping = TabStripGrouping([
            Entry(id: parent, parentID: nil),
            Entry(id: child, parentID: parent),
            Entry(id: other, parentID: nil)
        ])

        #expect(grouping.shownAfterCollapsing(parent, shown: child) == parent)
        #expect(grouping.shownAfterCollapsing(parent, shown: parent) == nil)
        #expect(grouping.shownAfterCollapsing(parent, shown: other) == nil)
        #expect(grouping.shownAfterCollapsing(parent, shown: nil) == nil)
    }

    // MARK: - Moves

    @Test func aParentMovesWithItsWholeGroup() throws {
        let parent = UUID(), child = UUID(), grandchild = UUID(), second = UUID(), other = UUID(), last = UUID()
        let pane = [
            Entry(id: parent, parentID: nil),
            Entry(id: child, parentID: parent),
            Entry(id: grandchild, parentID: child),
            Entry(id: second, parentID: parent),
            Entry(id: other, parentID: nil),
            Entry(id: last, parentID: nil)
        ]

        let move = try #require(TabStripMove.reorder(parent, in: pane, toward: 6))

        #expect(move == TabStripMove(ids: [parent, child, grandchild, second], gap: 2))
    }

    @Test func aChildMovesAmongItsSiblingsWithItsOwnChildren() throws {
        let parent = UUID(), first = UUID(), grandchild = UUID(), second = UUID(), third = UUID(), other = UUID()
        let pane = [
            Entry(id: parent, parentID: nil),
            Entry(id: first, parentID: parent),
            Entry(id: grandchild, parentID: first),
            Entry(id: second, parentID: parent),
            Entry(id: third, parentID: parent),
            Entry(id: other, parentID: nil)
        ]

        #expect(TabStripMove.reorder(third, in: pane, toward: 1) == TabStripMove(ids: [third], gap: 1))
        #expect(TabStripMove.reorder(first, in: pane, toward: 5) == TabStripMove(ids: [first, grandchild], gap: 3))
    }

    /// Gap 2 would split `first` from its grandchild, gap 0 is before the
    /// parent and gap 6 after `other`; each clamps to the nearest gap among
    /// the siblings.
    @Test func aChildDroppedOutsideItsParentClampsBackAmongItsSiblings() throws {
        let parent = UUID(), first = UUID(), grandchild = UUID(), second = UUID(), third = UUID(), other = UUID()
        let pane = [
            Entry(id: parent, parentID: nil),
            Entry(id: first, parentID: parent),
            Entry(id: grandchild, parentID: first),
            Entry(id: second, parentID: parent),
            Entry(id: third, parentID: parent),
            Entry(id: other, parentID: nil)
        ]

        #expect(TabStripMove.reorder(third, in: pane, toward: 0)?.gap == 1)
        #expect(TabStripMove.reorder(third, in: pane, toward: 6)?.gap == 4)
        #expect(TabStripMove.reorder(second, in: pane, toward: 2)?.gap == 1)
        #expect(TabStripMove.reorder(grandchild, in: pane, toward: 0)?.gap == 2)
    }

    @Test func aGroupNeverLandsInsideAnotherGroup() {
        let first = UUID(), firstChild = UUID(), secondChild = UUID(), other = UUID(), otherChild = UUID()
        let pane = [
            Entry(id: first, parentID: nil),
            Entry(id: firstChild, parentID: first),
            Entry(id: secondChild, parentID: first),
            Entry(id: other, parentID: nil),
            Entry(id: otherChild, parentID: other)
        ]

        #expect(TabStripMove.reorder(other, in: pane, toward: 2) == TabStripMove(ids: [other, otherChild], gap: 3))
        #expect(TabStripMove.reorder(other, in: pane, toward: 1) == TabStripMove(ids: [other, otherChild], gap: 0))
    }

    @Test func onlyATabWithoutAParentInItsPaneMovesToAnotherPane() {
        let parent = UUID(), child = UUID(), elsewhere = UUID(), elsewhereChild = UUID()
        let source = [Entry(id: parent, parentID: nil), Entry(id: child, parentID: parent)]
        let destination = [Entry(id: elsewhere, parentID: nil), Entry(id: elsewhereChild, parentID: elsewhere)]

        #expect(TabStripMove.transfer(child, from: source, to: destination, toward: nil) == nil)
        #expect(TabStripMove.transfer(parent, from: source, to: destination, toward: nil)
            == TabStripMove(ids: [parent, child], gap: 2))
        #expect(TabStripMove.transfer(parent, from: source, to: destination, toward: 1)?.gap == 0)
    }

    /// A child whose parent is in the other pane is top-level where it is,
    /// so it can move, and it lands in its parent's group.
    @Test func aChildMovingToItsParentsPaneJoinsItsGroup() {
        let parent = UUID(), sibling = UUID(), other = UUID(), child = UUID()
        let source = [Entry(id: child, parentID: parent)]
        let destination = [
            Entry(id: parent, parentID: nil),
            Entry(id: sibling, parentID: parent),
            Entry(id: other, parentID: nil)
        ]

        #expect(TabStripMove.transfer(child, from: source, to: destination, toward: nil)?.gap == 2)
        #expect(TabStripMove.transfer(child, from: source, to: destination, toward: 0)?.gap == 1)
    }

    @Test func aShownGapCountsOnlyShownChips() {
        let parent = UUID(), child = UUID(), other = UUID()
        let grouping = TabStripGrouping([
            Entry(id: parent, parentID: nil, childrenCollapsed: true),
            Entry(id: child, parentID: parent),
            Entry(id: other, parentID: nil)
        ])

        #expect(grouping.visibleGap(forPaneIndex: 1) == 1)
        #expect(grouping.visibleGap(forPaneIndex: 2) == 1)
        #expect(grouping.visibleGap(forPaneIndex: 3) == 2)
    }

    // MARK: - TaskStore

    private func makeTask() throws -> (ModelContext, WorkTask, TaskTab) {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let task = TaskStore.createTask(in: context, siblings: [])
        return (context, task, try #require(task.tabs.first))
    }

    @Test func collapsingWhileAChildIsSelectedSelectsTheParent() throws {
        let (context, task, parent) = try makeTask()
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        TaskStore.selectTab(child, in: task)

        TaskStore.setChildrenCollapsed(true, of: parent, in: task)

        #expect(parent.childrenCollapsed)
        #expect(task.selectedTabID == parent.id)
        #expect(task.liveTabs.contains { $0.id == child.id })
    }

    @Test func collapsingInAnUnfocusedPaneKeepsFocus() throws {
        let (context, task, parent) = try makeTask()
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let elsewhere = TaskStore.addTab(to: task, kind: .terminal, in: context)
        TaskStore.openInSplit(elsewhere, side: .right, in: task)
        TaskStore.selectTab(child, in: task)
        TaskStore.selectTab(elsewhere, in: task)

        TaskStore.setChildrenCollapsed(true, of: parent, in: task)

        #expect(task.selectedTabID == elsewhere.id)
        #expect(task.paneTabIDs == [parent.id, elsewhere.id])
    }

    @Test func selectingAHiddenChildExpandsItsParent() throws {
        let (context, task, parent) = try makeTask()
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        TaskStore.setChildrenCollapsed(true, of: parent, in: task)

        TaskStore.selectTab(child, in: task)

        #expect(!parent.childrenCollapsed)
        #expect(task.selectedTabID == child.id)
    }

    @Test func tabShortcutsCountOnlyShownChips() throws {
        let (context, task, parent) = try makeTask()
        _ = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let other = TaskStore.addTab(to: task, kind: .terminal, in: context)
        TaskStore.setChildrenCollapsed(true, of: parent, in: task)
        TaskStore.selectTab(parent, in: task)

        TaskStore.selectTab(atIndex: 1, in: task)
        #expect(task.selectedTabID == other.id)
        TaskStore.cycleTab(by: 1, in: task)
        #expect(task.selectedTabID == parent.id)
        #expect(parent.childrenCollapsed)
    }

    @Test func draggingACollapsedParentCarriesItsHiddenChildren() throws {
        let (context, task, parent) = try makeTask()
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let grandchild = TaskStore.addChildTab(to: task, parent: child, in: context)
        let other = TaskStore.addTab(to: task, kind: .terminal, in: context)
        TaskStore.setChildrenCollapsed(true, of: parent, in: task)

        TaskStore.moveTab(parent, toPane: 0, at: 4, in: task)

        #expect(task.orderedTabs.map(\.id) == [other.id, parent.id, child.id, grandchild.id])
        #expect(task.orderedTabs.map(\.orderIndex) == [0, 1, 2, 3])
        #expect(parent.childrenCollapsed)
    }

    @Test func aChildDraggedPastItsParentsGroupStaysAtItsEnd() throws {
        let (context, task, parent) = try makeTask()
        let first = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let second = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let other = TaskStore.addTab(to: task, kind: .terminal, in: context)

        #expect(TaskStore.landingIndex(of: first, toPane: 0, at: 4, in: task) == 3)
        TaskStore.moveTab(first, toPane: 0, at: 4, in: task)

        #expect(task.orderedTabs.map(\.id) == [parent.id, second.id, first.id, other.id])
    }

    @Test func aChildCannotLeaveItsParentsPane() throws {
        let (context, task, parent) = try makeTask()
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let elsewhere = TaskStore.addTab(to: task, kind: .terminal, in: context)
        TaskStore.openInSplit(elsewhere, side: .right, in: task)

        #expect(!TaskStore.canLeavePane(child, in: task))
        #expect(!TaskStore.canOpenInSplit(child, side: .right, in: task))
        #expect(TaskStore.canOpenInSplit(child, side: .left, in: task))
        #expect(TaskStore.landingIndex(of: child, toPane: 1, at: nil, in: task) == nil)
        TaskStore.moveTab(child, toPane: 1, in: task)

        #expect(task.panes.map { $0.map(\.id) } == [[parent.id, child.id], [elsewhere.id]])
    }

    @Test func aParentMovesToTheOtherPaneWithItsChildren() throws {
        let (context, task, parent) = try makeTask()
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let elsewhere = TaskStore.addTab(to: task, kind: .terminal, in: context)
        TaskStore.openInSplit(elsewhere, side: .right, in: task)
        let stays = TaskStore.addTab(to: task, kind: .terminal, pane: 0, in: context)

        TaskStore.moveTab(parent, toPane: 1, at: 0, in: task)

        #expect(task.panes.map { $0.map(\.id) } == [[stays.id], [parent.id, child.id, elsewhere.id]])
        #expect(task.panes.map { $0.map(\.orderIndex) } == [[0], [0, 1, 2]])
        #expect(task.selectedTabID == parent.id)
    }

    @Test func openingAParentInASplitTakesItsChildren() throws {
        let (context, task, parent) = try makeTask()
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let other = TaskStore.addTab(to: task, kind: .terminal, in: context)

        #expect(!TaskStore.canOpenInSplit(child, in: task))
        TaskStore.openInSplit(parent, side: .right, in: task)

        #expect(task.panes.map { $0.map(\.id) } == [[other.id], [parent.id, child.id]])
        #expect(task.paneTabIDs == [other.id, parent.id])
    }

    @Test func aParentWithEveryTabAsItsGroupCannotOpenInASplit() throws {
        let (context, task, parent) = try makeTask()
        _ = TaskStore.addChildTab(to: task, parent: parent, in: context)

        #expect(!TaskStore.canOpenInSplit(parent, in: task))
    }

    @Test func theInfoPaneListsEveryDescendantNested() {
        struct Row { let id: UUID; let parent: UUID? }
        let root = UUID(), child = UUID(), grandchild = UUID(), second = UUID(), stranger = UUID()
        let rows = [
            Row(id: root, parent: nil),
            Row(id: grandchild, parent: child),
            Row(id: stranger, parent: nil),
            Row(id: child, parent: root),
            Row(id: second, parent: root)
        ]

        let descendants = InfoPaneFacts.descendants(of: root, in: rows, id: \.id, parentID: \.parent)

        #expect(descendants.map(\.item.id) == [child, grandchild, second])
        #expect(descendants.map(\.depth) == [0, 1, 0])
    }
}
