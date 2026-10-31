import Foundation

/// Where in a project a task started from Home runs.
nonisolated enum HomeWorkspaceChoice: String, CaseIterable, Sendable {
    case newWorktree
    case projectFolder
    // A subfolder of the project is the next choice planned here.

    var title: String {
        switch self {
        case .newWorktree: "New worktree"
        case .projectFolder: "Project folder"
        }
    }

    var systemImage: String {
        switch self {
        case .newWorktree: "tree"
        case .projectFolder: "folder"
        }
    }
}

/// A folder a task can start in: a repository's root, or a plain folder that
/// isn't in one.
nonisolated struct HomeProject: Hashable, Identifiable, Sendable {
    let path: String
    let isRepository: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    var workspaceChoices: [HomeWorkspaceChoice] {
        isRepository ? [.newWorktree, .projectFolder] : [.projectFolder]
    }
}

/// Group, project and workspace for the next task Home starts. A nil group is
/// the ungrouped section.
nonisolated struct HomeDestination: Equatable, Sendable {
    var groupID: UUID?
    var projectPath: String?
    var workspace: HomeWorkspaceChoice
}

/// What a task started from Home is created with.
nonisolated struct HomeTaskPlan: Equatable, Sendable {
    enum Workspace: Equatable, Sendable {
        case directory(path: String, repoPath: String?)
        case newWorktree(repository: String, branch: String)
    }

    let groupID: UUID?
    let workspace: Workspace
    let message: String
}

/// Everything the destination pickers offer, and the defaults they start on.
nonisolated struct HomeDestinationCatalog: Equatable, Sendable {
    struct GroupOption: Hashable, Identifiable, Sendable {
        let id: UUID
        let name: String
    }

    struct TaskFacts: Equatable, Sendable {
        let id: UUID
        let groupID: UUID?
        let projectPath: String?
        let workspaceKind: WorkspaceKind
    }

    static let noGroupTitle = "No group"

    var groups: [GroupOption] = []
    /// Sorted by name.
    var projects: [HomeProject] = []
    /// Newest first.
    var tasks: [TaskFacts] = []

    func group(id: UUID?) -> GroupOption? {
        id.flatMap { id in groups.first { $0.id == id } }
    }

    func project(at path: String?) -> HomeProject? {
        path.flatMap { path in projects.first { $0.path == path } }
    }

    /// The most recently selected task's group and project, else the first
    /// of each.
    func defaultDestination(recentTaskID: UUID?) -> HomeDestination {
        let recent = recentTaskID.flatMap { id in tasks.first { $0.id == id } }
        let groupID = recent.map { group(id: $0.groupID)?.id } ?? groups.first?.id
        let projectPath = project(at: recent?.projectPath)?.path ?? projects.first?.path
        return HomeDestination(
            groupID: groupID,
            projectPath: projectPath,
            workspace: defaultWorkspace(forProject: projectPath, preferring: recent)
        )
    }

    /// Projects have no workspace setting of their own, so the default is
    /// whatever the project's latest task ran in, a worktree or the folder.
    func defaultWorkspace(forProject path: String?, preferring recent: TaskFacts? = nil) -> HomeWorkspaceChoice {
        guard let project = project(at: path), project.isRepository else { return .projectFolder }
        let candidates = [recent].compactMap { $0 } + tasks
        let latest = candidates.first { $0.projectPath == project.path && $0.workspaceKind != .unset }
        return latest?.workspaceKind == .worktree ? .newWorktree : .projectFolder
    }

    func choosingProject(_ path: String, in destination: HomeDestination) -> HomeDestination {
        var result = destination
        result.projectPath = path
        result.workspace = defaultWorkspace(forProject: path)
        return result
    }

    /// Drops a group or project that has gone, and a workspace its project
    /// can't offer.
    func validated(_ destination: HomeDestination) -> HomeDestination {
        var result = destination
        if destination.groupID != nil, group(id: destination.groupID) == nil {
            result.groupID = groups.first?.id
        }
        if project(at: destination.projectPath) == nil {
            result.projectPath = projects.first?.path
            result.workspace = defaultWorkspace(forProject: result.projectPath)
        } else if let project = project(at: result.projectPath),
                  !project.workspaceChoices.contains(result.workspace) {
            result.workspace = .projectFolder
        }
        return result
    }

    /// Nil without a project or with nothing to send.
    func plan(
        for destination: HomeDestination,
        message: String,
        branchPrefix: String,
        branchSuffix: String = WorkspaceProvisioner.randomSuffix()
    ) -> HomeTaskPlan? {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let project = project(at: destination.projectPath) else { return nil }
        let repository = project.isRepository ? ProjectRoot.repositoryDirectory(forRoot: project.path) : nil
        let workspace: HomeTaskPlan.Workspace
        if destination.workspace == .newWorktree, let repository {
            let branch = WorkspaceProvisioner.suggestedBranchName(
                for: Self.branchSeed(from: message), suffix: branchSuffix, prefix: branchPrefix
            )
            workspace = .newWorktree(repository: repository, branch: branch)
        } else {
            workspace = .directory(path: project.path, repoPath: repository)
        }
        return HomeTaskPlan(groupID: group(id: destination.groupID)?.id, workspace: workspace, message: message)
    }

    /// The message's first line: `slugify` trims it to a branch-sized length.
    static func branchSeed(from message: String) -> String {
        message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}
