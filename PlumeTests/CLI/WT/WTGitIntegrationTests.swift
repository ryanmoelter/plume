import Foundation
import Testing
@testable import Plume

/// `ProcessWorktreeGit` and `WorktreeContext.detect` against real scratch
/// repositories, in both layouts.
struct WTGitIntegrationTests {
    private func detect(from directory: String, settings: ProjectsConfiguration = ProjectsConfiguration()) throws -> WorktreeContext {
        try WorktreeContext.detect(
            git: ProcessWorktreeGit(workingDirectory: directory),
            settingsSource: StaticSettingsSource(configuration: settings),
            console: BufferConsole(), environment: [:]
        )
    }

    @Test func detectFindsTheStandardLayout() throws {
        let tmp = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let repo = try makeScratchRepository(in: tmp)
        let ctx = try detect(from: repo)
        #expect(ctx.layout == .standard)
        #expect(ctx.root == repo)
        #expect(ctx.mainName == "repo")
        #expect(ctx.newWorktreesDirectory == "\(repo)/.plume/worktrees")
        #expect(ctx.currentWorktree()?.path == repo)
    }

    @Test func detectFromALinkedWorktreeFindsTheMainWorktree() throws {
        let tmp = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let repo = try makeScratchRepository(in: tmp)
        let linked = "\(repo)/.plume/worktrees/a"
        try runGit(["worktree", "add", "-q", "-b", "ryanm/a", linked], in: repo)
        let ctx = try detect(from: linked)
        #expect(ctx.root == repo)
        #expect(ctx.currentWorktree()?.name == "a")
        #expect(ctx.currentWorktree()?.path == linked)
        #expect(ctx.listWorktreeNames() == ["repo", "a"])
    }

    @Test func detectFindsTheBareLayout() throws {
        let tmp = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let source = try makeScratchRepository(in: tmp, name: "source")
        let project = "\(tmp)/proj"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try runGit(["clone", "-q", "--bare", source, "\(project)/.bare"], in: tmp)
        try runGit(["worktree", "add", "-q", "\(project)/main", "main"], in: "\(project)/.bare")
        let ctx = try detect(from: "\(project)/main")
        #expect(ctx.layout == .bare)
        #expect(ctx.root == project)
        #expect(ctx.repoDir == "\(project)/.bare")
        #expect(ctx.mainName == "")
        #expect(ctx.newWorktreesDirectory == project)
        #expect(ctx.listWorktreeNames() == ["main"])
    }

    @Test(arguments: ["", "/.bare"])
    func detectFromTheBareLayoutsRootFolderFindsTheLayout(_ suffix: String) throws {
        let tmp = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let source = try makeScratchRepository(in: tmp, name: "source")
        let project = "\(tmp)/proj"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try runGit(["clone", "-q", "--bare", source, "\(project)/.bare"], in: tmp)
        try runGit(["worktree", "add", "-q", "\(project)/main", "main"], in: "\(project)/.bare")
        let ctx = try detect(from: project + suffix)
        #expect(ctx.layout == .bare)
        #expect(ctx.root == project)
        #expect(ctx.repoDir == "\(project)/.bare")
        #expect(ctx.currentWorktree() == nil)

        try WT.list(ctx, [])
        #expect((ctx.console as? BufferConsole)?.stdout.contains("main") == true)
    }

    @Test func detectReadsTheProjectsIgnoredChecks() throws {
        let tmp = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let repo = try makeScratchRepository(in: tmp)
        let ctx = try WorktreeContext.detect(
            git: ProcessWorktreeGit(workingDirectory: repo),
            settingsSource: StaticSettingsSource(
                configuration: ProjectsConfiguration(repositories: [repo: ProjectSettings(ignoredPendingChecks: ["project-check"])])
            ),
            console: BufferConsole(), environment: [:]
        )
        #expect(ctx.ui.ignoredPendingChecks == ["project-check"])
    }

    @Test func processEntriesIncludeDetachedWorktrees() throws {
        let tmp = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let repo = try makeScratchRepository(in: tmp)
        let detached = "\(repo)/.plume/worktrees/det"
        try runGit(["worktree", "add", "-q", "--detach", detached], in: repo)
        #expect(ProcessWorktreeGit(workingDirectory: repo).worktreeEntries() == [
            WorktreeEntry(path: repo, branch: "main"),
            WorktreeEntry(path: detached, branch: nil),
        ])
    }

    @Test func cobCreatesASelfIgnoredWorktree() throws {
        let tmp = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let repo = try makeScratchRepository(in: tmp)
        let settings = ProjectsConfiguration(repositories: [repo: ProjectSettings(branchPrefix: "ryanm/")])
        let ctx = try detect(from: repo, settings: settings)
        try WT.checkout(ctx, ["x", "--no-tab"], create: true)

        let worktree = "\(repo)/.plume/worktrees/x"
        #expect(try runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree) == "ryanm/x")
        #expect((try? String(contentsOfFile: "\(repo)/.plume/.gitignore", encoding: .utf8)) == "*\n")
        #expect(try runGit(["status", "--porcelain"], in: repo) == "")
        #expect((ctx.console as? BufferConsole)?.stdout.contains("(cd ") == false)
    }

    /// Another process can push to the shared stash list between a push and
    /// its restore, so the restore must find its own entry rather than take
    /// the top one.
    @Test func aStashRestoresItsOwnEntryAfterAnotherIsPushed() throws {
        let tmp = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let repo = try makeScratchRepository(in: tmp)
        let git = ProcessWorktreeGit(workingDirectory: repo)
        try "mine\n".write(toFile: "\(repo)/README", atomically: true, encoding: .utf8)
        let sha = try git.stashPush(repo, message: "mine")
        try "other\n".write(toFile: "\(repo)/other.txt", atomically: true, encoding: .utf8)
        try runGit(["stash", "push", "-q", "--include-untracked", "-m", "other"], in: repo)

        #expect(git.stashRestoreOK(repo, sha: sha, silent: true))

        #expect(try String(contentsOfFile: "\(repo)/README", encoding: .utf8) == "mine\n")
        #expect(!FileManager.default.fileExists(atPath: "\(repo)/other.txt"))
        #expect(try runGit(["stash", "list", "--format=%gs"], in: repo) == "On main: other")
    }

    @Test func backgroundMovesChangesAndLeavesOtherStashesAlone() throws {
        let tmp = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let repo = try makeScratchRepository(in: tmp)
        try "unrelated\n".write(toFile: "\(repo)/unrelated.txt", atomically: true, encoding: .utf8)
        try runGit(["stash", "push", "-q", "--include-untracked", "-m", "unrelated"], in: repo)
        try runGit(["checkout", "-q", "-b", "ryanm/feat"], in: repo)
        try "work\n".write(toFile: "\(repo)/README", atomically: true, encoding: .utf8)
        let settings = ProjectsConfiguration(repositories: [repo: ProjectSettings(branchPrefix: "ryanm/")])
        let ctx = try detect(from: repo, settings: settings)

        try WT.background(ctx, ["--no-tab"])

        let moved = "\(repo)/.plume/worktrees/feat"
        #expect(try String(contentsOfFile: "\(moved)/README", encoding: .utf8) == "work\n")
        #expect(try runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: repo) == "main")
        #expect(try runGit(["stash", "list", "--format=%gs"], in: repo) == "On main: unrelated")
    }
}
