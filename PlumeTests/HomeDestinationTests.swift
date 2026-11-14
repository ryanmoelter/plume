import Foundation
import SwiftData
import Testing
@testable import Plume

/// Home's destination picker: it starts on the last selected task's group and
/// project, offers a new worktree only in a repository, defaults the
/// workspace to what the project's latest task ran in, and turns the choice
/// into the parameters the new task is created with.
struct HomeDestinationTests {
    private let work = HomeDestinationCatalog.GroupOption(id: UUID(), name: "Work")
    private let side = HomeDestinationCatalog.GroupOption(id: UUID(), name: "Side")
    private let plume = HomeProject(path: "/repos/plume", isRepository: true)
    private let notes = HomeProject(path: "/docs/notes", isRepository: false)

    private func facts(
        group: UUID?, project: String?, _ kind: WorkspaceKind, id: UUID = UUID()
    ) -> HomeDestinationCatalog.TaskFacts {
        HomeDestinationCatalog.TaskFacts(id: id, groupID: group, projectPath: project, workspaceKind: kind)
    }

    private func catalog(tasks: [HomeDestinationCatalog.TaskFacts] = []) -> HomeDestinationCatalog {
        HomeDestinationCatalog(groups: [work, side], projects: [notes, plume], tasks: tasks)
    }

    // MARK: Group's plurality project

    @Test func aGroupsPluralityProjectIsTheOneMostOfItsTasksRunIn() {
        let tasks = [
            facts(group: work.id, project: notes.path, .directory),
            facts(group: work.id, project: plume.path, .directory),
            facts(group: work.id, project: plume.path, .directory),
            facts(group: side.id, project: notes.path, .directory),
            facts(group: side.id, project: notes.path, .directory),
        ]
        #expect(catalog(tasks: tasks).pluralityProject(inGroup: work.id) == plume)
    }

    @Test func aTieGoesToTheMoreRecentTask() {
        let tasks = [
            facts(group: work.id, project: notes.path, .directory),
            facts(group: work.id, project: plume.path, .directory),
        ]
        #expect(catalog(tasks: tasks).pluralityProject(inGroup: work.id) == notes)
    }

    @Test func aGroupWithNoKnownProjectHasNoPlurality() {
        let tasks = [
            facts(group: work.id, project: nil, .directory),
            facts(group: work.id, project: "/gone", .directory),
            facts(group: side.id, project: plume.path, .directory),
        ]
        #expect(catalog(tasks: tasks).pluralityProject(inGroup: work.id) == nil)
        #expect(catalog(tasks: tasks).pluralityProject(inGroup: nil) == nil)
    }

    @Test func noGroupCountsOnlyUngroupedTasks() {
        let tasks = [
            facts(group: nil, project: notes.path, .directory),
            facts(group: work.id, project: plume.path, .directory),
            facts(group: work.id, project: plume.path, .directory),
        ]
        #expect(catalog(tasks: tasks).pluralityProject(inGroup: nil) == notes)
    }

    // MARK: Defaults

    @Test func startsOnTheRecentTasksGroupAndProject() {
        let recent = facts(group: side.id, project: plume.path, .directory)
        let destination = catalog(tasks: [facts(group: work.id, project: notes.path, .directory), recent])
            .defaultDestination(recentTaskID: recent.id)
        #expect(destination.groupID == side.id)
        #expect(destination.projectPath == plume.path)
    }

    @Test func anUngroupedRecentTaskStartsUngrouped() {
        let recent = facts(group: nil, project: plume.path, .directory)
        #expect(catalog(tasks: [recent]).defaultDestination(recentTaskID: recent.id).groupID == nil)
    }

    @Test func withoutARecentTaskStartsOnTheFirstGroupAndProject() {
        let destination = catalog().defaultDestination(recentTaskID: nil)
        #expect(destination.groupID == work.id)
        #expect(destination.projectPath == notes.path)
        #expect(destination.workspace == .projectFolder)
    }

    @Test func aRecentTaskWithNoKnownProjectFallsBackToTheFirstProject() {
        let recent = facts(group: work.id, project: nil, .unset)
        #expect(catalog(tasks: [recent]).defaultDestination(recentTaskID: recent.id).projectPath == notes.path)
    }

    // MARK: Workspace

    @Test func workspaceFollowsTheProjectsLatestTask() {
        let catalog = catalog(tasks: [
            facts(group: nil, project: plume.path, .worktree),
            facts(group: nil, project: plume.path, .directory),
        ])
        #expect(catalog.defaultWorkspace(forProject: plume.path) == .newWorktree)
    }

    @Test func aTaskWithNoWorkspaceYetDoesNotDecide() {
        let catalog = catalog(tasks: [
            facts(group: nil, project: plume.path, .unset),
            facts(group: nil, project: plume.path, .worktree),
        ])
        #expect(catalog.defaultWorkspace(forProject: plume.path) == .newWorktree)
    }

    @Test func aProjectWithNoTasksUsesItsFolder() {
        #expect(catalog().defaultWorkspace(forProject: plume.path) == .projectFolder)
    }

    @Test func aPlainFolderNeverDefaultsToAWorktree() {
        let catalog = catalog(tasks: [facts(group: nil, project: notes.path, .worktree)])
        #expect(catalog.defaultWorkspace(forProject: notes.path) == .projectFolder)
    }

    @Test func choosingAProjectResetsTheWorkspaceToItsDefault() {
        let catalog = catalog(tasks: [facts(group: nil, project: plume.path, .worktree)])
        let start = HomeDestination(groupID: work.id, projectPath: notes.path, workspace: .projectFolder)
        let chosen = catalog.choosingProject(plume.path, in: start)
        #expect(chosen == HomeDestination(groupID: work.id, projectPath: plume.path, workspace: .newWorktree))
    }

    @Test func validationDropsWhatIsGone() {
        let stale = HomeDestination(groupID: UUID(), projectPath: "/gone", workspace: .newWorktree)
        #expect(catalog().validated(stale) == HomeDestination(groupID: work.id, projectPath: notes.path, workspace: .projectFolder))
    }

    @Test func validationKeepsANoGroupChoice() {
        let destination = HomeDestination(groupID: nil, projectPath: plume.path, workspace: .newWorktree)
        #expect(catalog().validated(destination) == destination)
    }

    // MARK: Plan

    @Test func aProjectFolderPlanRunsInTheProjectRoot() {
        let destination = HomeDestination(groupID: side.id, projectPath: plume.path, workspace: .projectFolder)
        let plan = catalog().plan(for: destination, message: "Fix the build", branchPrefix: "ryanm/")
        #expect(plan == HomeTaskPlan(
            groupID: side.id,
            workspace: .directory(path: plume.path, repoPath: plume.path),
            message: "Fix the build"
        ))
    }

    @Test func aPlainFolderPlanHasNoRepository() {
        let destination = HomeDestination(groupID: nil, projectPath: notes.path, workspace: .projectFolder)
        let plan = catalog().plan(for: destination, message: "Tidy", branchPrefix: "")
        #expect(plan?.workspace == .directory(path: notes.path, repoPath: nil))
        #expect(plan?.groupID == nil)
    }

    @Test func aWorktreePlanNamesItsBranchFromTheFirstLine() {
        let destination = HomeDestination(groupID: work.id, projectPath: plume.path, workspace: .newWorktree)
        let plan = catalog().plan(
            for: destination, message: "Add Home composer\nwith three variants", branchPrefix: "ryanm/", branchSuffix: "beef"
        )
        #expect(plan?.workspace == .newWorktree(repository: plume.path, branch: "ryanm/add-home-composer-beef"))
        #expect(plan?.message == "Add Home composer\nwith three variants")
    }

    @Test func nothingToSendHasNoPlan() {
        let destination = HomeDestination(groupID: nil, projectPath: plume.path, workspace: .projectFolder)
        #expect(catalog().plan(for: destination, message: "  \n ", branchPrefix: "") == nil)
    }

    @Test func noProjectHasNoPlan() {
        let destination = HomeDestination(groupID: nil, projectPath: nil, workspace: .projectFolder)
        #expect(catalog().plan(for: destination, message: "Hi", branchPrefix: "") == nil)
    }

    @Test func anExistingWorktreePlanRunsInThatWorktree() {
        let worktree = HomeWorkspaceChoice.worktree(path: "/repos/plume/.plume/worktrees/fix", branch: "ryanm/fix")
        let destination = HomeDestination(groupID: nil, projectPath: plume.path, workspace: worktree)
        #expect(catalog().validated(destination) == destination)
        #expect(catalog().plan(for: destination, message: "Hi", branchPrefix: "")?.workspace == .existingWorktree(
            path: "/repos/plume/.plume/worktrees/fix", repository: plume.path, branch: "ryanm/fix"
        ))
    }

    @Test func aPlainFolderCannotKeepAWorktreeChoice() {
        let destination = HomeDestination(
            groupID: nil, projectPath: notes.path, workspace: .worktree(path: "/elsewhere", branch: nil)
        )
        #expect(catalog().validated(destination).workspace == .projectFolder)
    }

    // MARK: Worktree listing

    private let listing = HomeWorktreeListing(
        projectPath: "/repos/plume",
        worktrees: [
            GitWorktree(path: "/repos/plume", branch: "main", isMain: true),
            GitWorktree(path: "/repos/plume/.plume/worktrees/fix", branch: "ryanm/fix", isMain: false),
        ],
        branch: "main"
    )

    @Test func theListingOffersEachWorktreeThenANewOne() {
        let fix = HomeWorkspaceChoice.worktree(path: "/repos/plume/.plume/worktrees/fix", branch: "ryanm/fix")
        #expect(listing.choices == [.projectFolder, fix, .newWorktree])
        #expect(listing.choices.map(listing.title(for:)) == ["main", "fix", "New Worktree"])
        #expect(listing.branch(for: fix) == "ryanm/fix")
        #expect(listing.branch(for: .projectFolder) == "main")
        #expect(listing.branch(for: .newWorktree) == nil)
    }

    @Test func aBareLayoutStillOffersTheProjectFolder() {
        let bare = HomeWorktreeListing(
            projectPath: "/repos/bare",
            worktrees: [GitWorktree(path: "/repos/bare/main", branch: "main", isMain: false)],
            branch: nil
        )
        #expect(bare.choices.first == .projectFolder)
        #expect(bare.title(for: .projectFolder) == "Project folder")
    }

    @Test func aRemovedWorktreeFallsBack() {
        let gone = HomeWorkspaceChoice.worktree(path: "/repos/plume/.plume/worktrees/gone", branch: nil)
        #expect(listing.validated(gone, fallback: .newWorktree) == .newWorktree)
        #expect(listing.validated(.projectFolder, fallback: .newWorktree) == .projectFolder)
    }
}

/// Creating the task a plan describes, in a store, without launching it.
@MainActor
struct HomeTaskStarterTests {
    private let context: ModelContext
    private let defaults: UserDefaults

    init() throws {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
        defaults = try #require(UserDefaults(suiteName: "HomeTaskStarterTests-\(UUID().uuidString)"))
    }

    @Test func aDirectoryPlanCreatesAnAgentTaskInItsGroup() throws {
        let group = TaskStore.createGroup(in: context, name: "Work", existing: [])
        let sibling = TaskStore.createTask(in: context, group: group, siblings: [])
        let plan = HomeTaskPlan(
            groupID: group.id, workspace: .directory(path: "/repos/plume", repoPath: "/repos/plume"), message: "Hi"
        )
        let task = HomeTaskStarter.createTask(
            for: plan, directory: "/repos/plume", in: context, recentFolders: defaults
        )
        #expect(task.group?.id == group.id)
        #expect(task.orderIndex == sibling.orderIndex + 1)
        #expect(task.workingDirectoryPath == "/repos/plume")
        #expect(task.repoPath == "/repos/plume")
        #expect(task.workspaceKind == .directory)
        #expect(task.tabs.map(\.kind) == [.agent])
        #expect(task.hasNeverStarted)
        #expect(RecentFolders.load(from: defaults) == ["/repos/plume"])
    }

    @Test func placementCountsOnlyLiveTasksInTheChosenGroup() {
        let group = TaskStore.createGroup(in: context, name: "Work", existing: [])
        let first = TaskStore.createTask(in: context, group: group, siblings: [])
        let second = TaskStore.createTask(in: context, group: group, siblings: [first])
        let archived = TaskStore.createTask(in: context, group: group, siblings: [first, second])
        archived.isArchived = true
        let plan = HomeTaskPlan(
            groupID: group.id, workspace: .directory(path: "/repos/plume", repoPath: nil), message: "Hi"
        )
        let task = HomeTaskStarter.createTask(for: plan, directory: "/repos/plume", in: context, recentFolders: defaults)
        #expect(task.orderIndex == second.orderIndex + 1)
    }

    @Test func aGroupThatNoLongerExistsPlacesTheTaskUngrouped() {
        let ungrouped = TaskStore.createTask(in: context, siblings: [])
        let plan = HomeTaskPlan(
            groupID: UUID(), workspace: .directory(path: "/repos/plume", repoPath: nil), message: "Hi"
        )
        let task = HomeTaskStarter.createTask(for: plan, directory: "/repos/plume", in: context, recentFolders: defaults)
        #expect(task.group == nil)
        #expect(task.orderIndex == ungrouped.orderIndex + 1)
    }

    @Test func aWorktreePlanRecordsTheBranchAndRepository() {
        let plan = HomeTaskPlan(
            groupID: nil, workspace: .newWorktree(repository: "/repos/plume", branch: "ryanm/x-beef"), message: "Hi"
        )
        let task = HomeTaskStarter.createTask(
            for: plan, directory: "/repos/plume/.plume/worktrees/ryanm-x-beef",
            in: context, recentFolders: defaults
        )
        #expect(task.group == nil)
        #expect(task.workingDirectoryPath == "/repos/plume/.plume/worktrees/ryanm-x-beef")
        #expect(task.repoPath == "/repos/plume")
        #expect(task.branchName == "ryanm/x-beef")
        #expect(task.workspaceKind == .worktree)
        #expect(RecentFolders.load(from: defaults) == ["/repos/plume"])
    }

    @Test func anExistingWorktreePlanRecordsItsBranch() {
        let path = "/repos/plume/.plume/worktrees/fix"
        let plan = HomeTaskPlan(
            groupID: nil,
            workspace: .existingWorktree(path: path, repository: "/repos/plume", branch: "ryanm/fix"),
            message: "Hi"
        )
        let task = HomeTaskStarter.createTask(
            for: plan, directory: path, in: context, recentFolders: defaults
        )
        #expect(task.workingDirectoryPath == path)
        #expect(task.repoPath == "/repos/plume")
        #expect(task.branchName == "ryanm/fix")
        #expect(task.workspaceKind == .worktree)
    }
}
