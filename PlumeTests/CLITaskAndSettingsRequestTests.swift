import AppKit
import Foundation
import SwiftData
import Testing

@testable import Plume

/// `task.new` opens a task on an existing worktree, in the caller's group,
/// with the repository and branch read from git, and refuses a path that is
/// not a checkout's root. `settings.open` selects the named pane and shows
/// the Settings window.
@MainActor
struct CLITaskAndSettingsRequestTests {
    private let context: ModelContext
    private let scratch: String

    init() throws {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
        scratch = FileManager.default.temporaryDirectory.appending(path: "plume-task-new-\(UUID().uuidString)").path
    }

    /// A repository at `<scratch>/repo` with a worktree on `ryanm/feature` at
    /// `<scratch>/feature`.
    nonisolated private static func makeRepositoryWithWorktree(in scratch: String) throws -> (repository: String, worktree: String) {
        let repository = "\(scratch)/repo"
        let worktree = "\(scratch)/feature"
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        try GitRunner.run(["init", "-b", "main"], in: repository)
        try GitRunner.run(["config", "user.email", "test@example.com"], in: repository)
        try GitRunner.run(["config", "user.name", "Test"], in: repository)
        try GitRunner.run(["config", "commit.gpgsign", "false"], in: repository)
        try "hello\n".write(toFile: "\(repository)/README.md", atomically: true, encoding: .utf8)
        try GitRunner.run(["add", "."], in: repository)
        try GitRunner.run(["commit", "-m", "init"], in: repository)
        try GitRunner.run(["worktree", "add", "-b", "ryanm/feature", worktree], in: repository)
        return (repository, worktree)
    }

    /// Off the main actor, which the socket tests running alongside need free.
    private func makeRepositoryWithWorktree() async throws -> (repository: String, worktree: String) {
        let scratch = scratch
        return try await Task.detached { try Self.makeRepositoryWithWorktree(in: scratch) }.value
    }

    private func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func makeHandler(
        tasks: [WorkTask],
        revealed: @escaping (UUID) -> Void = { _ in },
        openedSettings: @escaping () -> Void = {}
    ) -> CLICommandHandler {
        let handler = CLICommandHandler()
        handler.orderedWindows = { [] }
        handler.activateApp = {}
        handler.registerWindow(UUID(), .init(
            window: { nil },
            task: { id in tasks.first { $0.id == id } },
            taskIDForTab: { tabID in tasks.first { $0.tabs.contains { $0.id == tabID } }?.id },
            context: context,
            reveal: revealed,
            openSettings: openedSettings
        ))
        return handler
    }

    private func allTasks() throws -> [WorkTask] {
        try context.fetch(FetchDescriptor<WorkTask>())
    }

    @Test func aWorktreeOpensAsATaskInTheCallersGroup() async throws {
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let (repository, worktree) = try await makeRepositoryWithWorktree()
        let group = TaskStore.createGroup(in: context, existing: [])
        let caller = TaskStore.createTask(in: context, group: group, siblings: [])
        let callerTab = try #require(caller.tabs.first)
        var revealed: [UUID] = []
        let handler = makeHandler(tasks: [caller]) { revealed.append($0) }

        let response = await handler.handle(.newTask(.init(worktreePath: worktree, tabID: callerTab.id, select: true)))

        #expect(response.error == nil)
        let taskID = try #require(response.taskID)
        let task = try #require(try allTasks().first { $0.id == taskID })
        #expect(task.group?.id == group.id)
        #expect(task.orderIndex == caller.orderIndex + 1)
        #expect(task.workspaceKind == .worktree)
        #expect(task.workingDirectoryPath == worktree)
        #expect(task.repoPath.map(resolved) == resolved(repository))
        #expect(task.branchName == "ryanm/feature")
        #expect(task.title == "feature")
        #expect(task.tabs.count == 1)
        #expect(revealed == [taskID])
    }

    @Test func anUnknownCallerOpensTheTaskOutsideAnyGroup() async throws {
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let (_, worktree) = try await makeRepositoryWithWorktree()
        let group = TaskStore.createGroup(in: context, existing: [])
        let other = TaskStore.createTask(in: context, group: group, siblings: [])
        var revealed = false
        let handler = makeHandler(tasks: [other]) { _ in revealed = true }

        let response = await handler.handle(.newTask(.init(worktreePath: worktree, taskID: UUID(), select: false)))

        let task = try #require(try allTasks().first { $0.id == response.taskID })
        #expect(task.group == nil)
        #expect(!revealed)
    }

    /// Deleting a worktree task offers to remove the worktree, which must
    /// never happen to the main checkout.
    @Test func theMainCheckoutOpensAsADirectoryTask() async throws {
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let (repository, _) = try await makeRepositoryWithWorktree()
        let handler = makeHandler(tasks: [])

        let response = await handler.handle(.newTask(.init(worktreePath: repository, select: false)))

        let task = try #require(try allTasks().first { $0.id == response.taskID })
        #expect(task.workspaceKind == .directory)
        #expect(task.branchName == "main")
    }

    /// In the `.bare` layout the project folder is no repository, so the task
    /// records `.bare`, which every consumer of `repoPath` can run git in. A
    /// new worktree still lands beside `.bare`, as `plume wt` puts it.
    @Test func aBareLayoutWorktreeRecordsARepositoryEveryConsumerCanUse() async throws {
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let scratch = scratch
        let (project, worktree) = try await Task.detached {
            let source = "\(scratch)/source"
            let project = "\(scratch)/project"
            let worktree = "\(project)/feature"
            try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
            try GitRunner.run(["init", "-b", "main"], in: source)
            try GitRunner.run(
                ["-c", "user.email=test@example.com", "-c", "user.name=Test", "-c", "commit.gpgsign=false",
                 "commit", "--allow-empty", "-m", "init"],
                in: source
            )
            try GitRunner.run(["clone", "--bare", source, "\(project)/.bare"], in: scratch)
            try GitRunner.run(["worktree", "add", "-b", "feature", worktree], in: "\(project)/.bare")
            return (project, worktree)
        }.value
        let handler = makeHandler(tasks: [])

        let response = await handler.handle(.newTask(.init(worktreePath: worktree, select: false)))

        let task = try #require(try allTasks().first { $0.id == response.taskID })
        #expect(task.workspaceKind == .worktree)
        let repository = try #require(task.repoPath)
        #expect(resolved(repository) == resolved("\(project)/.bare"))

        let listing = await GitService.shared.worktreeListing(in: repository)
        #expect(listing.worktrees.map { resolved($0.path) } == [resolved(worktree)])
        #expect(listing.branch == "main")

        let created = try await GitService.shared.createWorktree(repository: repository, branch: "next", basePath: nil)
        #expect(resolved(created) == resolved("\(project)/next"))

        let branches = try await Task.detached {
            try WorkspaceProvisioner.removeWorktree(repository: repository, path: worktree, branch: "feature", deleteBranch: true)
            try WorkspaceProvisioner.removeWorktree(repository: repository, path: created, branch: "next", deleteBranch: true)
            return try GitRunner.run(["branch", "--format=%(refname:short)"], in: "\(project)/.bare")
        }.value
        #expect(!FileManager.default.fileExists(atPath: worktree))
        #expect(!FileManager.default.fileExists(atPath: created))
        #expect(branches.trimmingCharacters(in: .whitespacesAndNewlines) == "main")
    }

    /// A client that timed out retries, and the retry must not open a second
    /// task on the worktree.
    @Test func aWorktreeThatAlreadyHasATaskReturnsThatTask() async throws {
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let (_, worktree) = try await makeRepositoryWithWorktree()
        var revealed: [UUID] = []
        let handler = makeHandler(tasks: []) { revealed.append($0) }

        let first = await handler.handle(.newTask(.init(worktreePath: worktree, select: false)))
        let retry = await handler.handle(.newTask(.init(worktreePath: worktree + "/", select: true)))

        let taskID = try #require(first.taskID)
        #expect(retry.error == nil)
        #expect(retry.taskID == taskID)
        #expect(try allTasks().count == 1)
        #expect(revealed == [taskID])
    }

    @Test func aPathThatIsNotAWorktreeRootIsRefused() async throws {
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let (_, worktree) = try await makeRepositoryWithWorktree()
        let plain = "\(scratch)/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let subdirectory = "\(worktree)/sub"
        try FileManager.default.createDirectory(atPath: subdirectory, withIntermediateDirectories: true)
        let handler = makeHandler(tasks: [])

        let relative = await handler.handle(.newTask(.init(worktreePath: "feature", select: false)))
        #expect(relative.error == "worktreePath must be an absolute path: feature")
        let missing = await handler.handle(.newTask(.init(worktreePath: "\(scratch)/missing", select: false)))
        #expect(missing.error == "no such directory: \(scratch)/missing")
        let notGit = await handler.handle(.newTask(.init(worktreePath: plain, select: false)))
        #expect(notGit.error == "not a git worktree: \(plain)")
        let inside = await handler.handle(.newTask(.init(worktreePath: subdirectory, select: false)))
        #expect(inside.error == "not a git worktree: \(subdirectory)")
        #expect(try allTasks().isEmpty)
    }

    @Test func aNewTaskNeedsAnOpenWindow() async throws {
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let (_, worktree) = try await makeRepositoryWithWorktree()
        let handler = CLICommandHandler()
        handler.orderedWindows = { [] }

        let response = await handler.handle(.newTask(.init(worktreePath: worktree, select: false)))

        #expect(response.error == "no Plume window is open")
    }

    @Test func openingSettingsSelectsTheNamedPane() async throws {
        let suite = "plume-settings-open-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var opened = 0
        var activated = 0
        let handler = makeHandler(tasks: []) { opened += 1 }
        handler.settingsDefaults = defaults
        handler.activateApp = { activated += 1 }

        #expect(await handler.handle(.openSettings(.init(section: "projects"))).ok)
        #expect(defaults.string(forKey: SettingsPane.selectionKey) == SettingsPane.projects.rawValue)

        defaults.set(SettingsPane.agents.rawValue, forKey: SettingsPane.selectionKey)
        #expect(await handler.handle(.openSettings(.init(section: nil))).ok)
        #expect(defaults.string(forKey: SettingsPane.selectionKey) == SettingsPane.agents.rawValue)
        #expect(opened == 2)
        #expect(activated == 2)

        let unknown = await handler.handle(.openSettings(.init(section: "nope")))
        #expect(unknown.error == "no settings section nope")
        #expect(opened == 2)
    }
}
