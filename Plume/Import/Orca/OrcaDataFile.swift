import Foundation

/// The parts of a profile's `orca-data.json` an import needs. Every field is
/// decoded on its own, so a section Orca reshapes drops out instead of failing
/// the whole file.
nonisolated struct OrcaDataFile: Decodable {
    let schemaVersion: Int?
    let repos: [OrcaRepo]
    /// Keyed by worktree id, `<repoId>::<absolute path>`.
    let worktreeMeta: [String: OrcaWorktreeMeta]
    let workspaceSession: OrcaWorkspaceSession?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, repos, worktreeMeta, workspaceSession
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try? container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        repos = ((try? container.decodeIfPresent([FailableDecodable<OrcaRepo>].self, forKey: .repos)) ?? nil)?
            .compactMap(\.value) ?? []
        worktreeMeta = ((try? container.decodeIfPresent([String: FailableDecodable<OrcaWorktreeMeta>].self, forKey: .worktreeMeta)) ?? nil)?
            .compactMapValues(\.value) ?? [:]
        workspaceSession = try? container.decodeIfPresent(OrcaWorkspaceSession.self, forKey: .workspaceSession)
    }
}

nonisolated struct OrcaRepo: Decodable {
    let id: String?
    let path: String?
    let displayName: String?
}

nonisolated struct OrcaWorktreeMeta: Decodable {
    let displayName: String?
    let sortOrder: Double?
    /// Absent or `local` for a worktree on this machine.
    let hostId: String?

    var isRemote: Bool {
        guard let hostId, !hostId.isEmpty else { return false }
        return hostId != "local"
    }
}

nonisolated struct OrcaWorkspaceSession: Decodable {
    /// Every tab kind Orca shows, keyed by worktree id.
    let unifiedTabs: [String: [OrcaUnifiedTab]]?
    /// Terminal tabs only, from before `unifiedTabs` existed.
    let tabsByWorktree: [String: [OrcaTerminalTab]]
    /// Keyed by worktree id.
    let tabGroups: [String: [OrcaTabGroup]]
    /// A terminal tab's split panes, keyed by tab id.
    let terminalLayoutsByTabId: [String: OrcaTerminalLayout]
    /// What Orca saved to resume each pane's agent, keyed by `<tabId>:<leafId>`.
    let sleepingAgentSessionsByPaneKey: [String: OrcaSleepingAgent]

    private enum CodingKeys: String, CodingKey {
        case unifiedTabs, tabsByWorktree, tabGroups, terminalLayoutsByTabId, sleepingAgentSessionsByPaneKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unifiedTabs = ((try? container.decodeIfPresent([String: [FailableDecodable<OrcaUnifiedTab>]].self, forKey: .unifiedTabs)) ?? nil)?
            .mapValues { $0.compactMap(\.value) }
        tabsByWorktree = ((try? container.decodeIfPresent([String: [FailableDecodable<OrcaTerminalTab>]].self, forKey: .tabsByWorktree)) ?? nil)?
            .mapValues { $0.compactMap(\.value) } ?? [:]
        terminalLayoutsByTabId = ((try? container.decodeIfPresent([String: FailableDecodable<OrcaTerminalLayout>].self, forKey: .terminalLayoutsByTabId)) ?? nil)?
            .compactMapValues(\.value) ?? [:]
        sleepingAgentSessionsByPaneKey = ((try? container.decodeIfPresent([String: FailableDecodable<OrcaSleepingAgent>].self, forKey: .sleepingAgentSessionsByPaneKey)) ?? nil)?
            .compactMapValues(\.value) ?? [:]

        // Orca 1.4 writes a map keyed by worktree; a flat array is accepted too.
        if let keyed = try? container.decodeIfPresent([String: [FailableDecodable<OrcaTabGroup>]].self, forKey: .tabGroups) {
            tabGroups = keyed.mapValues { $0.compactMap(\.value) }
        } else if let flat = try? container.decodeIfPresent([FailableDecodable<OrcaTabGroup>].self, forKey: .tabGroups) {
            tabGroups = Dictionary(grouping: flat.compactMap(\.value).filter { $0.worktreeId != nil }, by: { $0.worktreeId ?? "" })
        } else {
            tabGroups = [:]
        }
    }
}

nonisolated struct OrcaUnifiedTab: Decodable {
    let id: String?
    let entityId: String?
    let contentType: String?
    let label: String?
    let customLabel: String?
    let sortOrder: Double?
    let agentSessionAgent: String?
}

nonisolated struct OrcaTerminalTab: Decodable {
    let id: String?
    let title: String?
    let customTitle: String?
    let sortOrder: Double?
}

nonisolated struct OrcaTabGroup: Decodable {
    let id: String?
    let worktreeId: String?
    let tabOrder: [String]?
}

nonisolated struct OrcaTerminalLayout: Decodable, Sendable {
    let root: OrcaPaneNode?
    /// Pane titles the user set, keyed by leaf id.
    let titlesByLeafId: [String: String]?
}

nonisolated indirect enum OrcaPaneNode: Decodable, Sendable {
    case leaf(id: String)
    case split(first: OrcaPaneNode, second: OrcaPaneNode)

    private enum CodingKeys: String, CodingKey {
        case type, leafId, first, second
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "leaf":
            self = .leaf(id: try container.decode(String.self, forKey: .leafId))
        case "split":
            self = .split(
                first: try container.decode(OrcaPaneNode.self, forKey: .first),
                second: try container.decode(OrcaPaneNode.self, forKey: .second)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown pane node")
        }
    }

    /// Depth-first, first child before second: left before right, top before bottom.
    var leafIDs: [String] {
        var result: [String] = []
        var stack = [self]
        while let node = stack.popLast() {
            switch node {
            case .leaf(let id): result.append(id)
            case .split(let first, let second): stack.append(contentsOf: [second, first])
            }
        }
        return result
    }
}

/// Orca's own handle on an agent it can resume in a pane, written at quit or
/// when a worktree sleeps.
nonisolated struct OrcaSleepingAgent: Decodable, Sendable {
    let agent: String?
    let providerSession: OrcaProviderSession?
    /// Non-empty for a pane on another machine.
    let connectionId: String?
}

nonisolated struct OrcaProviderSession: Decodable, Sendable {
    let key: String?
    let id: String?
    let transcriptPath: String?
}
