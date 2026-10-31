import Foundation
import Observation
import SwiftData

/// The tasks and groups Home's destination pickers are built from. Hashable,
/// so a view reloads the catalog only when one of them changes.
nonisolated struct HomeComposerInputs: Hashable, Sendable {
    struct TaskInput: Hashable, Sendable {
        let id: UUID
        let groupID: UUID?
        /// The repository, else the working directory.
        let path: String?
        let workspaceKindRaw: String
        let createdAt: Date
    }

    var groups: [HomeDestinationCatalog.GroupOption]
    var tasks: [TaskInput]
}

/// The destination every picker variant shares, and the send that starts a
/// task there.
@Observable @MainActor
final class HomeComposerModel {
    private(set) var catalog = HomeDestinationCatalog()
    var destination = HomeDestination(groupID: nil, projectPath: nil, workspace: .projectFolder)
    private(set) var isStarting = false
    var errorMessage: String?

    @ObservationIgnored private var hasDefaulted = false
    @ObservationIgnored private var lastInputs: HomeComposerInputs?
    /// Kept across Home's mounts, so returning to Home does not run `git`
    /// for every task again. A nil entry is a folder that no longer exists.
    private static var resolvedProjects: [String: HomeProject?] = [:]
    private static var addedFolders: [String] = []

    var canStart: Bool {
        !isStarting && catalog.project(at: destination.projectPath) != nil
    }

    var groupTitle: String {
        catalog.group(id: destination.groupID)?.name ?? HomeDestinationCatalog.noGroupTitle
    }

    var projectTitle: String {
        catalog.project(at: destination.projectPath)?.name ?? "Choose project"
    }

    /// The project's worktrees once `git` has listed them.
    private(set) var worktreeListing: HomeWorktreeListing?

    private var currentListing: HomeWorktreeListing? {
        worktreeListing.flatMap { $0.projectPath == destination.projectPath ? $0 : nil }
    }

    /// Only a repository has worktrees to choose among.
    var offersWorktrees: Bool {
        catalog.project(at: destination.projectPath)?.isRepository ?? false
    }

    var workspaceTitle: String {
        currentListing?.title(for: destination.workspace) ?? destination.workspace.title
    }

    func workspaceTitle(for choice: HomeWorkspaceChoice) -> String {
        currentListing?.title(for: choice) ?? choice.title
    }

    /// The branch the chosen worktree has out; nil for a new one.
    var workspaceBranch: String? { workspaceBranch(for: destination.workspace) }

    func workspaceBranch(for choice: HomeWorkspaceChoice) -> String? {
        currentListing?.branch(for: choice)
    }

    var workspaceChoices: [HomeWorkspaceChoice] {
        guard offersWorktrees else { return [.projectFolder] }
        return currentListing?.choices ?? [.projectFolder, .newWorktree]
    }

    /// Lists the chosen project's worktrees, and drops a chosen one that has
    /// since gone.
    func loadWorktrees() async {
        guard let project = catalog.project(at: destination.projectPath), project.isRepository else { return }
        let listing = await GitService.shared.worktreeListing(
            in: ProjectRoot.repositoryDirectory(forRoot: project.path)
        )
        guard !Task.isCancelled, destination.projectPath == project.path else { return }
        let loaded = HomeWorktreeListing(projectPath: project.path, worktrees: listing.worktrees, branch: listing.branch)
        worktreeListing = loaded
        destination.workspace = loaded.validated(
            destination.workspace, fallback: catalog.defaultWorkspace(forProject: project.path)
        )
    }

    func chooseGroup(_ id: UUID?) {
        destination.groupID = id
    }

    func chooseProject(_ path: String) {
        destination = catalog.choosingProject(path, in: destination)
    }

    func chooseWorkspace(_ choice: HomeWorkspaceChoice) {
        guard workspaceChoices.contains(choice) else { return }
        destination.workspace = choice
    }

    /// Resolves each task's folder to its project off the main actor, then
    /// rebuilds the catalog. The first load picks the defaults; later ones
    /// only keep the current choice valid.
    func refresh(_ inputs: HomeComposerInputs, recentTaskID: UUID?) async {
        lastInputs = inputs
        let configured = Array(AppSettings.shared.projectsConfiguration.repositories.keys)
        let paths = Set(inputs.tasks.compactMap(\.path) + configured + RecentFolders.load() + Self.addedFolders)
        let unresolved = paths.filter { Self.resolvedProjects[$0] == nil }
        if !unresolved.isEmpty {
            let resolved = await Task.detached { Self.resolve(Array(unresolved)) }.value
            Self.resolvedProjects.merge(resolved) { _, new in new }
        }
        guard !Task.isCancelled, lastInputs == inputs else { return }
        catalog = Self.catalog(inputs: inputs, paths: paths)
        if hasDefaulted {
            destination = catalog.validated(destination)
        } else {
            destination = catalog.defaultDestination(recentTaskID: recentTaskID)
            hasDefaulted = true
        }
    }

    /// A folder chosen from the open panel, for a project no task uses yet.
    func addFolder(_ path: String) async {
        Self.addedFolders.append(path)
        let resolved = await Task.detached { Self.resolve([path]) }.value
        Self.resolvedProjects.merge(resolved) { _, new in new }
        guard let inputs = lastInputs, let project = resolved[path] ?? nil else { return }
        let paths = Set(inputs.tasks.compactMap(\.path) + Array(Self.resolvedProjects.keys))
        catalog = Self.catalog(inputs: inputs, paths: paths)
        chooseProject(project.path)
    }

    /// Clears the error and reports a failure back through it, so the caller
    /// only has to put the text back.
    func start(
        _ message: ComposerHandOff.Message,
        choices: TabLaunchChoices,
        in context: ModelContext,
        groups: [TaskGroup],
        tasks: [WorkTask]
    ) async -> WorkTask? {
        guard canStart else { return nil }
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }
        var prefix = WorkspaceProvisioner.defaultBranchPrefix
        if destination.workspace == .newWorktree, let project = catalog.project(at: destination.projectPath),
           project.isRepository {
            prefix = await GitService.shared.configuredBranchPrefix(
                in: ProjectRoot.repositoryDirectory(forRoot: project.path),
                configuration: AppSettings.shared.projectsConfiguration
            ) ?? prefix
        }
        guard let plan = catalog.plan(for: destination, sending: message, choices: choices, branchPrefix: prefix) else {
            return nil
        }
        do {
            return try await HomeTaskStarter.start(plan, in: context, groups: groups, tasks: tasks)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private static func catalog(inputs: HomeComposerInputs, paths: Set<String>) -> HomeDestinationCatalog {
        let projects = Set(paths.compactMap { resolvedProjects[$0] ?? nil }).sorted {
            ($0.name.lowercased(), $0.path) < ($1.name.lowercased(), $1.path)
        }
        let tasks = inputs.tasks.sorted { $0.createdAt > $1.createdAt }.map { input in
            HomeDestinationCatalog.TaskFacts(
                id: input.id,
                groupID: input.groupID,
                projectPath: input.path.flatMap { resolvedProjects[$0] ?? nil }?.path,
                workspaceKind: WorkspaceKind(rawValue: input.workspaceKindRaw) ?? .unset
            )
        }
        return HomeDestinationCatalog(groups: inputs.groups, projects: projects, tasks: tasks)
    }

    /// Blocks on `git` for each path.
    nonisolated private static func resolve(_ paths: [String]) -> [String: HomeProject?] {
        var result: [String: HomeProject?] = [:]
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else {
                result[path] = .some(nil)
                continue
            }
            if let root = ProjectRoot.containing(path) {
                result[path] = HomeProject(path: root, isRepository: true)
            } else {
                result[path] = HomeProject(path: path, isRepository: false)
            }
        }
        return result
    }
}

extension HomeComposerInputs {
    @MainActor
    init(tasks: [WorkTask], groups: [TaskGroup]) {
        self.groups = groups.map { HomeDestinationCatalog.GroupOption(id: $0.id, name: $0.name) }
        self.tasks = tasks.map { task in
            TaskInput(
                id: task.id,
                groupID: task.group?.id,
                path: task.repoPath ?? task.workingDirectoryPath,
                workspaceKindRaw: task.workspaceKindRaw,
                createdAt: task.createdAt
            )
        }
    }
}
