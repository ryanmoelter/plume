import SwiftUI

/// Finds the subagent a chat's `Agent` call spawned, and opens its transcript.
///
/// Nil in the environment where nothing can open one, as inside a subagent's
/// own transcript, and the call then renders as a plain tool row.
struct ChatSubagentOpener {
    let tabID: UUID
    let subagents: () -> [SubagentTranscript]
    let open: (SubagentTranscript) -> Void

    /// Reads the store's observable state, so a row calling this from `body`
    /// redraws as the subagent's status changes.
    func subagent(forToolUseID toolUseID: String) -> SubagentTranscript? {
        Self.subagent(forToolUseID: toolUseID, in: subagents())
    }

    nonisolated static func subagent(forToolUseID toolUseID: String, in subagents: [SubagentTranscript]) -> SubagentTranscript? {
        subagents.first { $0.descriptor?.toolUseID == toolUseID }
    }

    /// Both names have been used for the subagent-spawning tool.
    nonisolated static let spawnToolNames: Set<String> = ["Agent", "Task"]
}

extension EnvironmentValues {
    @Entry var chatSubagentOpener: ChatSubagentOpener?
}
