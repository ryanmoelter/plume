import AppKit
import Testing
@testable import Plume

/// A chat that comes back on screen opens where the reader left it: at the
/// bottom if they were following it, or on the same rows if they had
/// scrolled up. Covers the list mounting on estimates, the composer's room
/// arriving after mount, and bounds changes the reader did not make.
@MainActor
struct ChatListReadingPositionTests {
    private let tabID = UUID()

    @Test func aChatMountedOnEstimatesLandsAtTheBottom() throws {
        let (controller, window) = makeList()
        defer { close(controller, window) }

        controller.update(ChatListInputs(pieces: underestimatedPieces(count: 80), tabID: tabID))
        // One pass: the one it asks for from inside layout may never come.
        controller.layoutPass()

        let lastRow = try #require(controller.documentView.subviews.filter { !$0.isHidden }.map(\.frame.maxY).max())
        #expect(lastRow <= offset(of: controller) + controller.scrollView.contentView.bounds.height)
        #expect(offset(of: controller) == bottom(of: controller))
    }

    /// Moving the list into a window posts a bounds change with the offset
    /// unchanged, after content may have grown under it.
    @Test func aBoundsChangeThatLeavesTheOffsetIsNotTheReaders() throws {
        let (controller, window) = makeList()
        defer { close(controller, window) }
        let pieces = underestimatedPieces(count: 80)
        controller.update(ChatListInputs(pieces: pieces, tabID: tabID))
        layOut(controller)

        controller.update(ChatListInputs(pieces: pieces + underestimatedPieces(count: 5, from: 80), tabID: tabID))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: controller.scrollView.contentView)
        layOut(controller)

        #expect(controller.readingPosition == .bottom)
        #expect(offset(of: controller) == bottom(of: controller))
    }

    @Test func aReaderAtTheBottomReturnsToTheBottom() throws {
        let positions = ChatReadingPositions()
        let pieces = underestimatedPieces(count: 80)
        do {
            let (controller, window) = makeList(positions: positions)
            controller.update(ChatListInputs(pieces: pieces, tabID: tabID))
            layOut(controller)
            close(controller, window)
        }
        #expect(positions[tabID] == .bottom)

        let (controller, window) = makeList(positions: positions)
        defer { close(controller, window) }
        controller.update(ChatListInputs(tabID: tabID))
        controller.update(ChatListInputs(pieces: pieces + underestimatedPieces(count: 5, from: 80), tabID: tabID))
        layOut(controller)

        #expect(offset(of: controller) == bottom(of: controller))
    }

    @Test func aScrolledUpReaderReturnsToTheSameRows() throws {
        let positions = ChatReadingPositions()
        let pieces = underestimatedPieces(count: 80)
        let left: CGFloat
        let position: ChatReadingPosition
        do {
            let (controller, window) = makeList(positions: positions)
            controller.update(ChatListInputs(pieces: pieces, tabID: tabID))
            layOut(controller)
            readerScroll(controller, to: 2000)
            layOut(controller)
            left = offset(of: controller)
            position = controller.readingPosition
            close(controller, window)
        }
        guard case .anchor = position else {
            Issue.record("Scrolled up, the reader should be anchored, not \(position)")
            return
        }
        #expect(positions[tabID] == position)

        let (controller, window) = makeList(positions: positions)
        defer { close(controller, window) }
        // A remounted chat builds its pieces after its list exists.
        controller.update(ChatListInputs(tabID: tabID))
        layOut(controller)
        controller.update(ChatListInputs(pieces: pieces, tabID: tabID))
        layOut(controller)

        #expect(controller.readingPosition == position)
        #expect(abs(offset(of: controller) - left) < 1)
    }

    /// The composer's height reaches the list a render after it mounts, and
    /// eases in.
    @Test func theComposerRoomArrivingAfterMountKeepsTheBottom() throws {
        let (controller, window) = makeList()
        defer { close(controller, window) }
        let pieces = underestimatedPieces(count: 80)
        controller.update(ChatListInputs(pieces: pieces, tabID: tabID))
        layOut(controller)

        controller.update(ChatListInputs(pieces: pieces, tabID: tabID, trailingInset: 220))
        layOut(controller)
        controller.finishAnimations()
        layOut(controller)

        #expect(controller.readingPosition == .bottom)
        #expect(offset(of: controller) == bottom(of: controller))
    }

    @Test func theComposerRoomArrivingAfterMountLeavesARestoredReaderInPlace() throws {
        let positions = ChatReadingPositions()
        let pieces = underestimatedPieces(count: 80)
        let left: CGFloat
        do {
            let (controller, window) = makeList(positions: positions)
            controller.update(ChatListInputs(pieces: pieces, tabID: tabID, trailingInset: 220))
            layOut(controller)
            readerScroll(controller, to: 2000)
            layOut(controller)
            left = offset(of: controller)
            close(controller, window)
        }

        let (controller, window) = makeList(positions: positions)
        defer { close(controller, window) }
        controller.update(ChatListInputs(pieces: pieces, tabID: tabID))
        layOut(controller)
        controller.update(ChatListInputs(pieces: pieces, tabID: tabID, trailingInset: 220))
        layOut(controller)
        controller.finishAnimations()
        layOut(controller)

        #expect(abs(offset(of: controller) - left) < 1)
    }

    @Test func switchingTabsOnOneListKeepsEachTabsPosition() throws {
        let positions = ChatReadingPositions()
        let (controller, window) = makeList(positions: positions)
        defer { close(controller, window) }
        let other = UUID()
        let pieces = underestimatedPieces(count: 80)
        controller.update(ChatListInputs(pieces: pieces, tabID: tabID))
        layOut(controller)
        readerScroll(controller, to: 2000)
        layOut(controller)
        let left = offset(of: controller)

        controller.update(ChatListInputs(pieces: pieces, tabID: other))
        layOut(controller)
        #expect(offset(of: controller) == bottom(of: controller))

        controller.update(ChatListInputs(pieces: pieces, tabID: tabID))
        layOut(controller)
        #expect(abs(offset(of: controller) - left) < 1)
        #expect(positions[other] == .bottom)
    }

    // MARK: - Helpers

    private func makeList(positions: ChatReadingPositions? = nil) -> (ChatListController, NSWindow) {
        let controller = ChatListController()
        controller.readingPositions = positions ?? ChatReadingPositions()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = controller.scrollView
        return (controller, window)
    }

    private func close(_ controller: ChatListController, _ window: NSWindow) {
        controller.tearDown()
        window.close()
    }

    /// Headings estimate at one line, so a long one measures several times
    /// its estimate and every first realization grows the document.
    private func underestimatedPieces(count: Int, from start: Int = 0) -> [ChatPiece] {
        (start..<start + count).map { index in
            let text = "Heading \(index) " + String(repeating: "long enough to wrap several times ", count: 6)
            return ChatPiece(
                id: "m/\(index)",
                messageID: "m",
                role: .assistant,
                content: .markdown(.heading(level: 2, text: text), index: index),
                wash: .none
            )
        }
    }

    private func offset(of controller: ChatListController) -> CGFloat {
        controller.scrollView.contentView.bounds.origin.y
    }

    private func bottom(of controller: ChatListController) -> CGFloat {
        let clip = controller.scrollView.contentView
        return max(0, controller.documentView.frame.height - clip.bounds.height)
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
