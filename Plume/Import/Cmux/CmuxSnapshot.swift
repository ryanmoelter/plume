import Foundation

/// The two cmux files joined into what an import needs: workspaces in sidebar
/// order, each panel already paired with the agent session running in it.
nonisolated struct CmuxSnapshot: Sendable {
    let workspaces: [CmuxWorkspaceView]

    static func decoding(sessionData: Data, hookData: Data?) -> CmuxSnapshot {
        let decoder = JSONDecoder()
        guard let file = try? decoder.decode(CmuxSessionFile.self, from: sessionData) else {
            return CmuxSnapshot(workspaces: [])
        }
        let hooks = hookData.flatMap { try? decoder.decode(CmuxHookSessions.self, from: $0) }

        var views: [CmuxWorkspaceView] = []
        for window in file.windows {
            guard let manager = window.tabManager else { continue }
            let groupNames = Dictionary(
                (manager.workspaceGroups ?? []).compactMap { group -> (String, String)? in
                    guard let id = group.id, let name = group.name, !name.isEmpty else { return nil }
                    return (id, name)
                },
                uniquingKeysWith: { first, _ in first }
            )
            for workspace in manager.workspaces {
                views.append(
                    CmuxWorkspaceView(
                        workspace: workspace,
                        groupName: workspace.groupId.flatMap { groupNames[$0] },
                        hooks: hooks
                    )
                )
            }
        }
        return CmuxSnapshot(workspaces: views)
    }

    static func loadingFromDisk() -> CmuxSnapshot {
        guard let sessionData = try? Data(contentsOf: CmuxLocations.sessionFile) else {
            return CmuxSnapshot(workspaces: [])
        }
        return decoding(
            sessionData: sessionData,
            hookData: try? Data(contentsOf: CmuxLocations.hookSessionsFile)
        )
    }
}

nonisolated struct CmuxWorkspaceView: Sendable {
    let stableID: String?
    let workspaceID: String?
    let groupName: String?
    let currentDirectory: String?
    let branch: String?
    let processTitle: String?
    let panels: [CmuxPanelView]
}

nonisolated struct CmuxPanelView: Sendable {
    let panelID: String
    let type: String
    let title: String?
    let directory: String?
    /// The agent running in this pane, if cmux still records one.
    let session: CmuxSessionRecord?

    var isTerminal: Bool { type == "terminal" }
}

extension CmuxWorkspaceView {
    /// Pairs each panel with its session.
    ///
    /// `activeSessionsBySurface` holds what is running now rather than a
    /// history, so most panes resolve to nothing. The workspace-keyed map is a
    /// fallback for the common single-agent workspace, and applies to one
    /// panel only — two panes sharing a session id would each claim a
    /// conversation that cannot be held twice.
    init(workspace: CmuxWorkspace, groupName: String?, hooks: CmuxHookSessions?) {
        let bySurface = hooks?.activeSessionsBySurface ?? [:]
        let records = hooks?.sessions ?? [:]

        func directSession(for panel: CmuxPanel) -> CmuxSessionRecord? {
            let keys = [panel.id, panel.stableSurfaceId].compactMap { $0 }
            for key in keys {
                if let id = bySurface[key]?.sessionId, let record = records[id] { return record }
            }
            return nil
        }

        var resolved = workspace.panels.map { panel in
            CmuxPanelView(
                panelID: panel.id ?? UUID().uuidString,
                type: panel.type ?? "terminal",
                title: panel.title,
                directory: panel.directory ?? panel.terminal?.workingDirectory,
                session: directSession(for: panel)
            )
        }

        if resolved.allSatisfy({ $0.session == nil }),
           let workspaceID = workspace.workspaceId,
           let id = hooks?.activeSessionsByWorkspace?[workspaceID]?.sessionId,
           let record = records[id],
           let target = resolved.firstIndex(where: { $0.isTerminal }) {
            resolved[target] = CmuxPanelView(
                panelID: resolved[target].panelID,
                type: resolved[target].type,
                title: resolved[target].title,
                directory: resolved[target].directory,
                session: record
            )
        }

        self.init(
            stableID: workspace.stableId,
            workspaceID: workspace.workspaceId,
            groupName: groupName,
            currentDirectory: workspace.currentDirectory,
            branch: workspace.gitBranch?.branch,
            processTitle: workspace.processTitle,
            panels: resolved
        )
    }
}
