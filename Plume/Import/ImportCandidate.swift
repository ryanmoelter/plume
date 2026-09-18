import Foundation

/// One importable workspace from another app, as the preview sheet shows it
/// and the importer consumes it.
///
/// Nothing here names the app it came from: a source supplies candidates, and
/// `Importer` turns them into tasks without knowing which app produced them.
/// `stableID` carries its own namespace (`cmux:<uuid>`).
nonisolated struct ImportCandidate: Identifiable, Sendable, Hashable {
    var id: String { stableID }
    let stableID: String
    let title: String
    let workingDirectoryPath: String
    /// The group this belongs to in the source app. Nil means ungrouped.
    let groupName: String?
    var tabs: [ImportTabPlan]
    var workspace: ImportWorkspacePlan
    /// Why this cannot be imported. Non-nil rows are shown but not selectable.
    var rejection: ImportRejection?
    /// Set when the store already holds this `stableID`.
    var isAlreadyImported: Bool = false

    var isImportable: Bool { rejection == nil && !isAlreadyImported }

    var agentTabCount: Int { tabs.count { $0.kind == .agent } }
    var terminalTabCount: Int { tabs.count { $0.kind == .terminal } }
}

nonisolated struct ImportTabPlan: Sendable, Hashable {
    let kind: TabKind
    let title: String?
    /// Where this tab was, which is not always its workspace's directory.
    let workingDirectoryPath: String?
    let agentSessionID: String?
    let sessionJSONLPath: String?
    let permissionMode: PermissionMode?
}

/// How the task's folder relates to git, resolved before the import writes
/// anything. `.unset` until validation has run.
nonisolated struct ImportWorkspacePlan: Sendable, Hashable {
    var kind: WorkspaceKind = .unset
    var repoPath: String?
    var branchName: String?
    var isValidated: Bool = false
}

/// Why a workspace cannot be imported. Each case states what is missing, since
/// the sheet shows it verbatim as the row's reason.
nonisolated enum ImportRejection: Sendable, Hashable {
    case noStableIdentity
    case noWorkingDirectory
    case directoryMissing(String)
    case unresolvableSession(String)
    case nothingToImport

    var reason: String {
        switch self {
        case .noStableIdentity:
            "No stable identifier, so a repeat import could not skip it"
        case .noWorkingDirectory:
            "No working directory recorded"
        case .directoryMissing(let path):
            "Folder no longer exists: \(abbreviating(path))"
        case .unresolvableSession(let id):
            "No transcript found for session \(id.prefix(8))"
        case .nothingToImport:
            "No importable tabs"
        }
    }

    private func abbreviating(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Where imported tasks land in the sidebar.
nonisolated enum ImportTarget: Hashable, Sendable {
    /// Recreate the source app's groups, reusing a Plume group of the same name.
    case mirrorSourceGroups
    case ungrouped
    case existing(UUID)
}
