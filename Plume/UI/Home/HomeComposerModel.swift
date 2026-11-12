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

/// Where Home's composer starts a task, and the send that starts it there.
@Observable @MainActor
final class HomeComposerModel {
    /// Maps each folder to its project, or to nil for a folder that no longer
    /// exists. Blocks on `git`, so it runs off the main actor.
    typealias Resolver = @Sendable ([String]) -> [String: HomeProject?]

    private(set) var catalog = HomeDestinationCatalog()
    var destination = HomeDestination(groupID: nil, projectPath: nil, workspace: .projectFolder)
    private(set) var isStarting = false
    var errorMessage: String?

    @ObservationIgnored private var hasDefaulted = false
    @ObservationIgnored private var lastInputs: HomeComposerInputs?
    /// Only the latest refresh publishes; an older one finishing late would
    /// put back what a newer one already replaced.
    @ObservationIgnored private var refreshCount = 0
    @ObservationIgnored private var resolvedProjects: [String: HomeProject?] = [:]
    @ObservationIgnored private var addedFolders: [String] = []
    @ObservationIgnored private let resolve: Resolver
    @ObservationIgnored private let configuredFolders: @MainActor () -> [String]

    init(
        resolve: @escaping Resolver = HomeComposerModel.resolveWithGit,
        configuredFolders: @escaping @MainActor () -> [String] = {
            Array(AppSettings.shared.projectsConfiguration.repositories.keys) + RecentFolders.load()
        }
    ) {
        self.resolve = resolve
        self.configuredFolders = configuredFolders
    }

    var canStart: Bool {
        !isStarting && catalog.project(at: destination.projectPath) != nil
    }

    var group: HomeDestinationCatalog.GroupOption? {
        catalog.group(id: destination.groupID)
    }

    var groupTitle: String {
        group?.name ?? HomeDestinationCatalog.noGroupTitle
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

    /// Only a folder git tracks offers a subfolder, as on the new
    /// conversation screen.
    var offersSubfolders: Bool { offersWorktrees }

    var subfolderTitle: String {
        destination.subfolder ?? ProjectSubfolder.rootTitle
    }

    /// The checkout whose folders the subfolder menu lists. A new worktree
    /// does not exist yet, so the project's own folder stands in for it.
    var subfolderCheckout: String? {
        guard offersSubfolders else { return nil }
        if case .worktree(let path, _) = destination.workspace { return path }
        return destination.projectPath
    }

    /// The folders directly inside `subfolderCheckout`.
    private(set) var subfolderChoices: [String] = []

    func loadSubfolders() async {
        guard let checkout = subfolderCheckout else {
            subfolderChoices = []
            return
        }
        let choices = await Task.detached { ProjectSubfolder.childFolders(of: checkout) }.value
        guard !Task.isCancelled, subfolderCheckout == checkout else { return }
        subfolderChoices = choices
    }

    func chooseSubfolder(_ subfolder: String?) {
        guard offersSubfolders else { return }
        destination.subfolder = subfolder.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A folder from the open panel. One outside the checkout is another
    /// project, as it is on the new conversation screen.
    func chooseSubfolder(atPath path: String) async {
        if let checkout = subfolderCheckout,
           let subfolder = ProjectSubfolder.relativePath(of: path, in: checkout) {
            chooseSubfolder(subfolder)
        } else {
            await addFolder(path)
        }
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
        if let project = catalog.pluralityProject(inGroup: id), project.path != destination.projectPath {
            chooseProject(project.path)
        }
    }

    func chooseProject(_ path: String) {
        destination = catalog.choosingProject(path, in: destination)
    }

    func chooseWorkspace(_ choice: HomeWorkspaceChoice) {
        guard workspaceChoices.contains(choice) else { return }
        destination.workspace = choice
    }

    /// Resolves every folder to its project off the main actor, then rebuilds
    /// the catalog. Every refresh resolves again, so a folder deleted or made
    /// a repository since the last one is seen; until it finishes, the last
    /// catalog stays up. The first load, and one that `picksDefaults`, picks
    /// the defaults; others only keep the current choice valid.
    func refresh(_ inputs: HomeComposerInputs, recentTaskID: UUID?, picksDefaults: Bool = false) async {
        if picksDefaults { hasDefaulted = false }
        lastInputs = inputs
        refreshCount += 1
        let thisRefresh = refreshCount
        let paths = Set(inputs.tasks.compactMap(\.path) + configuredFolders() + addedFolders)
        let resolve = resolve
        let resolved = await Task.detached { resolve(Array(paths)) }.value
        guard !Task.isCancelled, thisRefresh == refreshCount else { return }
        resolvedProjects = resolved
        catalog = catalog(inputs: inputs)
        if hasDefaulted {
            destination = catalog.validated(destination)
        } else {
            destination = catalog.defaultDestination(recentTaskID: recentTaskID)
            hasDefaulted = true
        }
    }

    /// A folder chosen from the open panel, for a project no task uses yet.
    func addFolder(_ path: String) async {
        addedFolders.append(path)
        guard let inputs = lastInputs else { return }
        await refresh(inputs, recentTaskID: nil)
        guard let project = resolvedProjects[path] ?? nil else { return }
        chooseProject(project.path)
    }

    /// Clears the error and reports a failure back through it, so the caller
    /// only has to put the text back.
    func start(
        _ message: ComposerHandOff.Message,
        choices: TabLaunchChoices,
        in context: ModelContext
    ) async -> WorkTask? {
        guard canStart else { return nil }
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }
        let destination = destination
        let catalog = catalog
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
            return try await HomeTaskStarter.start(plan, in: context)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func catalog(inputs: HomeComposerInputs) -> HomeDestinationCatalog {
        let projects = Set(resolvedProjects.values.compactMap { $0 }).sorted {
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

    nonisolated static func resolveWithGit(_ paths: [String]) -> [String: HomeProject?] {
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
        self.groups = groups.map {
            HomeDestinationCatalog.GroupOption(id: $0.id, name: $0.name, tintRaw: $0.tintRaw, iconName: $0.iconName)
        }
        self.tasks = tasks.map { task in
            let workspace = TabDirectoryStore.savedWorkspaceSource(in: task)?.workspace
            return TaskInput(
                id: task.id,
                groupID: task.group?.id,
                path: workspace?.repoPath ?? workspace?.directory,
                workspaceKindRaw: (workspace?.kind ?? .unset).rawValue,
                createdAt: task.createdAt
            )
        }
    }
}
