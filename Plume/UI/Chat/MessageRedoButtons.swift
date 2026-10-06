import SwiftUI

/// Rollback and fork, in the footer of a reply.
///
/// Both act on the point just after the reply: rollback cuts the conversation
/// there in place, and fork opens the conversation up to there in a new tab.
/// The cut is the user message that followed the reply (see
/// `MessageRedoContext.rollbackTargets(in:)`), so the newest reply offers
/// neither.
///
/// Rollback rides the documented control plane and hands the cut message's
/// text back to the composer. Fork keeps both branches live by starting a
/// second session, which needs an undocumented CLI flag. See
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
                // Debug-only until rollback and forking are ready to ship.
                #if DEBUG
                if role == .assistant,
                   let target = context.rollbackTargetByReplyID[messageID],
                   context.transcriptMessageIDs.contains(target),
                   let session = session(for: context) {
                    actions(target: target, session: session, context: context)
                }
                #endif
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

    private func actions(target: String, session: HeadlessSession, context: MessageRedoContext) -> some View {
        Group {
            Button { rollBack(to: target, session: session, context: context) } label: {
                FooterGlyph(symbol: "arrow.uturn.backward")
            }
            .help("Roll back to here — removes everything after this reply and puts your next message back in the composer")
            // The closure, so a driver runs the action rather than aiming a
            // synthetic click at a small glyph inside a hosted row.
            .plumeID(
                AccessibilityID.messageRollbackButton,
                label: messageID,
                invoke: { rollBack(to: target, session: session, context: context) }
            )

            Button { fork(from: target, context: context) } label: {
                FooterGlyph(symbol: "arrow.triangle.branch")
            }
            .help("Fork to a new tab from here, leaving this conversation as it is")
            // Disabled rather than left to do nothing when pressed, for a tab
            // with no session id to resume or no directory to spawn in.
            .disabled(!context.canFork || context.parentByMessageID[target] == nil)
            .plumeID(
                AccessibilityID.messageForkButton,
                label: messageID,
                invoke: { fork(from: target, context: context) }
            )
        }
        .buttonStyle(.plain)
    }

    private func session(for context: MessageRedoContext) -> HeadlessSession? {
        AgentSessionManager.shared.existingSession(for: context.tabID) as? HeadlessSession
    }

    private func rollBack(to target: String, session: HeadlessSession, context: MessageRedoContext) {
        session.rewindConversation(
            to: target,
            lastSeenMessageID: context.lastSeenUserMessageID
        )
    }

    /// Cuts at the target's parent: the target is the message being dropped.
    private func fork(from target: String, context: MessageRedoContext) {
        guard let parent = context.parentByMessageID[target] else { return }
        context.onFork(parent)
    }
}

/// A footer action's glyph, in the same hover circle as the copy button
/// beside it.
private struct FooterGlyph: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.isEnabled) private var isEnabled

    let symbol: String
    @State private var isHovered = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .emphasis(isHovered && isEnabled ? .primary : .subtle)
            .frame(width: Self.diameter, height: Self.diameter)
            .background(isHovered && isEnabled ? colors.surface(.backgroundTint) : .clear, in: .circle)
            .contentShape(.circle)
            .plumeHover { isHovered = $0 }
    }

    private static let diameter: CGFloat = 22
}
