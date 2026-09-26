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
