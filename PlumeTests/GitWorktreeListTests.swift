import Foundation
import SwiftData
import Testing
@testable import Plume

/// `GitRunner.worktrees(in:)` against real repositories: ordering, the main
/// worktree flag, branch-ref stripping, and the non-repo fallback.
struct GitWorktreeListTests {
    private func makeRepository() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "plume-worktrees-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try GitRunner.run(["init", "-b", "main"], in: path)
        try GitRunner.run(["config", "user.email", "test@example.com"], in: path)
        try GitRunner.run(["config", "user.name", "Test"], in: path)
        // The user's global config signs commits; the signer is unreachable
        // from a test host and would hang for 60s before failing.
        try GitRunner.run(["config", "commit.gpgsign", "false"], in: path)
        try "hello\n".write(toFile: "\(path)/README.md", atomically: true, encoding: .utf8)
        try GitRunner.run(["add", "."], in: path)
        try GitRunner.run(["commit", "-m", "init"], in: path)
        return path
    }

    @Test func aFreshRepositoryListsOnlyItsOwnCheckout() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }

        let worktrees = GitRunner.worktrees(in: repository)

        #expect(worktrees.count == 1)
        #expect(worktrees.first?.isMain == true)
        #expect(worktrees.first?.branch == "main")
    }

    @Test func addedWorktreesFollowTheMainOneWithBranchRefsStripped() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let added = try WorkspaceProvisioner.createWorktree(
            repository: repository, branch: "plume/feature-0001"
        )

        let worktrees = GitRunner.worktrees(in: repository)

        #expect(worktrees.count == 2)
        #expect(worktrees[0].isMain)
        #expect(worktrees[1].isMain == false)
        #expect(worktrees[1].branch == "plume/feature-0001")
        // `git` reports resolved paths; the temp directory is a symlink.
        #expect(URL(fileURLWithPath: worktrees[1].path).resolvingSymlinksInPath()
            == URL(fileURLWithPath: added).resolvingSymlinksInPath())
    }

    @Test func aDirectoryOutsideAnyRepositoryListsNothing() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "plume-not-a-repo-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(GitRunner.worktrees(in: path).isEmpty)
    }
}

struct RecentFoldersTests {
    /// A suite of its own per test, so a list written here never meets the
    /// shared defaults — which the app's own launch migration also writes.
    private func withStoredList(_ paths: [String], _ body: (UserDefaults) -> Void) {
        let name = "plume-recent-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { return }
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(paths, forKey: "recentRepositories")
        body(defaults)
    }

    @Test func mostRecentSkipsAFolderThatNoLongerExists() throws {
        let existing = FileManager.default.temporaryDirectory
            .appending(path: "plume-recent-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: existing) }

        withStoredList(["/nonexistent/plume-\(UUID().uuidString)", existing]) { defaults in
            #expect(RecentFolders.mostRecent(in: defaults) == existing)
        }
    }

    @Test func migratingReplacesAWorktreeWithItsProject() {
        withStoredList(["/repo/.worktrees/feature"]) { defaults in
            RecentFolders.migrateWorktreesToProjects(in: defaults) { _ in "/repo" }
            #expect(RecentFolders.load(from: defaults) == ["/repo"])
        }
    }

    @Test func migratingCollapsesTwoWorktreesOfOneProject() {
        withStoredList(["/repo/.worktrees/a", "/repo/.worktrees/b"]) { defaults in
            RecentFolders.migrateWorktreesToProjects(in: defaults) { _ in "/repo" }
            #expect(RecentFolders.load(from: defaults) == ["/repo"])
        }
    }

    @Test func migratingKeepsTheOrderAProjectAlreadyHad() {
        withStoredList(["/repo", "/other", "/repo/.worktrees/a"]) { defaults in
            RecentFolders.migrateWorktreesToProjects(in: defaults) { path in
                path.hasPrefix("/repo") ? "/repo" : "/other"
            }
            #expect(RecentFolders.load(from: defaults) == ["/repo", "/other"])
        }
    }

    @Test func migratingDropsADirectoryGitNoLongerKnows() {
        withStoredList(["/gone", "/repo"]) { defaults in
            RecentFolders.migrateWorktreesToProjects(in: defaults) { path in
                path == "/gone" ? nil : "/repo"
            }
            #expect(RecentFolders.load(from: defaults) == ["/repo"])
        }
    }

    @Test func migratingLeavesASettledListAlone() {
        withStoredList(["/repo", "/other"]) { defaults in
            RecentFolders.migrateWorktreesToProjects(in: defaults) { path in path }
            #expect(RecentFolders.load(from: defaults) == ["/repo", "/other"])
        }
    }
}

/// The last-used-folder default on new tasks.
@MainActor
struct RecentFolderDefaultTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    private func withRecentFolder(_ path: String?, _ body: () throws -> Void) rethrows {
        let saved = RecentFolders.load()
        defer { UserDefaults.standard.set(saved, forKey: "recentRepositories") }
        UserDefaults.standard.set(path.map { [$0] } ?? [], forKey: "recentRepositories")
        try body()
    }

    @Test func optingInSeedsTheWorkspaceFromTheLastFolderUsed() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "plume-seed-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }

        try withRecentFolder(folder) {
            let task = TaskStore.createTask(
                in: try makeContext(), siblings: [], defaultsToRecentFolder: true
            )
            #expect(task.workingDirectoryPath == folder)
            #expect(task.workspaceKind == .directory)
        }
    }

    @Test func aTaskStaysUnsetWithoutOptingIn() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "plume-seed-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }

        try withRecentFolder(folder) {
            let task = TaskStore.createTask(in: try makeContext(), siblings: [])
            #expect(task.workspaceKind == .unset)
            #expect(task.workingDirectoryPath == nil)
        }
    }

    @Test func nothingRememberedLeavesTheTaskUnset() throws {
        try withRecentFolder(nil) {
            let task = TaskStore.createTask(
                in: try makeContext(), siblings: [], defaultsToRecentFolder: true
            )
            #expect(task.workspaceKind == .unset)
        }
    }
}
