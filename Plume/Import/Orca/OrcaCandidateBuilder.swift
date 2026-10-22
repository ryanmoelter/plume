import Foundation

/// Turns an Orca snapshot into candidates, one per worktree with saved tabs.
///
/// Pure: whether the folder still exists, its git state and whether a session
/// still has a transcript are left to `ImportValidator`.
nonisolated enum OrcaCandidateBuilder {
    static func candidates(from snapshot: OrcaSnapshot) -> [ImportCandidate] {
        snapshot.worktrees.map(candidate(for:))
    }

    static func candidate(for worktree: OrcaWorktreeView) -> ImportCandidate {
        let directory = worktree.path ?? ""
        let tabs = worktree.tabs.map { tabPlan(for: $0, directory: directory) }

        return ImportCandidate(
            stableID: "orca:\(worktree.worktreeID)",
            title: title(for: worktree, directory: directory),
            workingDirectoryPath: directory,
            groupName: worktree.repoName,
            tabs: tabs,
            workspace: ImportWorkspacePlan(),
            rejection: rejection(directory: directory, tabs: tabs)
        )
    }

    private static func title(for worktree: OrcaWorktreeView, directory: String) -> String {
        if let name = worktree.displayName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        return directory.isEmpty ? worktree.worktreeID : URL(fileURLWithPath: directory).lastPathComponent
    }

    private static func tabPlan(for tab: OrcaTabView, directory: String) -> ImportTabPlan {
        let session = tab.session
        let provider = session?.provider
        return ImportTabPlan(
            kind: provider == nil ? .terminal : .agent,
            title: tab.title,
            workingDirectoryPath: directory.isEmpty ? nil : directory,
            agentSessionID: provider == nil ? nil : session?.sessionID,
            sessionJSONLPath: provider == nil ? nil : session?.transcriptPath,
            permissionMode: nil,
            provider: provider ?? .claudeCode
        )
    }

    private static func rejection(directory: String, tabs: [ImportTabPlan]) -> ImportRejection? {
        guard !directory.isEmpty else { return .noWorkingDirectory }
        guard !tabs.isEmpty else { return .nothingToImport }
        return nil
    }
}
