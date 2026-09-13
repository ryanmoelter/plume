import SwiftUI

/// The custom chat list, bridged into SwiftUI.
///
/// `ChatMessageList` still builds the pieces; this only draws them. See
/// `ChatListController` for what happens on the AppKit side and
/// `docs/chat-list.md` for why this exists beside the lazy stack.
struct ChatListView: NSViewRepresentable {
    var inputs: ChatListInputs
    var revealClock: RevealClock
    var commands: ChatListCommands
    var onOpenSubagent: (SubagentTranscript) -> Void = { _ in }
    var onVisiblePieceIDs: (Set<String>) -> Void = { _ in }
    var onDetachedChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> ChatListController {
        ChatListController()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let controller = context.coordinator
        commands.controller = controller
        apply(to: controller)
        return controller.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        apply(to: context.coordinator)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: ChatListController) {
        coordinator.tearDown()
    }

    private func apply(to controller: ChatListController) {
        // Callbacks first, unconditionally: they capture state the value
        // comparison below cannot see.
        controller.onOpenSubagent = onOpenSubagent
        controller.onVisiblePieceIDs = onVisiblePieceIDs
        controller.onDetachedChange = onDetachedChange
        controller.revealClock = revealClock
        if controller.inputs != inputs {
            controller.update(inputs)
        }
    }
}
