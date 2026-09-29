import AppKit
import Testing
@testable import Plume

/// A working indicator that departs fades its host to zero alpha before the
/// host returns to the pool. The piece that dequeues it next must draw.
@MainActor
struct ChatListHostPoolTests {
    @Test func aHostFreedByADepartingWorkingIndicatorDrawsWhenReused() async throws {
        let controller = ChatListController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = controller.scrollView
        defer {
            controller.tearDown()
            window.close()
        }

        let first = paragraph("m/0", "First paragraph.")
        let working = ChatPiece(id: "m/working", messageID: "m", role: .assistant, content: .working, wash: .none)
        controller.update(ChatListInputs(pieces: [first, working]))
        controller.documentView.layoutSubtreeIfNeeded()
        #expect(visibleHosts(in: controller).count == 2)

        controller.update(ChatListInputs(pieces: [first]))
        try await waitUntil { visibleHosts(in: controller).count == 1 }

        controller.update(ChatListInputs(pieces: [first, paragraph("m/1", "Second paragraph.")]))
        controller.documentView.layoutSubtreeIfNeeded()
        let hosts = visibleHosts(in: controller)
        #expect(hosts.count == 2)
        #expect(hosts.allSatisfy { $0.alphaValue == 1 })
    }

    /// PLUME-204: the reader scrolling away mid-departure evicts the
    /// indicator's host, and it must not come back when they scroll down.
    @Test func aWorkingIndicatorEvictedMidDepartureNeverReturns() async throws {
        let controller = ChatListController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = controller.scrollView
        var visible: Set<String> = []
        controller.onVisiblePieceIDs = { visible = $0 }
        defer {
            controller.tearDown()
            window.close()
        }

        let reply = (0..<60).map { paragraph("m/\($0)", "Paragraph \($0) of a reply long enough to scroll.") }
        let working = ChatPiece(id: "m/working", messageID: "m", role: .assistant, content: .working, wash: .none)
        controller.update(ChatListInputs(pieces: reply + [working]))
        controller.documentView.layoutSubtreeIfNeeded()
        try await waitUntil { visible.contains(working.id) }

        controller.update(ChatListInputs(pieces: reply))
        let clip = controller.scrollView.contentView
        clip.scroll(to: .zero)
        controller.scrollView.reflectScrolledClipView(clip)
        controller.documentView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))

        controller.scroll(to: .bottom, animated: false)
        controller.documentView.layoutSubtreeIfNeeded()
        try await waitUntil { visible.contains(reply[reply.count - 1].id) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(visible.contains(working.id) == false)
    }

    @Test func aWorkingIndicatorDepartingFromACrowdedWindowNeverReturns() async throws {
        let controller = ChatListController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 1400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = controller.scrollView
        var visible: Set<String> = []
        controller.onVisiblePieceIDs = { visible = $0 }
        defer {
            controller.tearDown()
            window.close()
        }

        let reply = (0..<400).map { paragraph("m/\($0)", "\($0)") }
        let working = ChatPiece(id: "m/working", messageID: "m", role: .assistant, content: .working, wash: .none)
        controller.update(ChatListInputs(pieces: reply + [working]))
        controller.documentView.layoutSubtreeIfNeeded()
        try await waitUntil { visible.contains(working.id) }

        controller.update(ChatListInputs(pieces: reply))
        controller.documentView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        controller.documentView.needsLayout = true
        controller.documentView.layoutSubtreeIfNeeded()
        #expect(visible.contains(working.id) == false)
    }

    private func paragraph(_ id: String, _ text: String) -> ChatPiece {
        ChatPiece(id: id, messageID: "m", role: .assistant, content: .markdown(.paragraph(text), index: 0), wash: .none)
    }

    private func visibleHosts(in controller: ChatListController) -> [NSView] {
        controller.documentView.subviews.filter { !$0.isHidden }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            try #require(Date() < deadline, "The working indicator never finished departing")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
