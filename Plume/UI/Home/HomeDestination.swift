import Foundation

/// Where in a project a task started from Home runs: one of the repository's
/// worktrees, or a new one named from the message.
nonisolated enum HomeWorkspaceChoice: Hashable, Sendable {
    case newWorktree
    /// The project's own folder: the repository's main checkout, or a plain
    /// folder that isn't in one.
    case projectFolder
    /// A linked worktree that already exists.
    case worktree(path: String, branch: String?)

    static let newWorktreeTitle = "New Worktree"
    /// What the new conversation screen calls the repository's own checkout.
    static let mainWorktreeTitle = "main"

    var title: String {
        switch self {
        case .newWorktree: Self.newWorktreeTitle
        case .projectFolder: Self.mainWorktreeTitle
        case .worktree(let path, _): (path as NSString).lastPathComponent
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

    func offers(_ choice: HomeWorkspaceChoice) -> Bool {
        isRepository || choice == .projectFolder
    }
}

/// A repository project's worktrees, as `git worktree list` gives them, in the
/// order the new conversation screen's worktree menu shows them.
nonisolated struct HomeWorktreeListing: Equatable, Sendable {
    let projectPath: String
    let worktrees: [GitWorktree]
    /// The main checkout's branch.
    let branch: String?

    /// The worktrees, then a new one.
    var choices: [HomeWorkspaceChoice] {
        var choices = worktrees.map(Self.choice(for:))
        if !choices.contains(.projectFolder) { choices.insert(.projectFolder, at: 0) }
        return choices + [.newWorktree]
    }

    /// A bare layout lists no main checkout, so its folder is just a folder.
    func title(for choice: HomeWorkspaceChoice) -> String {
        if choice == .projectFolder, !worktrees.contains(where: \.isMain) { return "Project folder" }
        return choice.title
    }

    func branch(for choice: HomeWorkspaceChoice) -> String? {
        switch choice {
        case .newWorktree: nil
        case .projectFolder: worktrees.first(where: \.isMain)?.branch ?? branch
        case .worktree(_, let branch): branch
        }
    }

    /// A worktree removed since it was chosen falls back to `fallback`.
    func validated(_ choice: HomeWorkspaceChoice, fallback: HomeWorkspaceChoice) -> HomeWorkspaceChoice {
        guard case .worktree(let path, _) = choice else { return choice }
        return choices.first { if case .worktree(path, _) = $0 { true } else { false } } ?? fallback
    }

    private static func choice(for worktree: GitWorktree) -> HomeWorkspaceChoice {
        worktree.isMain ? .projectFolder : .worktree(path: worktree.path, branch: worktree.branch)
    }
}

/// Group, project, workspace and subfolder for the next task Home starts. A
/// nil group is the ungrouped section.
nonisolated struct HomeDestination: Equatable, Sendable {
    var groupID: UUID?
    var projectPath: String?
    var workspace: HomeWorkspaceChoice
    /// Relative to whichever checkout `workspace` names. Nil is the project
    /// root.
    var subfolder: String? = nil
}

/// What a task started from Home is created with, and its first message.
nonisolated struct HomeTaskPlan: Equatable {
    enum Workspace: Equatable, Sendable {
        case directory(path: String, repoPath: String?)
        case newWorktree(repository: String, branch: String)
        case existingWorktree(path: String, repository: String, branch: String?)
    }

    var groupID: UUID?
    var workspace: Workspace
    /// Relative to the checkout `workspace` resolves to.
    var subfolder: String? = nil
    /// With its mentions already expanded into links.
    var message: String
    var images: [ChatImage] = []
    /// Nil leaves the new tab on the app's defaults.
    var choices: TabLaunchChoices?

    var blocks: [UserContentBlock] {
        [.text(message)] + images.map { .image($0) }
    }

    /// The task's working directory once `checkout` — the plan's folder, or
    /// the worktree created for it — is known.
    func workingDirectory(
        inCheckout checkout: String,
        isDirectory: (String) -> Bool = ProjectSubfolder.isDirectory
    ) -> String {
        ProjectSubfolder.existingDirectory(checkoutRoot: checkout, subfolder: subfolder, isDirectory: isDirectory)
    }
}

/// Everything the destination pickers offer, and the defaults they start on.
nonisolated struct HomeDestinationCatalog: Equatable, Sendable {
    struct GroupOption: Hashable, Identifiable, Sendable {
        let id: UUID
        let name: String
        /// A `SidebarTint` raw value.
        var tintRaw: String? = nil
        /// An SF Symbol name.
        var iconName: String? = nil
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
        result.subfolder = nil
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
            result.subfolder = nil
        } else if let project = project(at: result.projectPath), !project.offers(result.workspace) {
            result.workspace = .projectFolder
        }
        if project(at: result.projectPath)?.isRepository != true {
            result.subfolder = nil
        }
        return result
    }

    /// The composer's message, sent as text and images. The branch is named
    /// from the text as typed, since an expanded mention is a whole URL.
    func plan(
        for destination: HomeDestination,
        sending message: ComposerHandOff.Message,
        choices: TabLaunchChoices?,
        branchPrefix: String,
        branchSuffix: String = WorkspaceProvisioner.randomSuffix()
    ) -> HomeTaskPlan? {
        plan(
            for: destination,
            message: message.blocks.plainText,
            branchSeed: message.typedText,
            images: message.blocks.compactMap { if case .image(let image) = $0 { image } else { nil } },
            choices: choices,
            branchPrefix: branchPrefix,
            branchSuffix: branchSuffix
        )
    }

    /// Nil without a project or with nothing to send.
    func plan(
        for destination: HomeDestination,
        message: String,
        branchSeed: String? = nil,
        images: [ChatImage] = [],
        choices: TabLaunchChoices? = nil,
        branchPrefix: String,
        branchSuffix: String = WorkspaceProvisioner.randomSuffix()
    ) -> HomeTaskPlan? {
        let hasText = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText || !images.isEmpty, let project = project(at: destination.projectPath) else { return nil }
        let repository = project.isRepository ? ProjectRoot.repositoryDirectory(forRoot: project.path) : nil
        let workspace: HomeTaskPlan.Workspace
        switch (destination.workspace, repository) {
        case (.newWorktree, let repository?):
            let branch = WorkspaceProvisioner.suggestedBranchName(
                for: Self.branchSeed(from: branchSeed ?? message), suffix: branchSuffix, prefix: branchPrefix
            )
            workspace = .newWorktree(repository: repository, branch: branch)
        case (.worktree(let path, let branch), let repository?):
            workspace = .existingWorktree(path: path, repository: repository, branch: branch)
        default:
            workspace = .directory(path: project.path, repoPath: repository)
        }
        return HomeTaskPlan(
            groupID: group(id: destination.groupID)?.id,
            workspace: workspace,
            subfolder: repository == nil ? nil : destination.subfolder,
            message: message,
            images: images,
            choices: choices
        )
    }

    /// The message's first line: `slugify` trims it to a branch-sized length.
    static func branchSeed(from message: String) -> String {
        message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}
