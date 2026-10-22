import Foundation

/// Turns desktop sessions into candidates, one per session, grouped by repo.
///
/// Pure: whether the folder and transcript still exist is left to
/// `ImportValidator`.
nonisolated enum ClaudeDesktopCandidateBuilder {
    static func candidates(from snapshot: ClaudeDesktopSnapshot) -> [ImportCandidate] {
        snapshot.sessions.compactMap(candidate(for:))
    }

    static func candidate(for session: ClaudeDesktopSession) -> ImportCandidate? {
        guard let sessionID = nonEmpty(session.sessionID) else { return nil }
        let directory = nonEmpty(session.cwd) ?? ""
        let tabs = nonEmpty(session.cliSessionID).map { cliSessionID in
            [ImportTabPlan(
                kind: .agent,
                title: nonEmpty(session.title),
                workingDirectoryPath: directory.isEmpty ? nil : directory,
                agentSessionID: cliSessionID,
                sessionJSONLPath: nil,
                permissionMode: permissionMode(session.permissionMode)
            )]
        } ?? []

        return ImportCandidate(
            stableID: "claude-desktop:\(sessionID)",
            title: title(for: session, sessionID: sessionID, directory: directory),
            workingDirectoryPath: directory,
            groupName: groupName(for: session, directory: directory),
            tabs: tabs,
            workspace: ImportWorkspacePlan(branchName: nonEmpty(session.branch)),
            rejection: directory.isEmpty ? .noWorkingDirectory : tabs.isEmpty ? .nothingToImport : nil
        )
    }

    /// The desktop app calls the default mode `default`; Plume calls it manual.
    static func permissionMode(_ raw: String?) -> PermissionMode? {
        guard let raw else { return nil }
        return raw == "default" ? .manual : PermissionMode(rawValue: raw)
    }

    private static func title(for session: ClaudeDesktopSession, sessionID: String, directory: String) -> String {
        nonEmpty(session.title)
            ?? nonEmpty(session.worktreeName)
            ?? (directory.isEmpty ? sessionID : URL(fileURLWithPath: directory).lastPathComponent)
    }

    private static func groupName(for session: ClaudeDesktopSession, directory: String) -> String? {
        guard let repo = nonEmpty(session.originCwd) ?? nonEmpty(directory) else { return nil }
        return URL(fileURLWithPath: repo).lastPathComponent
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
