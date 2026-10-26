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
}
