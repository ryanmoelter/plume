import Foundation
import Observation

/// The conversation a forked tab inherits, shown until the fork writes its own.
///
/// `claude --fork-session` copies the resumed history into the new session's
/// transcript, but writes nothing at all until the first turn produces
/// content. A forked tab would otherwise open on the new-conversation screen,
/// having lost the history it was forked from until the user says something.
///
/// The messages are the original tab's own, cut at the fork point, so this
/// stands in for a file that is about to say the same thing — the same job
/// `OptimisticFirstMessage` does for a first message in flight. Held in memory
/// only: it is derivable from the transcript it came from, and the fork's
/// transcript replaces it within one turn.
@MainActor
@Observable
final class InheritedForkHistory {
    static let shared = InheritedForkHistory()

    private var messagesByTab: [UUID: [ChatMessage]] = [:]

    func messages(forTab tabID: UUID) -> [ChatMessage] {
        messagesByTab[tabID] ?? []
    }

    /// `cutAfter` is the last message the fork keeps — the same uuid passed to
    /// `--resume-session-at`, so the two cannot disagree about where the
    /// conversation was cut.
    func adopt(from transcript: Transcript, cutAfter: String, tabID: UUID) {
        guard let cut = transcript.messages.firstIndex(where: { $0.id == cutAfter }) else { return }
        messagesByTab[tabID] = Array(transcript.messages[...cut])
    }

    /// Drops the inherited copy once the fork's own transcript carries the
    /// history, which is what keeps it from being rendered twice.
    ///
    /// Matched on the ids the CLI preserves verbatim through a fork rather
    /// than on message count: the fork's first read can land before the whole
    /// prefix is flushed, and dropping then would blank the conversation.
    func settleIfCarried(by transcript: [ChatMessage], tabID: UUID) {
        guard let inherited = messagesByTab[tabID], let last = inherited.last else { return }
        guard transcript.contains(where: { $0.id == last.id }) else { return }
        messagesByTab.removeValue(forKey: tabID)
    }

    func forget(tabID: UUID) {
        messagesByTab.removeValue(forKey: tabID)
    }
}
