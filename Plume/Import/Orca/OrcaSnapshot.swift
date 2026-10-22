import Foundation

/// An Orca profile joined into what an import needs: worktrees in sidebar
/// order, each with its tabs in strip order — one per terminal pane — and
/// agent tabs already paired with the session they resume.
nonisolated struct OrcaSnapshot: Sendable {
    static let supportedSchemaVersion = 1

    let worktrees: [OrcaWorktreeView]
    /// The state decoded but carries a schema version Plume does not read.
    var isUnsupportedSchema = false
    /// `profile-state.db` exists but could not be read.
    var isUnreadable = false

    /// `claudeSessionIDs` maps an Orca agent session id (a structured chat
    /// tab's `entityId`) to the Claude session it last ran as.
    /// `paneStatus` is the hook status Orca last saw in each pane, keyed by
    /// pane key.
    static func decoding(
        data: Data,
        claudeSessionIDs: [String: String],
        paneStatus: [String: OrcaLastStatus.Status] = [:]
    ) -> OrcaSnapshot {
        guard let file = try? JSONDecoder().decode(OrcaDataFile.self, from: data)
        else { return OrcaSnapshot(worktrees: []) }
        guard file.schemaVersion == supportedSchemaVersion
        else { return OrcaSnapshot(worktrees: [], isUnsupportedSchema: true) }

        let session = file.workspaceSession
        let unified = session?.unifiedTabs
        let legacy = unified == nil ? session?.tabsByWorktree ?? [:] : [:]
        let panes = OrcaPaneResolver(
            layouts: session?.terminalLayoutsByTabId ?? [:],
            sleepingAgents: session?.sleepingAgentSessionsByPaneKey ?? [:],
            paneStatus: paneStatus
        )

        var views: [OrcaWorktreeView] = []
        for worktreeID in Set((unified ?? [:]).keys).union(legacy.keys) {
            guard OrcaWorktreeView.split(worktreeID).path != nil,
                  file.worktreeMeta[worktreeID]?.isRemote != true
            else { continue }
            let tabOrder = (session?.tabGroups[worktreeID] ?? []).flatMap { $0.tabOrder ?? [] }
            let tabs: [OrcaTabView]
            if let unifiedTabs = unified?[worktreeID] {
                guard !unifiedTabs.isEmpty else { continue }
                tabs = ordered(unifiedTabs, by: tabOrder, id: \.id, sortOrder: \.sortOrder)
                    .flatMap { OrcaTabView.views(unified: $0, claudeSessionIDs: claudeSessionIDs, panes: panes) }
            } else {
                let legacyTabs = legacy[worktreeID] ?? []
                guard !legacyTabs.isEmpty else { continue }
                tabs = ordered(legacyTabs, by: tabOrder, id: \.id, sortOrder: \.sortOrder)
                    .flatMap { OrcaTabView.views(legacy: $0, panes: panes) }
            }
            guard !tabs.isEmpty else { continue }
            views.append(OrcaWorktreeView(worktreeID: worktreeID, file: file, tabs: tabs))
        }
        return OrcaSnapshot(worktrees: sortedForSidebar(views, repos: file.repos))
    }

    /// `profile-state.db`; the `orca-data.json` export only when the database
    /// does not exist, since a database that cannot be read has newer state.
    static func loading(
        profileStateFile: URL,
        dataFile: URL,
        claudeSessionIDs: [String: String],
        paneStatus: [String: OrcaLastStatus.Status]
    ) -> OrcaSnapshot {
        let data: Data
        switch OrcaProfileState.read(at: profileStateFile) {
        case .document(let document):
            data = document
        case .unsupportedSchema:
            return OrcaSnapshot(worktrees: [], isUnsupportedSchema: true)
        case .unreadable:
            return OrcaSnapshot(worktrees: [], isUnreadable: true)
        case .missing:
            guard let fallback = try? Data(contentsOf: dataFile) else { return OrcaSnapshot(worktrees: []) }
            data = fallback
        }
        return decoding(data: data, claudeSessionIDs: claudeSessionIDs, paneStatus: paneStatus)
    }

    static func loadingFromDisk(now: Date = Date()) -> OrcaSnapshot {
        let profileID = OrcaLocations.activeProfileID
        return loading(
            profileStateFile: OrcaLocations.profileStateFile(profileID: profileID),
            dataFile: OrcaLocations.dataFile(profileID: profileID),
            claudeSessionIDs: OrcaAgentJournal.claudeSessionIDs(at: OrcaLocations.agentJournalFile),
            paneStatus: OrcaLastStatus.statuses(from: try? Data(contentsOf: OrcaLocations.lastStatusFile), now: now)
        )
    }

    /// Orca's own strip order: a tab's place in its groups' `tabOrder`, then
    /// `sortOrder` for any tab no group names.
    private static func ordered<Tab>(
        _ tabs: [Tab],
        by tabOrder: [String],
        id: KeyPath<Tab, String?>,
        sortOrder: KeyPath<Tab, Double?>
    ) -> [Tab] {
        let positions = Dictionary(tabOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return tabs.enumerated().sorted { lhs, rhs in
            let lhsPosition = lhs.element[keyPath: id].flatMap { positions[$0] } ?? Int.max
            let rhsPosition = rhs.element[keyPath: id].flatMap { positions[$0] } ?? Int.max
            if lhsPosition != rhsPosition { return lhsPosition < rhsPosition }
            let lhsSort = lhs.element[keyPath: sortOrder] ?? .infinity
            let rhsSort = rhs.element[keyPath: sortOrder] ?? .infinity
            if lhsSort != rhsSort { return lhsSort < rhsSort }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Repos in Orca's order, then worktrees by descending `sortOrder` — Orca
    /// treats a higher value as nearer the top.
    private static func sortedForSidebar(_ views: [OrcaWorktreeView], repos: [OrcaRepo]) -> [OrcaWorktreeView] {
        let repoPositions = Dictionary(
            repos.enumerated().compactMap { index, repo in repo.id.map { ($0, index) } },
            uniquingKeysWith: { first, _ in first }
        )
        return views.sorted { lhs, rhs in
            let lhsRepo = lhs.repoID.flatMap { repoPositions[$0] } ?? Int.max
            let rhsRepo = rhs.repoID.flatMap { repoPositions[$0] } ?? Int.max
            if lhsRepo != rhsRepo { return lhsRepo < rhsRepo }
            let lhsSort = lhs.sortOrder ?? -.infinity
            let rhsSort = rhs.sortOrder ?? -.infinity
            if lhsSort != rhsSort { return lhsSort > rhsSort }
            return lhs.worktreeID < rhs.worktreeID
        }
    }
}

nonisolated struct OrcaWorktreeView: Sendable {
    let worktreeID: String
    let repoID: String?
    let repoName: String?
    /// Nil when the worktree id carries no absolute path.
    let path: String?
    let displayName: String?
    let sortOrder: Double?
    /// Only the terminal and agent tabs; file, browser and other tabs drop out.
    let tabs: [OrcaTabView]

    init(worktreeID: String, file: OrcaDataFile, tabs: [OrcaTabView]) {
        let parts = Self.split(worktreeID)
        let repo = parts.repoID.flatMap { id in file.repos.first { $0.id == id } }
        let meta = file.worktreeMeta[worktreeID]
        self.worktreeID = worktreeID
        repoID = parts.repoID
        repoName = repo.flatMap(Self.name(of:))
        path = parts.path
        displayName = meta?.displayName
        sortOrder = meta?.sortOrder
        self.tabs = tabs
    }

    private static func name(of repo: OrcaRepo) -> String? {
        if let name = repo.displayName?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        guard let path = repo.path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// A worktree id is `<repoId>::<absolute path>`; the path may itself
    /// contain `::`, so only the first separator counts.
    static func split(_ worktreeID: String) -> (repoID: String?, path: String?) {
        guard let separator = worktreeID.range(of: "::") else { return (nil, nil) }
        let repoID = String(worktreeID[..<separator.lowerBound])
        let path = String(worktreeID[separator.upperBound...])
        return (repoID.isEmpty ? nil : repoID, path.hasPrefix("/") ? path : nil)
    }
}

/// One Plume tab's worth of an Orca tab: the whole tab for a chat, or one
/// pane of a terminal tab.
nonisolated struct OrcaTabView: Sendable, Hashable {
    let title: String?
    /// Nil for a plain terminal.
    let session: OrcaAgentSession?

    init(title: String?, session: OrcaAgentSession?) {
        self.title = title
        self.session = session
    }

    static func views(unified tab: OrcaUnifiedTab, claudeSessionIDs: [String: String], panes: OrcaPaneResolver) -> [OrcaTabView] {
        let title = firstNonEmpty(tab.customLabel, tab.label)
        switch tab.contentType {
        case "terminal":
            return panes.views(tabID: tab.entityId ?? tab.id, title: title)
        case "agent-session":
            let orcaSessionID = tab.entityId ?? tab.id.map { $0.replacingOccurrences(of: "structured-agent-session-", with: "") }
            let claudeID = tab.agentSessionAgent == "claude" ? orcaSessionID.flatMap { claudeSessionIDs[$0] } : nil
            let session = claudeID.map {
                OrcaAgentSession(agent: "claude", sessionID: $0, transcriptPath: nil, source: .agentJournal)
            }
            return [OrcaTabView(title: session == nil ? nil : title, session: session)]
        default:
            return []
        }
    }

    static func views(legacy tab: OrcaTerminalTab, panes: OrcaPaneResolver) -> [OrcaTabView] {
        panes.views(tabID: tab.id, title: firstNonEmpty(tab.customTitle, tab.title))
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        candidates.lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}

/// Splits a terminal tab into its panes and finds the agent each one was
/// running.
nonisolated struct OrcaPaneResolver: Sendable {
    let layouts: [String: OrcaTerminalLayout]
    let sleepingAgents: [String: OrcaSleepingAgent]
    let paneStatus: [String: OrcaLastStatus.Status]

    /// One view per pane, in split order. A tab with no saved layout is one
    /// plain terminal.
    func views(tabID: String?, title: String?) -> [OrcaTabView] {
        guard let tabID, let layout = layouts[tabID], let leafIDs = layout.root?.leafIDs, !leafIDs.isEmpty
        else { return [OrcaTabView(title: title, session: nil)] }
        return leafIDs.enumerated().map { index, leafID in
            OrcaTabView(
                title: paneTitle(layout.titlesByLeafId?[leafID], tabTitle: title, index: index),
                session: session(forPaneKey: "\(tabID):\(leafID)")
            )
        }
    }

    /// A hook status that is not `done` decides alone, as in Orca's cold
    /// restore, even when it cannot be resumed; the sleeping record covers
    /// only a finished, stale or missing status.
    func session(forPaneKey paneKey: String) -> OrcaAgentSession? {
        if let status = paneStatus[paneKey] { return status.session }
        guard let record = sleepingAgents[paneKey] else { return nil }
        return OrcaAgentSession(
            agent: record.agent,
            providerSession: record.providerSession,
            connectionId: record.connectionId,
            source: .sleepingAgent
        )
    }

    private func paneTitle(_ custom: String?, tabTitle: String?, index: Int) -> String? {
        if let custom = custom?.trimmingCharacters(in: .whitespaces), !custom.isEmpty { return custom }
        guard index > 0 else { return tabTitle }
        return tabTitle.map { "\($0) (\(index + 1))" }
    }
}
