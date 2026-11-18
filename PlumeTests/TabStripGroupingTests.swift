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
