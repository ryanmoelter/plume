import Foundation

/// Swallows its own decode error so one malformed array element never fails
/// the whole array.
nonisolated struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

nonisolated struct CmuxSessionFile: Decodable {
    let version: Int?
    let createdAt: Double?
    private let windowsBox: [FailableDecodable<CmuxWindow>]?

    var windows: [CmuxWindow] {
        (windowsBox ?? []).compactMap(\.value)
    }

    private enum CodingKeys: String, CodingKey {
        case version, createdAt
        case windowsBox = "windows"
    }
}

nonisolated struct CmuxWindow: Decodable {
    let windowId: String?
    let tabManager: CmuxTabManager?
}

nonisolated struct CmuxTabManager: Decodable {
    let selectedWorkspaceIndex: Int?
    let workspaceGroups: [CmuxWorkspaceGroup]?
    private let workspacesBox: [FailableDecodable<CmuxWorkspace>]?

    var workspaces: [CmuxWorkspace] {
        (workspacesBox ?? []).compactMap(\.value)
    }

    private enum CodingKeys: String, CodingKey {
        case selectedWorkspaceIndex, workspaceGroups
        case workspacesBox = "workspaces"
    }
}

nonisolated struct CmuxWorkspaceGroup: Decodable {
    let id: String?
    let name: String?
    let isCollapsed: Bool?
    let isPinned: Bool?
    let anchorWorkspaceId: String?
    let anchorMemberIndex: Int?
}

nonisolated struct CmuxWorkspace: Decodable {
    let workspaceId: String?
    let stableId: String?
    let groupId: String?
    let currentDirectory: String?
    let processTitle: String?
    let gitBranch: CmuxGitBranch?
    let customColor: String?
    let isPinned: Bool?
    let focusedPanelId: String?
    let layout: CmuxLayout?
    private let panelsBox: [FailableDecodable<CmuxPanel>]?

    var panels: [CmuxPanel] {
        (panelsBox ?? []).compactMap(\.value)
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceId, stableId, groupId, currentDirectory, processTitle
        case gitBranch, customColor, isPinned, focusedPanelId, layout
        case panelsBox = "panels"
    }
}

nonisolated struct CmuxGitBranch: Decodable {
    let branch: String?
    let isDirty: Bool?
}

nonisolated struct CmuxLayout: Decodable {
    let type: String?
    let pane: CmuxPane?
}

nonisolated struct CmuxPane: Decodable {
    let panelIds: [String]?
    let selectedPanelId: String?
}

nonisolated struct CmuxPanel: Decodable {
    let id: String?
    let stableSurfaceId: String?
    /// Cmux also uses `browser`, `simulator`, `agent-session`, and future
    /// values this import must still tolerate — filtering happens later.
    let type: String?
    let title: String?
    let directory: String?
    let ttyName: String?
    let gitBranch: CmuxGitBranch?
    let terminal: CmuxTerminal?
}

nonisolated struct CmuxTerminal: Decodable {
    let workingDirectory: String?
    let isRemoteTerminal: Bool?
}
