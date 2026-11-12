import SwiftUI

/// The custom chat list, bridged into SwiftUI.
///
/// `ChatMessageList` still builds the pieces; this only draws them. See
/// `ChatListController` for what happens on the AppKit side and
/// `docs/chat-list.md` for why this exists beside the lazy stack.
struct ChatListView: NSViewRepresentable {
    var inputs: ChatListInputs
    var revealModel: ChatRevealModel?
    var paneFocus: PaneFocusState?
    var commands: ChatListCommands
    /// Where a list with no tab opens; a tab's list reopens where it was left.
    var initialPosition: ChatReadingPosition = .bottom
    /// Passed beside `inputs` rather than within it: it carries a closure, so
    /// it cannot be compared. The controller restages rows itself when what
    /// they draw from it changes.
    var redoContext: MessageRedoContext?
    var onOpenPlan: (() -> Void)?
    var onToggleAgentMessage: (String) -> Void = { _ in }
    var onVisiblePieceIDs: (Set<String>) -> Void = { _ in }
    var onDetachedChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> ChatListController {
        ChatListController()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let controller = context.coordinator
        commands.controller = controller
        controller.open(at: initialPosition)
        apply(to: controller)
        controller.subagentOpener = context.environment.chatSubagentOpener
        controller.proposalBoard = context.environment.chatProposalBoard
        return controller.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        apply(to: context.coordinator)
        context.coordinator.subagentOpener = context.environment.chatSubagentOpener
        context.coordinator.proposalBoard = context.environment.chatProposalBoard
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: ChatListController) {
        coordinator.tearDown()
    }

    private func apply(to controller: ChatListController) {
        // Callbacks first, unconditionally: they capture state the value
        // comparison below cannot see.
        controller.onOpenPlan = onOpenPlan
        controller.onToggleAgentMessage = onToggleAgentMessage
        controller.onVisiblePieceIDs = onVisiblePieceIDs
        controller.onDetachedChange = onDetachedChange
        controller.revealModel = revealModel
        controller.paneFocus = paneFocus
        controller.redoContext = redoContext
        if controller.inputs != inputs {
            controller.update(inputs)
        }
    }
}
