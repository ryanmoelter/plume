@testable import Plume

/// The launch arguments most tests don't care about, defaulted away.
extension AgentProvider {
    func launchCommand(firstMessage: String?, resumeSessionID: String?) -> AgentLaunch {
        launchCommand(
            firstMessage: firstMessage,
            resumeSessionID: resumeSessionID,
            taskID: nil,
            tabID: nil,
            permissionMode: nil
        )
    }
}
