import Foundation
import SwiftData
import Testing
@testable import Plume

/// A strip groups a tab with the children attached to it: the unbroken run
/// after it of tabs whose own parent is already in the run. A move lands
/// where it is dropped unless it would split a run it does not join, and then
/// goes past that run. Collapsing a group hides its attached children's chips,
/// moves a pane off a tab it hides, and selecting a hidden tab expands the
/// groups hiding it.
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

    /// A grandchild is attached only through an attached parent: after a
    /// detached child it is that child's alone, and after a sibling of its
    /// parent it is nobody's.
    @Test func aDescendantAttachesOnlyThroughAnAttachedParent() {
        let parent = UUID(), other = UUID(), child = UUID(), grandchild = UUID()
        let detached = TabStripGrouping([
            Entry(id: parent, parentID: nil),
            Entry(id: other, parentID: nil),
            Entry(id: child, parentID: parent),
            Entry(id: grandchild, parentID: child)
        ])
        #expect(detached.groups == [.init(parentID: child, range: 2...3, depth: 0, isCollapsed: false)])
        #expect(!detached.isAttached(child, to: parent))
        #expect(detached.isAttached(grandchild, to: child))

        let sibling = UUID()
        let orphaned = TabStripGrouping([
            Entry(id: parent, parentID: nil),
            Entry(id: sibling, parentID: parent),
            Entry(id: grandchild, parentID: child)
        ])
        #expect(orphaned.groups == [.init(parentID: parent, range: 0...1, depth: 0, isCollapsed: false)])
        #expect(orphaned.endOfRun(of: parent) == 2)
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

    /// Strip: parent, first, grandchild (of first), second, third, other.
    private static func family() -> (pane: [Entry], parent: UUID, first: UUID, grandchild: UUID, second: UUID, third: UUID) {
        let parent = UUID(), first = UUID(), grandchild = UUID(), second = UUID(), third = UUID(), other = UUID()
        let pane = [
            Entry(id: parent, parentID: nil),
            Entry(id: first, parentID: parent),
            Entry(id: grandchild, parentID: first),
            Entry(id: second, parentID: parent),
            Entry(id: third, parentID: parent),
            Entry(id: other, parentID: nil)
        ]
        return (pane, parent, first, grandchild, second, third)
    }

    @Test func aChildDroppedOutsideItsParentsRunLandsThereDetached() {
        let family = Self.family()

        #expect(TabStripMove.reorder(family.third, in: family.pane, toward: 0) == TabStripMove(ids: [family.third], gap: 0))
        #expect(TabStripMove.reorder(family.third, in: family.pane, toward: 6)?.gap == 5)
        #expect(TabStripMove.reorder(family.first, in: family.pane, toward: 6)
            == TabStripMove(ids: [family.first, family.grandchild], gap: 4))
    }

    @Test func aChildDroppedInsideItsParentsRunStaysAttached() {
        let family = Self.family()

        #expect(TabStripMove.reorder(family.third, in: family.pane, toward: 1)?.gap == 1)
        #expect(TabStripMove.reorder(family.first, in: family.pane, toward: 5)
            == TabStripMove(ids: [family.first, family.grandchild], gap: 3))
    }

    /// Gap 2 is inside `first`'s own run, which `second` would split, so it
    /// goes past that run and stays in its parent's.
    @Test func aChildDroppedInsideASiblingsRunGoesPastIt() {
        let family = Self.family()

        #expect(TabStripMove.reorder(family.second, in: family.pane, toward: 2)?.gap == 3)
    }

    /// An unrelated tab dropped anywhere inside a run goes past its end
    /// rather than splitting it.
    @Test func anUnrelatedTabDroppedInsideARunGoesPastIt() {
        let first = UUID(), firstChild = UUID(), secondChild = UUID(), other = UUID(), otherChild = UUID()
        let pane = [
            Entry(id: first, parentID: nil),
            Entry(id: firstChild, parentID: first),
            Entry(id: secondChild, parentID: first),
            Entry(id: other, parentID: nil),
            Entry(id: otherChild, parentID: other)
        ]

        #expect(TabStripMove.reorder(other, in: pane, toward: 2) == TabStripMove(ids: [other, otherChild], gap: 3))
        #expect(TabStripMove.reorder(other, in: pane, toward: 1) == TabStripMove(ids: [other, otherChild], gap: 3))
        #expect(TabStripMove.reorder(other, in: pane, toward: 0) == TabStripMove(ids: [other, otherChild], gap: 0))
    }

    @Test func anyTabMovesToAnotherPaneWithItsAttachedChildren() {
        let parent = UUID(), child = UUID(), elsewhere = UUID(), elsewhereChild = UUID()
        let source = [Entry(id: parent, parentID: nil), Entry(id: child, parentID: parent)]
        let destination = [Entry(id: elsewhere, parentID: nil), Entry(id: elsewhereChild, parentID: elsewhere)]

        #expect(TabStripMove.transfer(child, from: source, to: destination, toward: nil) == TabStripMove(ids: [child], gap: 2))
        #expect(TabStripMove.transfer(parent, from: source, to: destination, toward: nil)
            == TabStripMove(ids: [parent, child], gap: 2))
        #expect(TabStripMove.transfer(parent, from: source, to: destination, toward: 1)?.gap == 2)
    }

    @Test func aChildMovingToItsParentsPaneAttachesOnlyInsideTheRun() {
        let parent = UUID(), sibling = UUID(), other = UUID(), child = UUID()
        let source = [Entry(id: child, parentID: parent)]
        let destination = [
            Entry(id: parent, parentID: nil),
            Entry(id: sibling, parentID: parent),
            Entry(id: other, parentID: nil)
        ]

        #expect(TabStripMove.transfer(child, from: source, to: destination, toward: nil)?.gap == 3)
        #expect(TabStripMove.transfer(child, from: source, to: destination, toward: 0)?.gap == 0)
        #expect(TabStripMove.transfer(child, from: source, to: destination, toward: 1)?.gap == 1)
        #expect(TabStripMove.transfer(child, from: source, to: destination, toward: 2)?.gap == 2)
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

    @Test func aChildDraggedPastItsParentsRunDetaches() throws {
        let (context, task, parent) = try makeTask()
        let first = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let second = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let other = TaskStore.addTab(to: task, kind: .terminal, in: context)

        #expect(TaskStore.landingIndex(of: first, toPane: 0, at: 4, in: task) == 4)
        TaskStore.moveTab(first, toPane: 0, at: 4, in: task)

        #expect(task.orderedTabs.map(\.id) == [parent.id, second.id, other.id, first.id])
        #expect(!TaskStore.isAttachedToParent(first))
        #expect(TaskStore.isAttachedToParent(second))
    }

    @Test func anUnrelatedTabDroppedInsideARunLandsAfterIt() throws {
        let (context, task, parent) = try makeTask()
        let other = TaskStore.addTab(to: task, kind: .terminal, in: context)
        let first = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let second = TaskStore.addChildTab(to: task, parent: parent, in: context)
        #expect(task.orderedTabs.map(\.id) == [parent.id, first.id, second.id, other.id])

        #expect(TaskStore.landingIndex(of: other, toPane: 0, at: 1, in: task) == 3)
        TaskStore.moveTab(other, toPane: 0, at: 1, in: task)

        #expect(task.orderedTabs.map(\.id) == [parent.id, first.id, second.id, other.id])
        #expect(TaskStore.isAttachedToParent(first) && TaskStore.isAttachedToParent(second))
    }

    @Test func aChildMovesToTheOtherPaneAlone() throws {
        let (context, task, parent) = try makeTask()
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let elsewhere = TaskStore.addTab(to: task, kind: .terminal, in: context)
        TaskStore.openInSplit(elsewhere, side: .right, in: task)

        #expect(TaskStore.canOpenInSplit(child, side: .right, in: task))
        TaskStore.moveTab(child, toPane: 1, in: task)

        #expect(task.panes.map { $0.map(\.id) } == [[parent.id], [elsewhere.id, child.id]])
        #expect(task.selectedTabID == child.id)
        #expect(TaskStore.grouping(of: task.tabs(inPane: 0)).groups.isEmpty)
        #expect(TaskStore.canMoveNextToParent(child))
    }

    @Test func aParentMovesToTheOtherPaneWithOnlyItsAttachedChildren() throws {
        let (context, task, parent) = try makeTask()
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let detached = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let elsewhere = TaskStore.addTab(to: task, kind: .terminal, in: context)
        TaskStore.openInSplit(elsewhere, side: .right, in: task)
        let stays = TaskStore.addTab(to: task, kind: .terminal, pane: 0, in: context)
        TaskStore.moveTab(detached, toPane: 0, at: 4, in: task)

        TaskStore.moveTab(parent, toPane: 1, at: 0, in: task)

        let expected: [[UUID]] = [[stays.id, detached.id], [parent.id, child.id, elsewhere.id]]
        #expect(task.panes.map { $0.map(\.id) } == expected)
        #expect(task.panes.map { $0.map(\.orderIndex) } == [[0, 1], [0, 1, 2]])
        #expect(task.selectedTabID == parent.id)
    }

    @Test func openingAParentInASplitTakesItsChildren() throws {
        let (context, task, parent) = try makeTask()
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let other = TaskStore.addTab(to: task, kind: .terminal, in: context)

        #expect(TaskStore.canOpenInSplit(child, in: task))
        TaskStore.openInSplit(parent, side: .right, in: task)

        #expect(task.panes.map { $0.map(\.id) } == [[other.id], [parent.id, child.id]])
        #expect(task.paneTabIDs == [other.id, parent.id])
    }

    @Test func aParentWithEveryTabAsItsGroupCannotOpenInASplit() throws {
        let (context, task, parent) = try makeTask()
        _ = TaskStore.addChildTab(to: task, parent: parent, in: context)

        #expect(!TaskStore.canOpenInSplit(parent, in: task))
    }

    private struct Row { let id: UUID; let parent: UUID? }

    @Test func theInfoPaneListsOnlyDirectRelations() {
        let root = UUID(), child = UUID(), grandchild = UUID(), second = UUID(), stranger = UUID()
        let rows = [
            Row(id: root, parent: nil),
            Row(id: grandchild, parent: child),
            Row(id: stranger, parent: nil),
            Row(id: child, parent: root),
            Row(id: second, parent: root)
        ]

        let forRoot = InfoPaneFacts.directRelations(of: root, in: rows, id: \.id, parentID: \.parent)
        #expect(forRoot.parent == nil)
        #expect(forRoot.children.map(\.id) == [child, second])

        let forChild = InfoPaneFacts.directRelations(of: child, in: rows, id: \.id, parentID: \.parent)
        #expect(forChild.parent?.id == root)
        #expect(forChild.children.map(\.id) == [grandchild])

        let forGrandchild = InfoPaneFacts.directRelations(of: grandchild, in: rows, id: \.id, parentID: \.parent)
        #expect(forGrandchild.parent?.id == child)
        #expect(forGrandchild.children.isEmpty)
    }

    @Test func aParentThatIsNoLongerOpenIsLeftOut() {
        let child = UUID()
        let rows = [Row(id: child, parent: UUID())]

        let relations = InfoPaneFacts.directRelations(of: child, in: rows, id: \.id, parentID: \.parent)

        #expect(relations.parent == nil)
        #expect(relations.children.isEmpty)
    }
}
