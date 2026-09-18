import Foundation

/// Fills in what a candidate cannot know without asking git and the
/// filesystem: how its folder relates to a repository, and where each agent
/// session's transcript actually is.
///
/// Separate from `CmuxCandidateBuilder` so the sheet draws its rows before any
/// subprocess runs.
nonisolated enum CmuxImportValidator {
    static func validating(_ candidate: ImportCandidate) async -> ImportCandidate {
        var validated = candidate
        guard candidate.rejection == nil else { return validated }

        let directory = candidate.workingDirectoryPath
        guard FileManager.default.fileExists(atPath: directory) else {
            validated.rejection = .directoryMissing(directory)
            return validated
        }

        validated.workspace = await workspacePlan(
            directory: directory,
            branch: candidate.workspace.branchName
        )
        validated.tabs = resolvingTranscripts(candidate.tabs, fallbackDirectory: directory)

        if let unresolved = validated.tabs.first(where: {
            $0.kind == .agent && $0.sessionJSONLPath == nil
        }) {
            validated.rejection = .unresolvableSession(unresolved.agentSessionID ?? "")
        }
        return validated
    }

    /// One `checkoutFacts` call answers both questions: a worktree reports a
    /// checkout root that differs from the project it belongs to.
    private static func workspacePlan(directory: String, branch: String?) async -> ImportWorkspacePlan {
        guard let facts = await GitService.shared.checkoutFacts(containing: directory) else {
            return ImportWorkspacePlan(kind: .directory, isValidated: true)
        }
        let isWorktree = standardized(facts.checkoutRoot) != standardized(facts.projectRoot)
        return ImportWorkspacePlan(
            kind: isWorktree ? .worktree : .directory,
            repoPath: facts.projectRoot,
            branchName: isWorktree ? branch : nil,
            isValidated: true
        )
    }

    /// cmux records a transcript path, but it can name a file that has since
    /// been deleted or moved between project directories.
    private static func resolvingTranscripts(
        _ tabs: [ImportTabPlan],
        fallbackDirectory: String
    ) -> [ImportTabPlan] {
        tabs.map { tab in
            guard tab.kind == .agent, let sessionID = tab.agentSessionID else { return tab }
            let directory = tab.workingDirectoryPath ?? fallbackDirectory
            guard let path = transcriptPath(sessionID: sessionID, directory: directory, recorded: tab.sessionJSONLPath)
            else { return tab }

            return ImportTabPlan(
                kind: tab.kind,
                title: tab.title,
                workingDirectoryPath: tab.workingDirectoryPath,
                agentSessionID: tab.agentSessionID,
                sessionJSONLPath: path,
                permissionMode: tab.permissionMode
            )
        }
    }

    private static func transcriptPath(sessionID: String, directory: String, recorded: String?) -> String? {
        if let recorded, SessionJSONLReader.hasContent(atPath: recorded) { return recorded }
        let resolved = SessionJSONLReader.resolvedTranscriptPath(
            workingDirectory: directory,
            sessionID: sessionID
        )
        return SessionJSONLReader.hasContent(atPath: resolved) ? resolved : nil
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
