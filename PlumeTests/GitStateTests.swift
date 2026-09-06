import Testing
import Foundation
@testable import Plume

/// Fixtures are real `git status --porcelain=v2 --branch` output.
struct GitStateTests {
    @Test func aCleanTrackedBranchReportsZeroes() {
        let state = GitState.parsing("""
        # branch.oid b49c5085167a17994fd00e63ff3ea534cc4a451f
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0
        """)

        #expect(state.branch == "main")
        #expect(state.ahead == 0)
        #expect(state.behind == 0)
        #expect(!state.isDirty)
        #expect(state.hasUpstream)
    }

    @Test func aheadAndBehindAreParsed() {
        let state = GitState.parsing("""
        # branch.head feature
        # branch.upstream origin/feature
        # branch.ab +3 -2
        """)

        #expect(state.ahead == 3)
        #expect(state.behind == 2)
    }

    /// The common case on a fresh worktree branch: both header lines are
    /// simply absent, which is different from being level with an upstream.
    @Test func noUpstreamLeavesTheCountsNil() {
        let state = GitState.parsing("""
        # branch.oid 306214d737f72ab7ae48be75ff83dc1592d8ca61
        # branch.head feature
        """)

        #expect(state.branch == "feature")
        #expect(state.ahead == nil)
        #expect(state.behind == nil)
        #expect(!state.hasUpstream)
    }

    /// git prints the tracking header without the counts whenever it cannot
    /// compare the two — the remote-tracking ref deleted, or never fetched.
    @Test func anUpstreamWithoutCountsStillCountsAsTracked() {
        let state = GitState.parsing("""
        # branch.oid 854ac3f53b773a148e9a27e12812559420598906
        # branch.head main
        # branch.upstream origin/main
        """)

        #expect(state.hasUpstream)
        #expect(state.upstream == "origin/main")
        #expect(state.ahead == nil)
        #expect(state.behind == nil)
    }

    @Test func changedAndUntrackedFilesBothMeanDirty() {
        let changed = GitState.parsing("""
        # branch.head main
        1 .M N... 100644 100644 100644 c978576 c978576 Plume/UI/Sidebar/SidebarView.swift
        """)
        #expect(changed.isDirty)

        let untracked = GitState.parsing("""
        # branch.head main
        ? Plume/UI/Sidebar/SidebarSelectionBackground.swift
        """)
        #expect(untracked.isDirty)
    }

    @Test func headersAloneAreNotDirty() {
        let state = GitState.parsing("""
        # branch.oid abc
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +14 -0
        """)
        #expect(!state.isDirty)
        #expect(state.ahead == 14)
    }

    @Test func aDetachedHeadHasNoBranch() {
        let state = GitState.parsing("""
        # branch.oid abc
        # branch.head (detached)
        """)
        #expect(state.branch == nil)
    }

    @Test func emptyOutputIsClean() {
        let state = GitState.parsing("")
        #expect(state.branch == nil)
        #expect(!state.isDirty)
        #expect(!state.hasUpstream)
    }

    /// The real command against a real repository, which is what catches a
    /// format change in git itself.
    @Test func aRealRepositoryReportsItsState() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GitStateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = root.path
        _ = try GitRunner.run(["init", "-q", "-b", "trunk", "."], in: path)
        // Signing would hang the test host waiting on an external agent.
        _ = try GitRunner.run(["config", "commit.gpgsign", "false"], in: path)
        _ = try GitRunner.run(["commit", "-q", "--allow-empty", "-m", "first"], in: path)

        let clean = try #require(GitRunner.state(in: path))
        #expect(clean.branch == "trunk")
        #expect(!clean.isDirty)
        // A fresh repository tracks nothing.
        #expect(!clean.hasUpstream)

        try "hello".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let dirty = try #require(GitRunner.state(in: path))
        #expect(dirty.isDirty)
    }

    /// Ahead/behind only appear once a branch actually tracks something, so
    /// a real clone is the only way to cover the counts end to end.
    @Test func aClonedBranchCountsCommitsAheadOfItsUpstream() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
        let origin = base.appendingPathComponent("GitStateOrigin-\(UUID().uuidString)")
        let clone = base.appendingPathComponent("GitStateClone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: origin)
            try? FileManager.default.removeItem(at: clone)
        }

        _ = try GitRunner.run(["init", "-q", "-b", "trunk", "."], in: origin.path)
        _ = try GitRunner.run(["config", "commit.gpgsign", "false"], in: origin.path)
        _ = try GitRunner.run(["commit", "-q", "--allow-empty", "-m", "first"], in: origin.path)

        _ = try GitRunner.run(["clone", "-q", origin.path, clone.path])
        _ = try GitRunner.run(["config", "commit.gpgsign", "false"], in: clone.path)

        let level = try #require(GitRunner.state(in: clone.path))
        #expect(level.hasUpstream)
        #expect(level.ahead == 0)

        _ = try GitRunner.run(["commit", "-q", "--allow-empty", "-m", "ahead"], in: clone.path)
        let ahead = try #require(GitRunner.state(in: clone.path))
        #expect(ahead.ahead == 1)
        #expect(ahead.behind == 0)
        #expect(!ahead.isDirty)
    }

    /// The live "no upstream" bug, end to end: a configured upstream whose
    /// remote-tracking ref is gone still tracks something.
    @Test func aBranchWhoseRemoteRefIsMissingStillHasAnUpstream() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
        let origin = base.appendingPathComponent("GitStateMissingRefOrigin-\(UUID().uuidString)")
        let clone = base.appendingPathComponent("GitStateMissingRefClone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: origin)
            try? FileManager.default.removeItem(at: clone)
        }

        _ = try GitRunner.run(["init", "-q", "-b", "trunk", "."], in: origin.path)
        _ = try GitRunner.run(["config", "commit.gpgsign", "false"], in: origin.path)
        _ = try GitRunner.run(["commit", "-q", "--allow-empty", "-m", "first"], in: origin.path)
        _ = try GitRunner.run(["clone", "-q", origin.path, clone.path])
        _ = try GitRunner.run(["update-ref", "-d", "refs/remotes/origin/trunk"], in: clone.path)

        let state = try #require(GitRunner.state(in: clone.path))
        #expect(state.hasUpstream)
        #expect(state.ahead == nil)
    }

    /// A linked worktree's `.git` is a pointer file; what git writes to is
    /// the per-worktree directory inside the repository.
    @Test func aWorktreeResolvesToItsOwnGitDirectory() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
        let repository = base.appendingPathComponent("GitStateWorktreeRepo-\(UUID().uuidString)")
        let worktree = base.appendingPathComponent("GitStateWorktree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: repository)
            try? FileManager.default.removeItem(at: worktree)
        }

        _ = try GitRunner.run(["init", "-q", "-b", "trunk", "."], in: repository.path)
        _ = try GitRunner.run(["config", "commit.gpgsign", "false"], in: repository.path)
        _ = try GitRunner.run(["commit", "-q", "--allow-empty", "-m", "first"], in: repository.path)
        _ = try GitRunner.run(["worktree", "add", "-q", worktree.path, "-b", "side"], in: repository.path)

        let resolved = try #require(GitRunner.gitDirectory(containing: worktree.path))
        #expect(resolved.hasSuffix("worktrees/\(worktree.lastPathComponent)"))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func aDirectoryOutsideAnyRepositoryHasNoState() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GitStateNotARepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(GitRunner.state(in: directory.path) == nil)
    }
}
