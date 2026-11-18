import AppKit
import Testing
@testable import Plume

/// A row whose height moves by less than a point snaps to it, including a row
/// realized again at a fraction of a point off its last measurement, whose
/// container then matches the list's height for it. A row already easing is
/// re-targeted instead, so the ease ends at the new height.
@MainActor
struct ChatListHeightSnapTests {
    private let rowID = "m/0"

    @Test func aRowRealizedAgainUnderAPointOffSnaps() throws {
        let (controller, window) = makeList()
        defer { close(controller, window) }
        try #require(controller.realizedIDs.contains(rowID))
        let measured = controller.displayHeight(of: rowID)

        controller.reportMeasurement(measured + 0.5, for: rowID)
        layOut(controller)
        try #require(controller.displayHeight(of: rowID) == measured + 0.5)
        #expect(controller.heightEase(of: rowID) == nil)

        controller.scroll(to: .bottom, animated: false)
        layOut(controller)
        try #require(!controller.realizedIDs.contains(rowID))
        try #require(controller.displayHeight(of: rowID) == measured + 0.5)

        readerScroll(controller, to: 0)
        layOut(controller)
        try #require(controller.realizedIDs.contains(rowID))
        #expect(controller.heightEase(of: rowID) == nil)
        #expect(controller.displayHeight(of: rowID) == measured)
        #expect(controller.containerHeight(of: rowID) == controller.displayHeight(of: rowID))
    }

    @Test func aRowAlreadyEasingIsRetargetedByAChangeUnderAPoint() throws {
        let (controller, window) = makeList()
        defer { close(controller, window) }
        try #require(controller.realizedIDs.contains(rowID))
        let measured = controller.displayHeight(of: rowID)

        controller.reportMeasurement(measured + 40, for: rowID)
        layOut(controller)
        try #require(controller.heightEase(of: rowID) != nil)
        let current = controller.displayHeight(of: rowID)

        controller.reportMeasurement(current + 0.5, for: rowID)
        layOut(controller)
        #expect(controller.heightEase(of: rowID)?.to == current + 0.5)
        #expect(controller.displayHeight(of: rowID) == current)
    }

    /// Scrolled to the top, with enough rows below that the bottom is out of
    /// the realized window.
    private func makeList() -> (ChatListController, NSWindow) {
        let controller = ChatListController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = controller.scrollView
        let pieces = (0..<200).map { index in
            ChatPiece(
                id: "m/\(index)", messageID: "m", role: .assistant,
                content: .markdown(.paragraph("Paragraph \(index) of a reply long enough to scroll."), index: index),
                wash: .none
            )
        }
        controller.update(ChatListInputs(pieces: pieces))
        layOut(controller)
        readerScroll(controller, to: 0)
        layOut(controller)
        controller.finishAnimations()
        layOut(controller)
        return (controller, window)
    }

    private func close(_ controller: ChatListController, _ window: NSWindow) {
        controller.tearDown()
        window.close()
    }

    private func readerScroll(_ controller: ChatListController, to y: CGFloat) {
        let clip = controller.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: y))
        controller.scrollView.reflectScrolledClipView(clip)
    }

    /// An offscreen window runs no layout of its own.
    private func layOut(_ controller: ChatListController) {
        for _ in 0..<2 {
            controller.documentView.needsLayout = true
            controller.documentView.layoutSubtreeIfNeeded()
        }
    }
}
