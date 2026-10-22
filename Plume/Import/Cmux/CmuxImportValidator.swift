import Foundation

/// `ImportValidator` configured for cmux: a lost transcript refuses the row,
/// and a Codex tab stays an agent only while its recorded rollout still holds
/// its thread.
nonisolated enum CmuxImportValidator {
    static func validating(_ candidate: ImportCandidate) async -> ImportCandidate {
        await ImportValidator.validating(
            candidate,
            configuration: .init(missingTranscript: .reject, resolveCodexTab: resolvingCodexTab)
        )
    }

    private static func resolvingCodexTab(_ tab: ImportTabPlan) -> ImportTabPlan {
        guard let sessionID = tab.agentSessionID else { return tab }
        let valid = CmuxCodexSessions.validRollout(path: tab.sessionJSONLPath, sessionID: sessionID, cwd: tab.workingDirectoryPath)
        return ImportValidator.resolvingCodexTab(tab, hasValidRollout: valid)
    }
}
