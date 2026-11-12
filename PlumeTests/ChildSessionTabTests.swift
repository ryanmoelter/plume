import Foundation
import SwiftData
import Testing
@testable import Plume

/// A child session's tab opens after its parent's other children, unselected,
/// and the sidebar nests it one level under the parent. Its workspace is its
/// own worktree, which the task then owns, or the parent's folder.
@MainActor
struct ChildSessionTabTests {
    private let context: ModelContext

    init() throws {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
    }

    private func makeTask() throws -> (WorkTask, parent: TaskTab) {
        let task = TaskStore.createTask(in: context, siblings: [])
        let parent = try #require(task.tabs.first)
        parent.workspace = .directory("/repo")
        return (task, parent)
    }

    @Test func childrenOpenAfterTheParentsOtherChildrenWithoutTakingSelection() throws {
        let (task, parent) = try makeTask()
        let after = TaskStore.addTab(to: task, kind: .terminal, in: context)
        TaskStore.selectTab(parent, in: task)

        let first = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let second = TaskStore.addChildTab(to: task, parent: parent, in: context)

        #expect(task.tabs(inPane: 0).map(\.id) == [parent.id, first.id, second.id, after.id])
        #expect(task.tabs(inPane: 0).map(\.orderIndex) == [0, 1, 2, 3])
        #expect(task.selectedTabID == parent.id)
        #expect(first.parentTabID == parent.id)
        #expect(first.transport == .headless)
        #expect(first.provider == .claudeCode)
    }

    @Test func aParentWithChildrenLaunchesWithTheirNotesFolder() throws {
        let task = TaskStore.createTask(in: context, siblings: [])
        let parent = try #require(task.tabs.first)
        #expect(ChildSessionCoordinator.launchDirectories(for: parent).isEmpty)

        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)

        #expect(ChildSessionCoordinator.launchDirectories(for: parent) == [AppPaths.sideSessionNotesDirectory(parentTabID: parent.id).path])
        #expect(ChildSessionCoordinator.launchDirectories(for: child).isEmpty)
    }

    @Test func theInsertionPointFollowsTheLastChild() {
        let parent = UUID(), other = UUID(), child = UUID()
        #expect(TaskStore.childInsertionIndex(parentID: parent, in: [(parent, nil), (other, nil)]) == 1)
        #expect(TaskStore.childInsertionIndex(parentID: parent, in: [(parent, nil), (other, nil), (child, parent)]) == 3)
        #expect(TaskStore.childInsertionIndex(parentID: parent, in: [(other, nil)]) == 1)
    }

    @Test func nestingMovesChildrenUnderTheirParent() {
        struct Row { let id: UUID; let parent: UUID? }
        let parent = Row(id: UUID(), parent: nil)
        let sibling = Row(id: UUID(), parent: nil)
        let child = Row(id: UUID(), parent: parent.id)
        let orphan = Row(id: UUID(), parent: UUID())

        let nested = TaskStore.nestedByParent([parent, sibling, child, orphan], id: \.id, parentID: \.parent)

        #expect(nested.map(\.item.id) == [parent.id, child.id, sibling.id, orphan.id])
        #expect(nested.map(\.depth) == [0, 1, 0, 0])
    }

    @Test func aParentCycleStillListsEveryTab() {
        struct Row { let id: UUID; var parent: UUID? }
        let a = UUID(), b = UUID()
        let nested = TaskStore.nestedByParent([Row(id: a, parent: b), Row(id: b, parent: a)], id: \.id, parentID: \.parent)
        #expect(Set(nested.map(\.item.id)) == [a, b])
    }

    @Test func useWorktreeFollowsTheParentUnlessAsked() {
        #expect(ChildSessionWorkspace.usesWorktree(requested: nil, parentIsWorktree: true))
        #expect(!ChildSessionWorkspace.usesWorktree(requested: nil, parentIsWorktree: false))
        #expect(ChildSessionWorkspace.usesWorktree(requested: true, parentIsWorktree: false))
        #expect(!ChildSessionWorkspace.usesWorktree(requested: false, parentIsWorktree: true))
    }

    @Test func aChildsWorktreeIsRecordedAsOwnedByTheTask() throws {
        let (task, parent) = try makeTask()
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        let worktree = ChildSessionWorkspace.Worktree(path: "/repo/.plume/worktrees/fix", repository: "/repo", branch: "me/fix-1a2b")

        ChildSessionWorkspace.apply(worktree, to: child, parent: parent)
        #expect(task.ownedWorktrees.isEmpty)
        ChildSessionWorkspace.recordOwnership(of: worktree, in: task)

        #expect(child.workspace == TabWorkspace(kind: .worktree, directory: worktree.path, repoPath: "/repo", branchName: "me/fix-1a2b"))
        #expect(task.ownedWorktrees == [OwnedWorktree(path: worktree.path, repoPath: "/repo", branch: "me/fix-1a2b")])
    }

    @Test func withoutAWorktreeTheChildSharesTheParentsFolder() throws {
        let (task, parent) = try makeTask()
        let child = TaskStore.addChildTab(to: task, parent: parent, in: context)
        child.workspace = TabWorkspace()

        ChildSessionWorkspace.apply(nil, to: child, parent: parent)

        #expect(child.workspace.directory == "/repo")
        #expect(task.ownedWorktrees.isEmpty)
    }

    private func makeRepository() throws -> String {
        let repository = FileManager.default.temporaryDirectory.appending(path: "plume-child-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        for arguments in [
            ["init", "-b", "main"], ["config", "user.email", "test@example.com"], ["config", "user.name", "Test"],
            ["config", "commit.gpgsign", "false"], ["commit", "--allow-empty", "-m", "one"]
        ] { try GitRunner.run(arguments, in: repository) }
        return repository
    }

    private static func realPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    @Test func aWorktreeIsCutFromTheParentsHeadInTheParentsSubfolder() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let parentPath = try WorkspaceProvisioner.createWorktree(repository: repository, branch: "parent-branch")
        let sub = (parentPath as NSString).appendingPathComponent("app/src")
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: sub).appending(path: "file.txt"))
        try GitRunner.run(["add", "."], in: parentPath)
        try GitRunner.run(["commit", "-m", "parent's own"], in: parentPath)
        let parentHead = try GitRunner.run(["rev-parse", "HEAD"], in: parentPath).trimmingCharacters(in: .whitespacesAndNewlines)

        let (_, parent) = try makeTask()
        parent.workspace = TabWorkspace(kind: .worktree, directory: sub, repoPath: "/somewhere/stale", branchName: "parent-branch")
        let request = try StartSessionRequest.parse([
            "title": .string("Child"), "prompt": .string("p"), "initiation": .string("user_asked"), "name": .string("kid")
        ]).get()

        let worktree = try #require(try await ChildSessionWorkspace.worktree(for: request, parent: parent).get())

        let childHead = try GitRunner.run(["rev-parse", "HEAD"], in: worktree.path).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(childHead == parentHead)
        #expect(worktree.branch.contains("kid-"))
        #expect(Self.realPath(worktree.repository) == Self.realPath(repository))
        #expect(worktree.workingDirectory == (worktree.path as NSString).appendingPathComponent("app/src"))
    }

    @Test func aSubfolderIsRelativeToTheCheckoutRoot() {
        #expect(ChildSessionWorkspace.subfolder(of: "/r/a/b", in: "/r") == "a/b")
        #expect(ChildSessionWorkspace.subfolder(of: "/r", in: "/r") == nil)
        #expect(ChildSessionWorkspace.subfolder(of: "/rx/a", in: "/r") == nil)
    }

    /// A temporary folder is one Claude Code has never been told to trust,
    /// so the launch fails its pre-flight without spawning `claude`.
    @Test func aChildThatCannotLaunchLeavesNoTabAndNoWorktree() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let (task, parent) = try makeTask()
        parent.workspace = .directory(repository)
        parent.permissionMode = .manual
        let request = try StartSessionRequest.parse([
            "title": .string("Child"), "prompt": .string("p"), "initiation": .string("user_asked"),
            "name": .string("kid"), "use_worktree": .bool(true)
        ]).get()

        let result = await ChildSessionCoordinator.shared.startSession(request, from: parent)

        guard case .failure(let error) = result else {
            Issue.record("expected the start to fail")
            return
        }
        #expect(error.message.hasPrefix("The session could not start: "))
        #expect(task.liveTabs.map(\.id) == [parent.id])
        #expect(task.ownedWorktrees.isEmpty)
        let worktrees = try GitRunner.run(["worktree", "list", "--porcelain"], in: repository)
        #expect(!worktrees.contains("kid-"))
        let branches = try GitRunner.run(["branch", "--list"], in: repository)
        #expect(!branches.contains("kid-"))
    }
}
