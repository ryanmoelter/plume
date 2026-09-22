import Foundation

/// Whether some process outside this app is still writing a session's
/// transcript.
///
/// An agent survives the app that spawned it when Plume is force-quit or its
/// bundle is replaced under a running copy, and it keeps appending to the
/// transcript afterwards. Resuming that session then puts two writers on one
/// file: the transcript is append-only with parent pointers, so they fork it
/// rather than corrupt it, and each goes on never seeing the other's turns.
///
/// The session id is no help in finding the process. An agent that minted its
/// own id carries no `--resume` in its arguments, so the only honest evidence
/// is circumstantial — a `claude` process this app did not spawn, plus a
/// transcript that has changed recently enough to look live. Pure, so the
/// decision is testable without either.
enum OrphanedSessionDetector {
    /// How recently the transcript must have changed to read as live. Longer
    /// than a slow turn's thinking time, short enough that a finished session
    /// stops blocking its own resume.
    static let writeHorizon: TimeInterval = 90

    /// `candidatePIDs` are `claude` processes that look like Plume's own —
    /// matched on the settings path it launches them with. `ownedPIDs` are the
    /// ones this app actually spawned; anything left over outlived a previous
    /// run.
    static func isWrittenElsewhere(
        transcriptModifiedAt: Date?,
        now: Date,
        candidatePIDs: Set<pid_t>,
        ownedPIDs: Set<pid_t>
    ) -> Bool {
        guard !candidatePIDs.subtracting(ownedPIDs).isEmpty else { return false }
        guard let transcriptModifiedAt else { return false }
        return now.timeIntervalSince(transcriptModifiedAt) < writeHorizon
    }
}
