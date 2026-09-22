import SwiftUI

/// Redo and fork, in the footer of a user message.
///
/// Offered on user messages only. Redoing an assistant message is not
/// meaningful — the user turn that produced it is still in context, so the
/// model would only answer it again — and the CLI agrees: an assistant row is
/// frequently mid-tool-call, which `rewind_conversation` refuses outright with
/// `target_splits_tool_call`.
///
/// Redo is the default and rides the documented control plane, cutting the
/// conversation in place and handing its text back to the composer. Fork
/// keeps both branches live by starting a second session, which needs an
/// undocumented CLI flag — hence the secondary billing. See
/// `HeadlessCommand.Fork`.
struct MessageRedoButtons: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.messageRedoContext) private var context

    let messageID: String
    let role: ChatMessage.Role

    var body: some View {
        if let context {
            HStack(spacing: 4) {
                forkMarker(context: context)
                if role == .user, let session = session(for: context) {
                    actions(session: session, context: context)
                }
            }
        }
    }

    /// Says that the conversation forked here. Shown on any message, unlike
    /// the buttons: an abandoned branch can hang off an assistant row too.
    @ViewBuilder
    private func forkMarker(context: MessageRedoContext) -> some View {
        if let abandoned = context.abandonedCountByMessageID[messageID], abandoned > 0 {
            Label {
                Text(abandoned == 1 ? "1 message" : "\(abandoned) messages")
            } icon: {
                Image(systemName: "arrow.triangle.branch")
            }
            .font(.system(size: 11))
            .emphasis(.subtle)
            .help("The conversation forked here. This branch continued; the other was left behind.")
            .plumeID(AccessibilityID.messageForkMarker, label: messageID)
        }
    }

    private func actions(session: HeadlessSession, context: MessageRedoContext) -> some View {
        Group {
            Button { redo(session: session, context: context) } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("Redo this message — cuts the conversation back to here and puts the text back in the composer")
            // The closure, so a driver runs the action rather than aiming a
            // synthetic click at a 13pt glyph inside a hosted row.
            .plumeID(
                AccessibilityID.messageRedoButton,
                label: messageID,
                invoke: { redo(session: session, context: context) }
            )

            Button { fork(context: context) } label: {
                Image(systemName: "arrow.triangle.branch")
            }
            .help("Fork to a new tab from this message, leaving this conversation as it is")
            // A fork cuts at the target's parent, so the first message of a
            // conversation has nothing to cut after. Disabled rather than
            // left to do nothing when pressed, as is a tab with no session id
            // to resume or no directory to spawn in.
            .disabled(!context.canFork || context.parentByMessageID[messageID] == nil)
            .plumeID(
                AccessibilityID.messageForkButton,
                label: messageID,
                invoke: { fork(context: context) }
            )
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .emphasis(.subtle)
    }

    private func session(for context: MessageRedoContext) -> HeadlessSession? {
        AgentSessionManager.shared.existingSession(for: context.tabID) as? HeadlessSession
    }

    private func redo(session: HeadlessSession, context: MessageRedoContext) {
        session.rewindConversation(
            to: messageID,
            lastSeenMessageID: context.lastSeenUserMessageID
        )
    }

    private func fork(context: MessageRedoContext) {
        guard let parent = context.parentByMessageID[messageID] else { return }
        context.onFork(parent)
    }
}
