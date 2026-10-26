import Foundation
import Testing
@testable import Plume

/// Worktree discovery from git's own registry: the porcelain parser (which
/// keeps detached worktrees), and `WorktreeContext` built on it. A worktree
/// anywhere on disk is found, the working directory is recognized by
/// registry membership, and a shared name is refused rather than guessed.
/// Ported from `test_wt_discovery.py`.
struct WTDiscoveryTests {
    private static let root = "/repo"

    private func context(
        _ entries: [(String, String?)],
        top: String? = nil,
        layout: WorktreeLayout = .standard,
        mainName: String = "repo"
    ) -> WorktreeContext {
        WorktreeContext(
            git: FakeWorktreeGit(entries, top: top), layout: layout, root: Self.root, repoDir: Self.root,
            newWorktreesDirectory: "\(Self.root)/.plume/worktrees", mainName: mainName
        )
    }

    // MARK: porcelain

    @Test func aDetachedWorktreeSurvivesWithNoBranch() {
        let text = porcelain([("/repo", "main"), ("/repo/.plume/worktrees/det", nil), ("/repo/.plume/worktrees/a", "ryanm/a")])
        #expect(WorktreePorcelain.entries(from: text) == [
            WorktreeEntry(path: "/repo", branch: "main"),
            WorktreeEntry(path: "/repo/.plume/worktrees/det", branch: nil),
            WorktreeEntry(path: "/repo/.plume/worktrees/a", branch: "ryanm/a"),
        ])
    }

    /// A record is flushed by the next `worktree` line, so a detached entry
    /// can't swallow the branch of the one after it.
    @Test func aDetachedEntryDoesNotAbsorbTheNextBranch() {
        let entries = WorktreePorcelain.entries(from: porcelain([("/repo/det", nil), ("/repo/a", "ryanm/a")]))
        #expect(entries == [WorktreeEntry(path: "/repo/det", branch: nil), WorktreeEntry(path: "/repo/a", branch: "ryanm/a")])
    }

    @Test func recordsDropDetachedWorktrees() {
        let entries = WorktreePorcelain.entries(from: porcelain([("/repo", "main"), ("/repo/det", nil)]))
        #expect(WorktreePorcelain.records(from: entries) == [WorktreeRecord(branch: "main", path: "/repo")])
    }

    @Test func noOutputIsEmpty() {
        #expect(WorktreePorcelain.entries(from: "").isEmpty)
    }

    // MARK: registry

    @Test func aWorktreeOutsideTheNewDirectoryIsFound() throws {
        let ctx = context([("/repo", "main"), ("/elsewhere/foreign", "someone/x")])
        #expect(ctx.listWorktreeNames().contains("foreign"))
        #expect(try ctx.worktreePath("foreign") == "/elsewhere/foreign")
        #expect(ctx.worktreeExists("foreign"))
    }

    @Test func theMainWorktreeSortsFirst() {
        let ctx = context([("/repo/.plume/worktrees/aaa", "ryanm/aaa"), ("/repo", "main"), ("/repo/.plume/worktrees/zzz", "ryanm/zzz")])
        #expect(ctx.listWorktreeNames() == ["repo", "aaa", "zzz"])
    }

    @Test func aDetachedWorktreeIsListed() {
        let ctx = context([("/repo", "main"), ("/repo/.plume/worktrees/det", nil)])
        #expect(ctx.listWorktreeNames() == ["repo", "det"])
    }

    /// The bare layout registers `.bare` as a worktree, but it holds no
    /// checkout.
    @Test func theBareRepositoryIsExcluded() {
        let ctx = context([("/repo/.bare", "main"), ("/repo/a", "ryanm/a")], layout: .bare, mainName: "")
        #expect(ctx.listWorktreeNames() == ["a"])
        #expect(!ctx.worktreeExists(".bare"))
    }

    /// The hidden-name filter applies to linked worktrees only: a repository
    /// checked out in a dot-directory still lists its root.
    @Test func aDotNamedMainWorktreeIsKept() throws {
        let ctx = WorktreeContext(
            git: FakeWorktreeGit([("/home/.dotfiles", "main"), ("/home/.dotfiles/.plume/worktrees/a", "ryanm/a")]),
            layout: .standard, root: "/home/.dotfiles", repoDir: "/home/.dotfiles",
            newWorktreesDirectory: "/home/.dotfiles/.plume/worktrees", mainName: ".dotfiles"
        )
        #expect(ctx.listWorktreeNames() == [".dotfiles", "a"])
        #expect(try ctx.worktreePath(".dotfiles") == "/home/.dotfiles")
    }

    @Test func anUnknownNameFails() {
        #expect(cliFailure { _ = try context([("/repo", "main")]).worktreePath("nope") } != nil)
    }

    @Test func pathsInListOrderMatchNames() {
        let ctx = context([("/repo", "main"), ("/repo/.plume/worktrees/a", "ryanm/a"), ("/elsewhere/b", "ryanm/b")])
        let names = ctx.listWorktreeNames()
        let paths = ctx.worktreePathsInListOrder()
        #expect(names.count == 3)
        #expect(paths.count == names.count)
        #expect(Dictionary(uniqueKeysWithValues: zip(names, paths)) == [
            "repo": "/repo", "a": "/repo/.plume/worktrees/a", "b": "/elsewhere/b",
        ])
    }

    // MARK: ambiguous names

    private func ambiguous(top: String? = nil) -> WorktreeContext {
        context([("/repo", "main"), ("/repo/.plume/worktrees/foo", "ryanm/foo"), ("/elsewhere/foo", "other/foo")], top: top)
    }

    @Test func resolvingAnAmbiguousNameFailsListingTheCandidates() throws {
        let failure = try #require(cliFailure { _ = try ambiguous().worktreePath("foo") })
        let message = failure.message ?? ""
        #expect(message.contains("ambiguous"))
        #expect(message.contains("/repo/.plume/worktrees/foo"))
        #expect(message.contains("/elsewhere/foo"))
    }

    @Test func bothCollidingWorktreesStillList() {
        let ctx = ambiguous()
        #expect(ctx.listWorktreeNames() == ["repo", "foo", "foo"])
        #expect(ctx.worktreePathsInListOrder() == ["/repo", "/elsewhere/foo", "/repo/.plume/worktrees/foo"])
    }

    @Test func describeExistingNamesEveryLocation() {
        let described = ambiguous().describeExisting("foo")
        #expect(described.contains("/repo/.plume/worktrees/foo"))
        #expect(described.contains("/elsewhere/foo"))
    }

    // MARK: current worktree

    @Test func aWorkingDirectoryOutsideTheNewDirectoryIsRecognized() throws {
        let ctx = context([("/repo", "main"), ("/elsewhere/foreign", "someone/x")], top: "/elsewhere/foreign")
        #expect(ctx.currentWorktreeNameOrNone() == "foreign")
        #expect(try ctx.currentWorktreePath() == "/elsewhere/foreign")
    }

    @Test func theMainWorktreeReportsItsName() {
        #expect(context([("/repo", "main")], top: "/repo").currentWorktreeNameOrNone() == "repo")
    }

    @Test func anUnregisteredWorkingDirectoryIsNone() {
        #expect(context([("/repo", "main")], top: "/somewhere/else").currentWorktreeNameOrNone() == nil)
    }

    @Test func aWorkingDirectoryOutsideARepositoryIsNone() {
        #expect(context([("/repo", "main")], top: nil).currentWorktreeNameOrNone() == nil)
    }

    /// `wt current` must answer inside a worktree whose name it shares: the
    /// path comes from git's toplevel, not a name lookup.
    @Test(arguments: ["/repo/.plume/worktrees/foo", "/elsewhere/foo"])
    func anAmbiguousNameStillReportsItsOwnPath(_ top: String) {
        let current = ambiguous(top: top).currentWorktree()
        #expect(current?.name == "foo")
        #expect(current?.path == top)
    }

    @Test func theBareLayoutNamesByBasename() {
        let ctx = context([("/repo/a", "ryanm/a")], top: "/repo/a", layout: .bare, mainName: "")
        #expect(ctx.currentWorktreeNameOrNone() == "a")
    }

    // MARK: --paths column

    @Test func theRootRendersAsDot() {
        #expect(WT.displayLocation("/repo", root: "/repo") == ".")
    }

    @Test func insideTheRepositoryIsRelative() {
        #expect(WT.displayLocation("/repo/.plume/worktrees/foo", root: "/repo") == ".plume/worktrees")
    }

    @Test func directlyUnderTheRootIsDot() {
        #expect(WT.displayLocation("/repo/foo", root: "/repo") == ".")
    }

    @Test func outsideTheRepositoryStaysAbsolute() {
        #expect(WT.displayLocation("/elsewhere/foo", root: "/repo") == "/elsewhere")
    }

    @Test func aMissingPathIsBlank() {
        #expect(WT.displayLocation(nil, root: "/repo") == "")
    }

    // MARK: new-worktree directory

    @Test func theStandardLayoutSelfIgnoresDotPlume() throws {
        let tmp = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let ctx = WorktreeContext(
            git: FakeWorktreeGit(), layout: .standard, root: tmp, repoDir: tmp,
            newWorktreesDirectory: "\(tmp)/.plume/worktrees", mainName: (tmp as NSString).lastPathComponent
        )
        try ctx.ensureWorktreesDirectory()
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: "\(tmp)/.plume/worktrees", isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect((try? String(contentsOfFile: "\(tmp)/.plume/.gitignore", encoding: .utf8)) == "*\n")
    }

    @Test func anExistingDotPlumeIgnoreIsKept() throws {
        let tmp = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try FileManager.default.createDirectory(atPath: "\(tmp)/.plume", withIntermediateDirectories: true)
        try "custom\n".write(toFile: "\(tmp)/.plume/.gitignore", atomically: true, encoding: .utf8)
        let ctx = WorktreeContext(
            git: FakeWorktreeGit(), layout: .standard, root: tmp, repoDir: tmp,
            newWorktreesDirectory: "\(tmp)/.plume/worktrees", mainName: (tmp as NSString).lastPathComponent
        )
        try ctx.ensureWorktreesDirectory()
        #expect((try? String(contentsOfFile: "\(tmp)/.plume/.gitignore", encoding: .utf8)) == "custom\n")
        #expect(FileManager.default.fileExists(atPath: "\(tmp)/.plume/worktrees"))
    }

    @Test func theBareLayoutWritesNothing() throws {
        let tmp = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let ctx = WorktreeContext(
            git: FakeWorktreeGit(), layout: .bare, root: tmp, repoDir: tmp, newWorktreesDirectory: tmp, mainName: ""
        )
        try ctx.ensureWorktreesDirectory()
        #expect(!FileManager.default.fileExists(atPath: "\(tmp)/.gitignore"))
        #expect(!FileManager.default.fileExists(atPath: "\(tmp)/.plume"))
    }

    // MARK: detect

    private func detect(_ git: FakeWorktreeGit, settings: ProjectsConfiguration = ProjectsConfiguration()) throws -> WorktreeContext {
        try WorktreeContext.detect(
            git: git, settingsSource: StaticSettingsSource(configuration: settings),
            console: BufferConsole(), environment: [:]
        )
    }

    @Test func detectFindsTheStandardLayoutFromARelativeCommonDirectory() throws {
        let git = FakeWorktreeGit(top: "/repo", common: ".git")
        let ctx = try detect(git)
        #expect(ctx.layout == .standard)
        #expect(ctx.root == "/repo")
        #expect(ctx.repoDir == "/repo")
        #expect(ctx.mainName == "repo")
        #expect(ctx.newWorktreesDirectory == "/repo/.plume/worktrees")
        #expect(git.repoDir == "/repo")
    }

    /// From a linked worktree, the common directory is still the main
    /// worktree's `.git`.
    @Test func detectFromALinkedWorktreeFindsTheMainWorktree() throws {
        let ctx = try detect(FakeWorktreeGit(top: "/repo/.plume/worktrees/a", common: "/repo/.git"))
        #expect(ctx.root == "/repo")
        #expect(ctx.mainName == "repo")
    }

    @Test func detectFindsTheBareLayout() throws {
        let git = FakeWorktreeGit(top: "/proj/a", common: "/proj/.bare")
        let ctx = try detect(git)
        #expect(ctx.layout == .bare)
        #expect(ctx.root == "/proj")
        #expect(ctx.repoDir == "/proj/.bare")
        #expect(ctx.mainName == "")
        #expect(ctx.newWorktreesDirectory == "/proj")
        #expect(git.repoDir == "/proj/.bare")
    }

    @Test func detectOutsideARepositoryFails() {
        #expect(cliFailure { _ = try detect(FakeWorktreeGit(top: nil)) }?.message == "not inside a git repo")
    }

    @Test func detectAppliesTheRepositorysSettings() throws {
        let settings = ProjectsConfiguration(
            defaults: ProjectSettings(baseBranch: "develop", protectedWorktrees: ["keep"]),
            repositories: ["/repo": ProjectSettings(baseBranch: "staging")]
        )
        let ctx = try detect(FakeWorktreeGit(top: "/repo", common: "/repo/.git"), settings: settings)
        #expect(ctx.baseBranch == "staging")
        #expect(ctx.baseRef == "origin/staging")
        #expect(ctx.protected == ["keep", "repo"])
    }

    // MARK: forge and prefix

    private func contextWith(git: FakeWorktreeGit, settings: ProjectSettings = ProjectSettings()) -> WorktreeContext {
        WorktreeContext(
            git: git, layout: .standard, root: "/repo", repoDir: "/repo",
            newWorktreesDirectory: "/repo/.plume/worktrees", mainName: "repo", settings: settings
        )
    }

    @Test func theForgeIsSniffedFromOrigin() {
        #expect(contextWith(git: FakeWorktreeGit(origin: "git@github.com:o/r.git")).forgeKind == .github)
    }

    @Test func theForgeSettingOverridesTheSniff() {
        let ctx = contextWith(git: FakeWorktreeGit(origin: "git@git.corp:o/r.git"), settings: ProjectSettings(forge: .gitlab))
        #expect(ctx.forgeKind == .gitlab)
    }

    @Test func thePrefixFallsBackToTheEmailsLocalPart() {
        #expect(contextWith(git: FakeWorktreeGit(config: ["user.email": "ryan@example.com"])).branchPrefixResolution() == "ryan/")
    }

    /// An explicit empty prefix means "no prefix", not "unset".
    @Test func anExplicitEmptyPrefixBeatsTheEmail() {
        let ctx = contextWith(git: FakeWorktreeGit(config: ["user.email": "ryan@example.com"]), settings: ProjectSettings(branchPrefix: ""))
        #expect(ctx.branchPrefixResolution() == "")
    }

    @Test func noPrefixAndNoEmailCannotResolve() {
        let ctx = contextWith(git: FakeWorktreeGit())
        #expect(ctx.branchPrefixResolution() == nil)
        #expect(cliFailure { _ = try WT.branchPrefix(ctx) } != nil)
    }
}
