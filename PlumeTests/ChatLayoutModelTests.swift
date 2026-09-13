import CoreGraphics
import Foundation
import Testing
@testable import Plume

@MainActor
struct ChatLayoutModelTests {
    private func item(
        _ id: String,
        _ height: CGFloat,
        top: CGFloat = 0,
        bottom: CGFloat = 0,
        folds: Bool = false
    ) -> ChatLayoutItem {
        ChatLayoutItem(id: id, topInset: top, bottomInset: bottom, estimatedHeight: height, folds: folds)
    }

    // MARK: - Items

    @Test func aNewItemStartsWithTargetDisplayAndEstimateEqual() {
        var model = ChatLayoutModel()
        model.setItems([item("a", 10)])
        #expect(model.targetHeight(of: "a") == 10)
        #expect(model.displayHeight(of: "a") == 10)
    }

    @Test func anEstimateUpdatesOnlyAnUnmeasuredItem() {
        var model = ChatLayoutModel()
        model.measurementWidth = 300
        model.setItems([item("a", 10), item("b", 10)])
        let generation = model.realize("b")
        model.setTargetHeight(50, for: "b", width: 300, generation: generation)

        model.updateEstimate(30, for: "a")
        model.updateEstimate(30, for: "b")

        #expect(model.targetHeight(of: "a") == 30)
        #expect(model.displayHeight(of: "a") == 30)
        #expect(model.targetHeight(of: "b") == 50)
        #expect(model.contentHeight == 80)
    }

    @Test func measuredHeightsSurviveAcrossSetItemsForIDsStillPresent() {
        var model = ChatLayoutModel()
        model.measurementWidth = 300
        model.setItems([item("a", 10), item("b", 10)])
        let generation = model.realize("b")
        let accepted = model.setTargetHeight(50, for: "b", width: 300, generation: generation)
        #expect(accepted)

        model.setItems([item("b", 10), item("a", 10)])

        #expect(model.targetHeight(of: "b") == 50)
        #expect(model.displayHeight(of: "b") == 50)
    }

    @Test func measurementsForRemovedIDsAreDropped() {
        var model = ChatLayoutModel()
        model.measurementWidth = 300
        model.setItems([item("a", 10), item("b", 10)])
        let generation = model.realize("a")
        let accepted = model.setTargetHeight(40, for: "a", width: 300, generation: generation)
        #expect(accepted)

        model.setItems([item("b", 10)])
        #expect(model.index(of: "a") == nil)

        model.setItems([item("a", 99), item("b", 10)])
        #expect(model.targetHeight(of: "a") == 99)
        #expect(!model.hasMeasurement("a"))
    }

    // MARK: - Heights

    @Test func displayHeightIsIndependentOfTargetUntilSnapped() {
        var model = ChatLayoutModel()
        model.setItems([item("a", 10)])
        model.setDisplayHeight(5, for: "a")
        #expect(model.displayHeight(of: "a") == 5)
        #expect(model.targetHeight(of: "a") == 10)

        model.snapDisplayHeights()
        #expect(model.displayHeight(of: "a") == 10)
    }

    // MARK: - Stamped measurements

    @Test func realizeReturnsIncreasingGenerationsPerID() {
        var model = ChatLayoutModel()
        model.setItems([item("a", 10)])
        #expect(model.realize("a") == 1)
        #expect(model.realize("a") == 2)
        #expect(model.realize("a") == 3)
    }

    @Test func firstMeasurementJumpsDisplayHeightToo() {
        var model = ChatLayoutModel()
        model.measurementWidth = 200
        model.setItems([item("a", 10)])
        let generation = model.realize("a")
        #expect(!model.hasMeasurement("a"))

        let accepted = model.setTargetHeight(80, for: "a", width: 200, generation: generation)
        #expect(accepted)

        #expect(model.hasMeasurement("a"))
        #expect(model.targetHeight(of: "a") == 80)
        #expect(model.displayHeight(of: "a") == 80)
    }

    @Test func secondMeasurementUpdatesTargetOnlyNotDisplay() {
        var model = ChatLayoutModel()
        model.measurementWidth = 200
        model.setItems([item("a", 10)])
        let firstGeneration = model.realize("a")
        let firstAccepted = model.setTargetHeight(80, for: "a", width: 200, generation: firstGeneration)
        #expect(firstAccepted)

        model.setDisplayHeight(30, for: "a")
        let secondGeneration = model.realize("a")
        let secondAccepted = model.setTargetHeight(120, for: "a", width: 200, generation: secondGeneration)
        #expect(secondAccepted)

        #expect(model.targetHeight(of: "a") == 120)
        #expect(model.displayHeight(of: "a") == 30)
    }

    @Test func staleGenerationAndStaleWidthReportsAreBothRejected() {
        var model = ChatLayoutModel()
        model.measurementWidth = 300
        model.setItems([item("a", 10)])
        let firstGeneration = model.realize("a")
        let accepted = model.setTargetHeight(50, for: "a", width: 300, generation: firstGeneration)
        #expect(accepted)
        let secondGeneration = model.realize("a")

        let staleWidth = model.setTargetHeight(999, for: "a", width: 250, generation: secondGeneration)
        #expect(!staleWidth)
        let staleGeneration = model.setTargetHeight(999, for: "a", width: 300, generation: firstGeneration)
        #expect(!staleGeneration)
        #expect(model.targetHeight(of: "a") == 50)
    }

    @Test func realizeAndSetTargetHeightOnUnknownIDsAreNoOps() {
        var model = ChatLayoutModel()
        #expect(model.realize("ghost") == 0)
        let accepted = model.setTargetHeight(10, for: "ghost", width: 0, generation: 0)
        #expect(!accepted)
    }

    // MARK: - Geometry

    @Test func slotTopStacksItemsContiguously() {
        var model = ChatLayoutModel()
        model.setItems([item("a", 10), item("b", 20), item("c", 30)])
        #expect(model.slotTop(of: "a") == 0)
        #expect(model.slotTop(of: "b") == 10)
        #expect(model.slotTop(of: "c") == 30)
        #expect(model.contentHeight == 60)
    }

    @Test func frameAddsTopInsetOnTopOfSlotTop() {
        var model = ChatLayoutModel()
        model.measurementWidth = 400
        model.setItems([
            item("a", 10, top: 5, bottom: 3),
            item("b", 20),
        ])

        #expect(model.slotTop(of: "a") == 0)
        #expect(model.frame(of: "a") == CGRect(x: 0, y: 5, width: 400, height: 10))
        #expect(model.slotTop(of: "b") == 18)
        #expect(model.frame(of: "b")?.origin.y == 18)
        #expect(model.frame(of: "missing") == nil)
    }

    @Test func totalHeightAndMaxOffsetIncludeTrailingInsetButNoSlackWithoutAnAnchor() {
        var model = ChatLayoutModel()
        model.setItems([item("a", 60)])
        model.trailingInset = 5
        model.viewportHeight = 25

        #expect(model.slack == 0)
        #expect(model.totalHeight == 65)
        #expect(model.maxOffset == 40)
    }

    // MARK: - Slack (send-to-top)

    /// Simulates a sent prompt anchored at the top while a reply streams in,
    /// piece by piece. Until the reply fills the viewport the prompt stays
    /// put through every height change in either direction; once it has,
    /// a disclosure collapsing or the viewport growing leaves the reader
    /// following the bottom rather than snapping back to the prompt.
    @Test func slackPinsThePromptUntilTheReplyFillsTheViewport() {
        var model = ChatLayoutModel()
        model.viewportHeight = 100
        model.setItems([item("p", 20)])
        model.setAnchor("p")

        #expect(model.slack == 80)
        #expect(model.maxOffset == 0)

        model.setItems([item("p", 20), item("r1", 30)])
        #expect(model.slack == 50)
        #expect(model.maxOffset == 0)

        // A block re-wrapping a line taller for a frame, then back.
        model.setDisplayHeight(40, for: "r1")
        #expect(model.slack == 40)
        model.setDisplayHeight(30, for: "r1")
        #expect(model.slack == 50)
        #expect(model.maxOffset == 0)

        model.setItems([item("p", 20), item("r1", 30), item("r2", 60)])
        #expect(model.slack == 0)
        #expect(model.maxOffset == 10)

        model.setDisplayHeight(10, for: "r2")
        #expect(model.slack == 0)

        model.viewportHeight = 200
        #expect(model.slack == 0)

        // The next prompt starts over.
        model.setAnchor("r2")
        #expect(model.slack > 0)
    }

    // MARK: - The fold

    @Test func followingRestsWithTheFoldBehindTheComposerAndScrollingRevealsIt() {
        var model = ChatLayoutModel()
        model.viewportHeight = 100
        model.trailingInset = 20
        model.setItems([item("a", 150), item("header", 10), item("rows", 40, bottom: 5, folds: true)])
        #expect(model.foldHeight == 45)
        #expect(model.maxOffset == 125)
        #expect(model.followOffset == 80)
    }

    @Test func onlyATrailingRunFolds() {
        var model = ChatLayoutModel()
        model.viewportHeight = 100
        model.setItems([item("a", 150, folds: true), item("b", 10), item("c", 30, folds: true), item("d", 20, folds: true)])
        #expect(model.foldHeight == 50)
        model.setItems([item("a", 150, folds: true), item("b", 10)])
        #expect(model.foldHeight == 0)
    }

    /// The fold is not content the reply has to grow past: it slides behind
    /// the composer before following starts.
    @Test func slackCountsOnlyTheHeldContent() {
        var model = ChatLayoutModel()
        model.viewportHeight = 100
        model.setItems([item("p", 20), item("rows", 30, folds: true)])
        model.setAnchor("p")
        #expect(model.slack == 80)
        #expect(model.followOffset == 0)

        model.setItems([item("p", 20), item("r1", 80), item("rows", 30, folds: true)])
        #expect(model.slack == 0)
        #expect(model.maxOffset == 30)
        #expect(model.followOffset == 0)
    }

    @Test func anAnchorMissingFromItemsGivesZeroSlack() {
        var model = ChatLayoutModel()
        model.viewportHeight = 100
        model.setItems([item("a", 10)])
        model.setAnchor("missing")
        #expect(model.slack == 0)
    }

    @Test func settingAnchorToNilClearsSlack() {
        var model = ChatLayoutModel()
        model.viewportHeight = 100
        model.setItems([item("p", 20)])
        model.setAnchor("p")
        #expect(model.slack > 0)

        model.setAnchor(nil)
        #expect(model.slack == 0)
        #expect(model.anchorID == nil)
    }

    @Test func slackIsNotRecomputedWhileTheViewportIsHiddenButAppliesOnceItShows() {
        var model = ChatLayoutModel()
        model.setItems([item("p", 20)])
        model.setAnchor("p")
        #expect(model.slack == 0)

        model.viewportHeight = 100
        #expect(model.slack == 80)
    }

    // MARK: - Windows

    @Test func realizedRangeFindsSlotsIntersectingTheOverscanWindow() {
        var model = ChatLayoutModel()
        model.setItems((0..<10).map { item("\($0)", 20) })
        model.viewportHeight = 50

        #expect(model.realizedRange(offset: 100) == 3..<9)
    }

    @Test func realizedRangeIsEmptyWhenHiddenOrEmpty() {
        var hidden = ChatLayoutModel()
        hidden.setItems([item("a", 10)])
        #expect(hidden.realizedRange(offset: 0) == 0..<0)

        var empty = ChatLayoutModel()
        empty.viewportHeight = 100
        #expect(empty.realizedRange(offset: 0) == 0..<0)
    }

    @Test func realizedRangeTrimsToMaxRealizedDroppingFromTheEndsAlternately() {
        var model = ChatLayoutModel(overscan: 0, maxRealized: 3)
        model.setItems((0..<10).map { item("\($0)", 10) })
        model.viewportHeight = 100

        #expect(model.realizedRange(offset: 0) == 4..<7)
    }

    // MARK: - Visible ids

    @Test func visibleIDsExcludesAnItemEntirelyBehindTheTrailingInset() {
        var model = ChatLayoutModel()
        model.setItems([item("a", 40), item("b", 40), item("c", 40)])
        model.viewportHeight = 100
        model.trailingInset = 30

        #expect(model.visibleIDs(offset: 0) == ["a", "b"])
    }

    @Test func visibleIDsShiftWithTheOffsetAndStayInOrder() {
        var model = ChatLayoutModel()
        model.setItems([item("a", 40), item("b", 40), item("c", 40)])
        model.viewportHeight = 100
        model.trailingInset = 30

        #expect(model.visibleIDs(offset: 50) == ["b", "c"])
    }

    // MARK: - Preservation

    @Test func readerAnchorFindsTheItemStraddlingTheViewportTop() {
        var model = ChatLayoutModel()
        model.setItems([item("a", 10), item("b", 20), item("c", 30)])

        let anchor = model.readerAnchor(offset: 15)
        #expect(anchor?.id == "b")
        #expect(anchor?.distance == 5)
    }

    @Test func offsetKeepingClampsToMaxOffset() {
        var model = ChatLayoutModel()
        model.setItems([item("a", 10), item("b", 20), item("c", 30)])

        #expect(model.offset(keeping: "b", distance: 5) == 15)
        #expect(model.offset(keeping: "c", distance: 100) == model.maxOffset)
    }

    @Test func measuringAnItemAboveTheReaderMovesThePreservedOffsetByTheGrowth() {
        var model = ChatLayoutModel()
        model.setItems([item("a", 10), item("b", 20), item("c", 30)])
        let anchor = model.readerAnchor(offset: 15)!
        let before = model.offset(keeping: anchor.id, distance: anchor.distance)

        model.setDisplayHeight(110, for: "a")
        let after = model.offset(keeping: anchor.id, distance: anchor.distance)

        #expect(after - before == 100)
    }

    @Test func measuringAnItemBelowTheReaderDoesNotMoveThePreservedOffset() {
        var model = ChatLayoutModel()
        model.setItems([item("a", 10), item("b", 20), item("c", 30)])
        let anchor = model.readerAnchor(offset: 15)!
        let before = model.offset(keeping: anchor.id, distance: anchor.distance)

        model.setDisplayHeight(130, for: "c")
        let after = model.offset(keeping: anchor.id, distance: anchor.distance)

        #expect(after == before)
    }

    @Test func theAnchorItemItselfGrowingDoesNotMoveThePreservedOffset() {
        var model = ChatLayoutModel()
        model.setItems([item("a", 10), item("b", 20), item("c", 30)])
        let anchor = model.readerAnchor(offset: 15)!
        let before = model.offset(keeping: anchor.id, distance: anchor.distance)

        model.setDisplayHeight(200, for: "b")
        let after = model.offset(keeping: anchor.id, distance: anchor.distance)

        #expect(after == before)
    }

    // MARK: - Index helpers

    @Test func indexHelpersReflectCurrentOrder() {
        var model = ChatLayoutModel()
        model.setItems([item("a", 10), item("b", 20), item("c", 30)])

        #expect(model.ids == ["a", "b", "c"])
        #expect(model.count == 3)
        #expect(model.index(of: "b") == 1)
        #expect(model.id(at: 2) == "c")
        #expect(model.index(of: "missing") == nil)
    }
}
