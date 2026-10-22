import Foundation

/// Fills in what a candidate cannot know without asking git and the
/// filesystem: how its folder relates to a repository, and where each agent
/// session's transcript actually is.
///
/// Separate from the candidate builders so the sheet draws its rows before any
/// subprocess runs.
nonisolated enum ImportValidator {
    /// What to do with a Claude agent tab whose transcript cannot be found.
    enum MissingTranscriptPolicy: Sendable {
        /// The whole row is refused as `.unresolvableSession`.
        case reject
        /// The tab survives as a plain terminal with no session.
        case downgradeToTerminal
    }

    struct Configuration: Sendable {
        var missingTranscript: MissingTranscriptPolicy
        /// Decides a Codex tab's fate. Nil leaves Codex tabs untouched.
        var resolveCodexTab: (@Sendable (ImportTabPlan) -> ImportTabPlan)?
        /// For a source that records no branch: a worktree takes its checkout's
        /// current branch.
        var readsBranchFromGit: Bool = false
    }

    static func validating(_ candidate: ImportCandidate, configuration: Configuration) async -> ImportCandidate {
        var validated = candidate
        guard candidate.rejection == nil else { return validated }

        let directory = candidate.workingDirectoryPath
        guard FileManager.default.fileExists(atPath: directory) else {
            validated.rejection = .directoryMissing(directory)
            return validated
        }

        validated.workspace = await workspacePlan(directory: directory, branch: candidate.workspace.branchName, configuration: configuration)
        validated.tabs = resolvingTranscripts(candidate.tabs, fallbackDirectory: directory, configuration: configuration)

        if let unresolved = validated.tabs.first(where: {
            $0.kind == .agent && $0.provider == .claudeCode && $0.sessionJSONLPath == nil
        }) {
            validated.rejection = .unresolvableSession(unresolved.agentSessionID ?? "")
        }
        return validated
    }

    /// One `checkoutFacts` call answers both questions: a worktree reports a
    /// checkout root that differs from the project it belongs to.
    private static func workspacePlan(
        directory: String,
        branch: String?,
        configuration: Configuration
    ) async -> ImportWorkspacePlan {
        guard let facts = await GitService.shared.checkoutFacts(containing: directory) else {
            return ImportWorkspacePlan(kind: .directory, isValidated: true)
        }
        let isWorktree = standardized(facts.checkoutRoot) != standardized(facts.projectRoot)
        var resolvedBranch: String?
        if isWorktree {
            resolvedBranch = branch
            if branch == nil, configuration.readsBranchFromGit {
                let current = await GitService.shared.currentBranch(in: facts.checkoutRoot)
                resolvedBranch = current == "HEAD" ? nil : current
            }
        }
        return ImportWorkspacePlan(
            kind: isWorktree ? .worktree : .directory,
            repoPath: facts.projectRoot,
            branchName: resolvedBranch,
            isValidated: true
        )
    }

    /// A source can record a transcript path that names a file since deleted or
    /// moved between project directories.
    private static func resolvingTranscripts(
        _ tabs: [ImportTabPlan],
        fallbackDirectory: String,
        configuration: Configuration
    ) -> [ImportTabPlan] {
        tabs.map { tab in
            guard tab.kind == .agent else { return tab }
            if tab.provider == .codex {
                return configuration.resolveCodexTab?(tab) ?? tab
            }
            let directory = tab.workingDirectoryPath ?? fallbackDirectory
            if let sessionID = tab.agentSessionID,
               let path = transcriptPath(sessionID: sessionID, directory: directory, recorded: tab.sessionJSONLPath) {
                return ImportTabPlan(
                    kind: tab.kind,
                    title: tab.title,
                    workingDirectoryPath: tab.workingDirectoryPath,
                    agentSessionID: tab.agentSessionID,
                    sessionJSONLPath: path,
                    permissionMode: tab.permissionMode
                )
            }
            switch configuration.missingTranscript {
            case .reject:
                return tab
            case .downgradeToTerminal:
                return ImportTabPlan(
                    kind: .terminal,
                    title: nil,
                    workingDirectoryPath: tab.workingDirectoryPath,
                    agentSessionID: nil,
                    sessionJSONLPath: nil,
                    permissionMode: nil
                )
            }
        }
    }

    /// A Codex tab keeps its thread when its rollout is valid and otherwise
    /// becomes a plain terminal with no title, as a Claude tab does.
    static func resolvingCodexTab(_ tab: ImportTabPlan, hasValidRollout: Bool) -> ImportTabPlan {
        guard hasValidRollout, let sessionID = tab.agentSessionID else {
            return ImportTabPlan(
                kind: .terminal,
                title: nil,
                workingDirectoryPath: tab.workingDirectoryPath,
                agentSessionID: nil,
                sessionJSONLPath: nil,
                permissionMode: nil,
                provider: .codex
            )
        }
        return ImportTabPlan(
            kind: .agent,
            title: tab.title,
            workingDirectoryPath: tab.workingDirectoryPath,
            agentSessionID: sessionID,
            sessionJSONLPath: nil,
            permissionMode: nil,
            provider: .codex
        )
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
