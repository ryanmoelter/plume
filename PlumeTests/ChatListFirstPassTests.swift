import AppKit
import Testing
@testable import Plume

/// A remounted chat opens at the bottom, so its first pass builds the rows
/// there and none at the top, where the scroll view starts.
@MainActor
struct ChatListFirstPassTests {
    @Test func theFirstPassBuildsOnlyRowsNearTheBottom() throws {
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
        let tabID = UUID()
        // A remounted chat builds its pieces after its list exists.
        controller.update(ChatListInputs(tabID: tabID))
        layOut(controller)
        let before = controller.realizations

        controller.update(ChatListInputs(pieces: (0..<300).map(piece), tabID: tabID))
        layOut(controller)

        #expect(controller.scrollView.contentView.bounds.minY > 0)
        #expect(controller.realizedIDs.contains("m/299"))
        #expect(!controller.realizedIDs.contains("m/0"))
        #expect(controller.realizations - before == controller.realizedIDs.count - 1)
    }

    /// These kinds estimate at least their measured height, so building the
    /// rows at the bottom never grows the document under the first pass.
    private func piece(_ index: Int) -> ChatPiece {
        let block: MarkdownBlock = switch index % 3 {
        case 0: .codeBlock(language: nil, code: "let x = 1")
        case 1: .heading(level: 2, text: "H")
        default: .codeBlock(language: nil, code: "a\nb\nc\nd")
        }
        return ChatPiece(id: "m/\(index)", messageID: "m", role: .assistant, content: .markdown(block, index: index), wash: .none)
    }

    /// An offscreen window runs no layout of its own.
    private func layOut(_ controller: ChatListController) {
        controller.documentView.needsLayout = true
        controller.documentView.layoutSubtreeIfNeeded()
    }
}
