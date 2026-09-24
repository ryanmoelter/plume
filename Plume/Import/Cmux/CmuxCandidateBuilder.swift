import Foundation

/// Turns a snapshot into candidates, applying every rule that can be decided
/// without touching git or the filesystem.
///
/// Pure and synchronous, so the sheet can draw its rows before any subprocess
/// runs. `CmuxImportValidator` fills in the rest.
nonisolated enum CmuxCandidateBuilder {
    /// cmux marks an agent-bearing tab with this.
    static let agentTitleMarker = "✳"

    static func candidates(from snapshot: CmuxSnapshot) -> [ImportCandidate] {
        snapshot.workspaces.map(candidate(for:))
    }

    static func candidate(for workspace: CmuxWorkspaceView) -> ImportCandidate {
        let directory = workspace.currentDirectory?.trimmingCharacters(in: .whitespaces) ?? ""
        let tabs = workspace.panels.filter(\.isTerminal).map(tabPlan(for:))

        return ImportCandidate(
            stableID: workspace.stableID.map { "cmux:\($0)" } ?? "",
            title: title(for: workspace, directory: directory),
            workingDirectoryPath: directory,
            groupName: workspace.groupName,
            tabs: tabs,
            workspace: ImportWorkspacePlan(branchName: workspace.branch),
            rejection: rejection(for: workspace, directory: directory, tabs: tabs)
        )
    }

    /// A workspace cmux never titled repeats its own path, which says nothing
    /// the row's own path line doesn't.
    static func title(for workspace: CmuxWorkspaceView, directory: String) -> String {
        let folder = URL(fileURLWithPath: directory).lastPathComponent
        guard let raw = workspace.processTitle?.trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return folder }

        let stripped = raw.hasPrefix(agentTitleMarker)
            ? String(raw.dropFirst(agentTitleMarker.count)).trimmingCharacters(in: .whitespaces)
            : raw
        guard !stripped.isEmpty, !namesTheSamePath(stripped, as: directory) else { return folder }
        return stripped
    }

    /// cmux abbreviates a home-relative title with `~`, against whichever home
    /// wrote the file — so compare by trailing path components rather than by
    /// expanding `~` here.
    private static func namesTheSamePath(_ title: String, as directory: String) -> Bool {
        guard title.hasPrefix("/") || title.hasPrefix("~") else { return false }
        if title == directory { return true }
        let components = title.split(separator: "/").filter { $0 != "~" }
        guard !components.isEmpty else { return false }
        return directory.split(separator: "/").suffix(components.count) == components[...]
    }

    private static func tabPlan(for panel: CmuxPanelView) -> ImportTabPlan {
        guard let session = panel.session, let sessionID = session.sessionId, !sessionID.isEmpty else {
            return ImportTabPlan(
                kind: .terminal,
                title: cleanedTitle(panel.title),
                workingDirectoryPath: panel.directory,
                agentSessionID: nil,
                sessionJSONLPath: nil,
                permissionMode: nil
            )
        }
        return ImportTabPlan(
            kind: .agent,
            title: cleanedTitle(panel.title),
            // The session's own cwd, not the workspace's: an agent can run in
            // a worktree its workspace does not point at.
            workingDirectoryPath: session.cwd ?? panel.directory,
            agentSessionID: sessionID,
            // What cmux recorded. Validation prefers it, then falls back to
            // deriving one, since the file it names may be gone.
            sessionJSONLPath: session.transcriptPath,
            permissionMode: panel.provider == .claudeCode ? session.lastPermissionMode.flatMap(PermissionMode.init(rawValue:)) : nil,
            provider: panel.provider
        )
    }

    private static func cleanedTitle(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
        let stripped = title.hasPrefix(agentTitleMarker)
            ? String(title.dropFirst(agentTitleMarker.count)).trimmingCharacters(in: .whitespaces)
            : title
        return stripped.isEmpty ? nil : stripped
    }

    private static func rejection(
        for workspace: CmuxWorkspaceView,
        directory: String,
        tabs: [ImportTabPlan]
    ) -> ImportRejection? {
        guard workspace.stableID?.isEmpty == false else { return .noStableIdentity }
        guard !directory.isEmpty else { return .noWorkingDirectory }
        guard !tabs.isEmpty else { return .nothingToImport }
        return nil
    }
}
