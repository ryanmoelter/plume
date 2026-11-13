import AppKit
import Testing
@testable import Plume

/// Paging scrolls the list by a viewport less its insets, stops following the
/// bottom while the reader is above it, and follows again on landing there.
@MainActor
struct ChatListPagingTests {
    private let tabID = UUID()

    @Test func pagingUpMovesTheListAndStopsFollowing() throws {
        let (controller, window) = makeList()
        defer { close(controller, window) }

        controller.scrollPage(up: true)
        controller.finishAnimations()
        layOut(controller)

        let moved = bottom(of: controller) - offset(of: controller)
        #expect(moved > 300)
        #expect(moved < controller.scrollView.contentView.bounds.height)
        guard case .anchor = controller.readingPosition else {
            Issue.record("Paged up, the reader should be anchored, not \(controller.readingPosition)")
            return
        }
    }

    @Test func pagingPastTheBottomClampsAndFollowsAgain() throws {
        let (controller, window) = makeList()
        defer { close(controller, window) }
        controller.scrollPage(up: true)
        controller.finishAnimations()
        layOut(controller)

        controller.scrollPage(up: false)
        controller.scrollPage(up: false)
        controller.finishAnimations()
        layOut(controller)

        #expect(offset(of: controller) == bottom(of: controller))
        #expect(controller.readingPosition == .bottom)
    }

    @Test func pagingUpFromTheTopClampsAtZero() throws {
        let (controller, window) = makeList()
        defer { close(controller, window) }
        controller.scroll(to: .offset(-500), animated: false)
        layOut(controller)

        #expect(offset(of: controller) == 0)
        controller.scrollPage(up: true)
        controller.finishAnimations()
        layOut(controller)
        #expect(offset(of: controller) == 0)
    }

    private func makeList() -> (ChatListController, NSWindow) {
        let controller = ChatListController()
        controller.readingPositions = ChatReadingPositions()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = controller.scrollView
        controller.update(ChatListInputs(pieces: pieces(count: 80), tabID: tabID))
        layOut(controller)
        return (controller, window)
    }

    private func close(_ controller: ChatListController, _ window: NSWindow) {
        controller.tearDown()
        window.close()
    }

    private func pieces(count: Int) -> [ChatPiece] {
        (0..<count).map { index in
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

    private func layOut(_ controller: ChatListController) {
        for _ in 0..<2 {
            controller.documentView.needsLayout = true
            controller.documentView.layoutSubtreeIfNeeded()
        }
    }
}
