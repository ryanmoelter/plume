import Foundation

/// Whether an agent tab should resume its prior `claude` session right now.
///
/// Pure so the decision is testable without a live `SurfaceManager` session.
enum AgentAutoResume {
    static func shouldResume(
        agentSessionID: String?,
        workingDirectoryPath: String?,
        hasExistingSurfaceSession: Bool,
        directoryExists: (String) -> Bool
    ) -> Bool {
        guard let agentSessionID, !agentSessionID.isEmpty else { return false }
        guard !hasExistingSurfaceSession else { return false }
        guard let workingDirectoryPath, directoryExists(workingDirectoryPath) else { return false }
        return true
    }
}
