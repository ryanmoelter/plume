import Foundation

/// Whether an agent tab should resume its prior `claude` session right now.
///
/// Pure so the decision is testable without a live `SurfaceManager` session.
enum AgentAutoResume {
    /// `isSessionWrittenElsewhere` reports that some other process is still
    /// appending to this session's transcript — an agent orphaned by a crash
    /// or an upgrade, which outlives the app that spawned it. Resuming on top
    /// of one puts two writers on a single transcript, where they fork it and
    /// each goes on unaware of the other's turns.
    static func shouldResume(
        agentSessionID: String?,
        workingDirectoryPath: String?,
        hasExistingSurfaceSession: Bool,
        isSessionWrittenElsewhere: Bool = false,
        directoryExists: (String) -> Bool
    ) -> Bool {
        guard let agentSessionID, !agentSessionID.isEmpty else { return false }
        guard !hasExistingSurfaceSession else { return false }
        guard !isSessionWrittenElsewhere else { return false }
        guard let workingDirectoryPath, directoryExists(workingDirectoryPath) else { return false }
        return true
    }
}
