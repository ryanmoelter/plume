import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Plume

struct SidebarDragItemTests {
    @Test(arguments: [
        SidebarDragItem.tab(UUID()), .task(UUID()), .group(UUID()),
    ])
    func payloadRoundTrips(item: SidebarDragItem) {
        #expect(SidebarDragItem(payload: item.payload) == item)
    }

    @Test(arguments: [
        "",
        UUID().uuidString,
        "plume-tab:not-a-uuid",
        "plume-window:\(UUID().uuidString)",
        "some dragged text",
    ])
    func foreignTextIsNoItem(payload: String) {
        #expect(SidebarDragItem(payload: payload) == nil)
    }
}

struct SidebarDropRulesTests {
    private let a = UUID(), b = UUID(), c = UUID()

    @Test func tabLandsInATaskWhereverItIsOver() {
        for y: CGFloat in [1, 20, 39] {
            #expect(SidebarDropRules.placement(of: .tab(a), over: .task(b), y: y, height: 40) == .into)
        }
    }

    @Test func taskReordersByWhichHalfItIsOver() {
        #expect(SidebarDropRules.placement(of: .task(a), over: .task(b), y: 10, height: 40) == .before)
        #expect(SidebarDropRules.placement(of: .task(a), over: .task(b), y: 30, height: 40) == .after)
    }

    @Test func taskLandsInAGroup() {
        #expect(SidebarDropRules.placement(of: .task(a), over: .group(b), y: 5, height: 20) == .into)
    }

    @Test func groupReordersAmongGroupsOnly() {
        #expect(SidebarDropRules.placement(of: .group(a), over: .group(b), y: 15, height: 20) == .after)
        #expect(SidebarDropRules.placement(of: .group(a), over: .task(b), y: 15, height: 20) == nil)
        #expect(SidebarDropRules.placement(of: .tab(a), over: .group(b), y: 15, height: 20) == nil)
    }

    @Test func droppingOnItselfDoesNothing() {
        #expect(SidebarDropRules.placement(of: .task(a), over: .task(a), y: 5, height: 40) == nil)
        #expect(SidebarDropRules.placement(of: .group(a), over: .group(a), y: 5, height: 20) == nil)
    }

    @Test func moveOffsetsMatchArrayMove() throws {
        let ids = [a, b, c]

        let beforeFirst = try #require(SidebarDropRules.move(c, .before, a, in: ids))
        var moved = ids
        moved.move(fromOffsets: IndexSet(integer: beforeFirst.from), toOffset: beforeFirst.to)
        #expect(moved == [c, a, b])

        let afterLast = try #require(SidebarDropRules.move(a, .after, c, in: ids))
        moved = ids
        moved.move(fromOffsets: IndexSet(integer: afterLast.from), toOffset: afterLast.to)
        #expect(moved == [b, c, a])

        let afterFirst = try #require(SidebarDropRules.move(c, .after, a, in: ids))
        moved = ids
        moved.move(fromOffsets: IndexSet(integer: afterFirst.from), toOffset: afterFirst.to)
        #expect(moved == [a, c, b])
    }

    @Test func moveNeedsBothInTheList() {
        #expect(SidebarDropRules.move(UUID(), .before, a, in: [a, b]) == nil)
        #expect(SidebarDropRules.move(a, .before, UUID(), in: [a, b]) == nil)
        #expect(SidebarDropRules.move(a, .into, b, in: [a, b]) == nil)
    }
}

/// Every way a drag leaves or ends clears the feedback it drew, and nothing
/// draws once the drag is over.
@MainActor
struct InAppDragTests {
    private let a = UUID(), b = UUID(), task = UUID(), otherTask = UUID()

    private func dragWithFeedback() -> InAppDrag {
        let drag = InAppDrag()
        drag.begin(.task(a))
        drag.showSidebarIndicator(SidebarDropIndicator(target: .task(b), placement: .before))
        drag.showTabStripGap(TabStripGap(taskID: task, gap: 1))
        return drag
    }

    @Test func updatesDrawFeedbackDuringADrag() {
        let drag = dragWithFeedback()
        #expect(drag.sidebarIndicator == SidebarDropIndicator(target: .task(b), placement: .before))
        #expect(drag.tabStripGap == TabStripGap(taskID: task, gap: 1))
    }

    @Test func aForeignDragDrawsNothing() {
        let drag = InAppDrag()
        drag.showSidebarIndicator(SidebarDropIndicator(target: .task(b), placement: .into))
        drag.showTabStripGap(TabStripGap(taskID: task, gap: 0))
        #expect(drag.sidebarIndicator == nil)
        #expect(drag.tabStripGap == nil)
    }

    @Test func exitClearsOnlyItsOwnTarget() {
        let drag = dragWithFeedback()
        drag.clearSidebarIndicator(on: .task(a))
        drag.clearTabStripGap(in: otherTask)
        #expect(drag.sidebarIndicator != nil)
        #expect(drag.tabStripGap != nil)

        drag.clearSidebarIndicator(on: .task(b))
        drag.clearTabStripGap(in: task)
        #expect(drag.sidebarIndicator == nil)
        #expect(drag.tabStripGap == nil)
    }

    @Test func dropHandsOverTheItemAndClearsEverything() {
        let drag = dragWithFeedback()
        #expect(drag.takeForDrop() == .task(a))
        #expect(drag.item == nil)
        #expect(drag.sidebarIndicator == nil)
        #expect(drag.tabStripGap == nil)
        #expect(drag.takeForDrop() == nil)
    }

    @Test func anUpdateAfterTheDropDrawsNothing() {
        let drag = dragWithFeedback()
        _ = drag.takeForDrop()
        drag.showSidebarIndicator(SidebarDropIndicator(target: .task(b), placement: .after))
        drag.showTabStripGap(TabStripGap(taskID: task, gap: 2))
        #expect(drag.sidebarIndicator == nil)
        #expect(drag.tabStripGap == nil)
    }

    @Test func releaseClearsFeedbackAtOnceAndTheItemAfterTheGrace() async {
        let drag = InAppDrag(releaseGrace: .milliseconds(1))
        drag.begin(.tab(a))
        drag.showTabStripGap(TabStripGap(taskID: task, gap: 0))
        let release = drag.buttonReleased()
        #expect(drag.tabStripGap == nil)
        #expect(drag.item == .tab(a))
        await release.value
        #expect(drag.item == nil)
    }

    @Test func aDragBegunDuringTheGraceSurvivesTheRelease() async {
        let drag = InAppDrag(releaseGrace: .milliseconds(1))
        drag.begin(.tab(a))
        let release = drag.buttonReleased()
        drag.begin(.task(b))
        await release.value
        #expect(drag.item == .task(b))
    }

    @Test func beginClearsFeedbackLeftByAnEarlierDrag() {
        let drag = dragWithFeedback()
        drag.begin(.tab(b))
        #expect(drag.item == .tab(b))
        #expect(drag.sidebarIndicator == nil)
        #expect(drag.tabStripGap == nil)
    }
}
