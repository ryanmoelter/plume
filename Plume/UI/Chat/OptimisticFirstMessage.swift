import Foundation
import SwiftUI

/// The first message of a conversation, held in memory from the moment it is
/// sent until the transcript on disk contains it.
///
/// Launching an agent is fire-and-forget: `AgentLauncher` returns before the
/// process exists, and Claude Code writes nothing until the session is up. The
/// window between the two is long enough to read as the app ignoring the
/// message, so the conversation opens immediately with this standing in for
/// the line that is about to be written.
nonisolated struct OptimisticFirstMessage: Equatable {
    let text: String
    let sentAt: Date
    /// A failure that happened while this message was the only thing on
    /// screen. It belongs in the conversation rather than in a full-pane
    /// state, which would throw away the message the user just wrote.
    var failure: ChatStartFailure?

    init(text: String, sentAt: Date = Date(), failure: ChatStartFailure? = nil) {
        self.text = text
        self.sentAt = sentAt
        self.failure = failure
    }

    /// The id given to the synthesized message. Stable for the life of the
    /// pending message so the list is not asked to re-identify a row that has
    /// not changed.
    static let messageID = "plume.optimistic.first-message"

    /// Classified the way `TranscriptParser` classifies the line it is
    /// standing in for, so a `!` command renders as one here too rather than
    /// showing its wrapper tags as prose until the transcript catches up.
    private var kind: InjectedContent {
        InjectedContent.classify(text: text, isMeta: false)
    }

    var message: ChatMessage {
        ChatMessage(
            id: Self.messageID,
            role: .user,
            blocks: [kind.isUserProse ? .markdown(kind.bodyText(text)) : .injected(kind, text: text)],
            timestamp: sentAt
        )
    }

    var noticeMessage: ChatMessage? {
        guard let failure else { return nil }
        return ChatMessage(
            id: "\(Self.messageID).failure",
            role: .notice,
            blocks: [.notice(ChatNotice(
                kind: .error,
                title: failure.title,
                detail: failure.detail
            ))],
            timestamp: nil
        )
    }

    /// Whether `messages` already carries this message, which is what retires
    /// it. Compared on trimmed text because the parser reconstructs the line
    /// from the transcript's own content blocks rather than echoing what was
    /// sent, and only against user prose, so an assistant quoting the text
    /// back never counts as the line arriving.
    func isSettled(by messages: [ChatMessage]) -> Bool {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return true }
        return messages.contains { message in
            guard message.role == .user else { return false }
            return message.prose == wanted || message.injectedText == wanted
        }
    }
}

extension ChatMessage {
    /// The message's plain prose, ignoring tool calls, thinking and injected
    /// content — what a user actually typed, when a user typed it.
    var prose: String {
        blocks
            .compactMap { block in
                if case .markdown(let text) = block { return text }
                return nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ChatMessage {
    /// The text of an injected line — a `!` command among them — which
    /// carries no prose to match a pending message against.
    var injectedText: String {
        blocks
            .compactMap { block in
                if case .injected(_, let text) = block { return text }
                return nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Keeps the pending first message in step with the transcript and with a
/// failed start.
///
/// Both are state writes, so they happen on change rather than during a
/// render: writing observable state from `body` invalidates the render that
/// made the write and spins. It is one modifier rather than two `onChange`
/// calls because `ChatTabView.body`'s chain is already at the type-checker's
/// limit, and two more push it over.
struct OptimisticFirstMessageTracking: ViewModifier {
    let messages: [ChatMessage]
    let startFailure: ChatStartFailure?
    @Binding var pending: OptimisticFirstMessage?

    func body(content: Content) -> some View {
        content
            .onChange(of: messages) { _, arrived in
                guard OptimisticChatReconciler.isSettled(transcript: arrived, pending: pending) else { return }
                pending = nil
            }
            // A start that failed with a message in play keeps the
            // conversation and puts the error in it; `startFailureState` still
            // owns the case where there is nothing on screen to attach it to.
            .onChange(of: startFailure) { _, failure in
                guard pending != nil else { return }
                pending?.failure = failure
            }
    }
}

/// What the chat should render while a first message is in flight.
///
/// One rule decides it, and it is what makes a double render impossible: the
/// pending message is dropped the instant the real transcript contains it, and
/// the two are never concatenated without that check. A transcript that has
/// not caught up yet renders its own messages plus the pending one; the moment
/// the line lands, the pending copy is gone and only the transcript's is left.
nonisolated enum OptimisticChatReconciler {
    static func messages(
        transcript: [ChatMessage],
        pending: OptimisticFirstMessage?
    ) -> [ChatMessage] {
        guard let pending else { return transcript }
        guard !pending.isSettled(by: transcript) else { return transcript }
        return transcript + [pending.message] + (pending.noticeMessage.map { [$0] } ?? [])
    }

    /// Whether the pending message has been absorbed and can be released.
    /// A failed start keeps it: there is no transcript coming, and dropping it
    /// would clear the conversation out from under the error explaining it.
    static func isSettled(
        transcript: [ChatMessage],
        pending: OptimisticFirstMessage?
    ) -> Bool {
        guard let pending else { return false }
        guard pending.failure == nil else { return false }
        return pending.isSettled(by: transcript)
    }
}
