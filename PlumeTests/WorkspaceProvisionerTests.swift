import Testing
import Foundation
@testable import Plume

struct BranchNamingTests {
    @Test func slugifyLowercasesAndHyphenates() {
        #expect(WorkspaceProvisioner.slugify("Fix Login Bug") == "fix-login-bug")
    }

    @Test func slugifyCollapsesRunsOfSeparators() {
        #expect(WorkspaceProvisioner.slugify("a  --  b") == "a-b")
    }

    @Test func slugifyStripsLeadingAndTrailingSeparators() {
        #expect(WorkspaceProvisioner.slugify("  hello!  ") == "hello")
    }

    @Test func slugifyDropsPunctuationAndKeepsNumbers() {
        #expect(WorkspaceProvisioner.slugify("DROID-123: fix the thing!") == "droid-123-fix-the-thing")
    }

    @Test func slugifyIsBounded() {
        #expect(WorkspaceProvisioner.slugify(String(repeating: "a", count: 100)).count == 40)
    }

    @Test func emptyTitleStillProducesAUsableBranch() {
        #expect(WorkspaceProvisioner.suggestedBranchName(for: "!!!", suffix: "beef") == "plume/task-beef")
    }

    @Test func suggestedBranchIsNamespacedAndSuffixed() {
        #expect(WorkspaceProvisioner.suggestedBranchName(for: "Fix Login", suffix: "a1b2") == "plume/fix-login-a1b2")
    }

    @Test func worktreeDirectoryNameFlattensTheBranchPath() {
        #expect(WorkspaceProvisioner.worktreeDirectoryName(for: "plume/fix-login-a1b2") == "plume-fix-login-a1b2")
    }

    @Test func worktreePathLivesUnderDotPlume() {
        let path = WorkspaceProvisioner.worktreePath(repository: "/repo", branch: "plume/x-0001")
        #expect(path == "/repo/.plume/worktrees/plume-x-0001")
    }

    @Test func worktreePathHonorsABasePathOverride() {
        let path = WorkspaceProvisioner.worktreePath(
            repository: "/repo", branch: "plume/x-0001", basePath: "/elsewhere"
        )
        #expect(path == "/elsewhere/repo/plume-x-0001")
    }

    @Test func emptyBasePathFallsBackToTheDefaultLocation() {
        let path = WorkspaceProvisioner.worktreePath(
            repository: "/repo", branch: "plume/x-0001", basePath: ""
        )
        #expect(path == "/repo/.plume/worktrees/plume-x-0001")
    }

    @Test func randomSuffixIsFourHexCharacters() {
        let suffix = WorkspaceProvisioner.randomSuffix()
        #expect(suffix.count == 4)
        #expect(suffix.allSatisfy { $0.isHexDigit })
    }

    // MARK: - Dropping the branch prefix

    @Test func strippingThePrefixKeepsOnlyTheLastSegment() {
        #expect(WorkspaceProvisioner.worktreeDirectoryName(
            for: "ryanm/plume-183", strippingPrefix: true
        ) == "plume-183")
        #expect(WorkspaceProvisioner.worktreeDirectoryName(
            for: "plume/task", strippingPrefix: true
        ) == "task")
    }

    @Test func strippingThePrefixLeavesAnUnprefixedBranchAlone() {
        #expect(WorkspaceProvisioner.worktreeDirectoryName(
            for: "hotfix", strippingPrefix: true
        ) == "hotfix")
    }

    @Test func strippingDropsEveryLeadingSegment() {
        #expect(WorkspaceProvisioner.worktreeDirectoryName(
            for: "a/b/c", strippingPrefix: true
        ) == "c")
    }

    /// Stripping to nothing would name every such worktree `worktree`.
    @Test func aTrailingSlashKeepsTheNameItWouldOtherwiseLose() {
        #expect(WorkspaceProvisioner.worktreeDirectoryName(
            for: "ryanm/", strippingPrefix: true
        ) == "ryanm")
    }

    @Test func strippingReachesTheDerivedPath() {
        #expect(WorkspaceProvisioner.worktreePath(
            repository: "/repo", branch: "ryanm/plume-183", strippingPrefix: true
        ) == "/repo/.plume/worktrees/plume-183")
    }

    // MARK: - An explicit location

    @Test func anExplicitPathOverridesEveryDerivation() {
        #expect(WorkspaceProvisioner.worktreePath(
            repository: "/repo",
            branch: "plume/x-0001",
            basePath: "/elsewhere",
            explicitPath: "/somewhere/else/tree"
        ) == "/somewhere/else/tree")
    }

    @Test func anExplicitPathExpandsATilde() {
        #expect(WorkspaceProvisioner.worktreePath(
            repository: "/repo", branch: "plume/x-0001", explicitPath: "~/trees/x"
        ) == NSHomeDirectory() + "/trees/x")
    }

    @Test func anEmptyExplicitPathFallsBackToTheDerivedOne() {
        #expect(WorkspaceProvisioner.worktreePath(
            repository: "/repo", branch: "plume/x-0001", explicitPath: "  "
        ) == "/repo/.plume/worktrees/plume-x-0001")
    }

    @Test func aSiblingOfTheRepositoryIsNotInsideItsPlumeDirectory() {
        #expect(!WorkspaceProvisioner.isInsidePlumeDirectory(
            path: "/parent/repo-trees/x", repository: "/parent/repo"
        ))
        #expect(WorkspaceProvisioner.isInsidePlumeDirectory(
            path: "/parent/repo/.plume/worktrees/x", repository: "/parent/repo"
        ))
    }

    /// The combination the sheet offers: a base path override, a stripped
    /// prefix, and no explicit location.
    @Test func aBasePathAndAStrippedPrefixCompose() {
        #expect(WorkspaceProvisioner.worktreePath(
            repository: "/parent/repo",
            branch: "ryanm/plume-183",
            basePath: "/trees",
            strippingPrefix: true
        ) == "/trees/repo/plume-183")
    }

    // MARK: - The branch prefix

    @Test func aCustomPrefixReplacesPlume() {
        #expect(WorkspaceProvisioner.suggestedBranchName(
            for: "Fix Login", suffix: "a1b2", prefix: "ryanm/"
        ) == "ryanm/fix-login-a1b2")
    }
}

/// Drives real `git`, so these create and tear down scratch repositories.
struct WorktreeProvisioningTests {
    private func makeRepository() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "plume-repo-\(UUID().uuidString)").path
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

    @Test func createsWorktreeAndBranchInsideDotPlume() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }

        let path = try WorkspaceProvisioner.createWorktree(repository: repository, branch: "plume/feature-0001")

        #expect(path == "\(repository)/.plume/worktrees/plume-feature-0001")
        #expect(FileManager.default.fileExists(atPath: "\(path)/README.md"))
        let branches = try GitRunner.run(["branch", "--list", "plume/feature-0001"], in: repository)
        #expect(branches.contains("plume/feature-0001"))
    }

    /// The whole point of the `.plume/.gitignore` bootstrap.
    @Test func repositoryStaysCleanAfterCreatingAWorktree() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }

        try WorkspaceProvisioner.createWorktree(repository: repository, branch: "plume/feature-0002")

        let status = try GitRunner.run(["status", "--porcelain"], in: repository)
        #expect(status.isEmpty)
    }

    @Test func gitignoreIsWrittenOnceAndNotOverwritten() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }

        try WorkspaceProvisioner.ensurePlumeDirectoryIgnored(in: repository)
        let gitignore = "\(repository)/.plume/.gitignore"
        try "custom\n".write(toFile: gitignore, atomically: true, encoding: .utf8)

        try WorkspaceProvisioner.ensurePlumeDirectoryIgnored(in: repository)

        let contents = try String(contentsOfFile: gitignore, encoding: .utf8)
        #expect(contents == "custom\n")
    }

    @Test func removingAWorktreeCanAlsoDeleteItsBranch() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let branch = "plume/feature-0003"
        let path = try WorkspaceProvisioner.createWorktree(repository: repository, branch: branch)

        try WorkspaceProvisioner.removeWorktree(
            repository: repository, path: path, branch: branch, deleteBranch: true
        )

        #expect(!FileManager.default.fileExists(atPath: path))
        let remaining = try GitRunner.run(["branch", "--list", branch], in: repository)
        #expect(remaining.isEmpty)
    }

    /// The create flow points the task at the new path and then re-lists, so
    /// the listing has to name the worktree that was just added.
    @Test func aCreatedWorktreeAppearsInTheListing() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let branch = "plume/listed-0001"

        let path = try WorkspaceProvisioner.createWorktree(repository: repository, branch: branch)

        let listed = GitRunner.worktrees(in: repository)
        #expect(listed.contains { standardized($0.path) == standardized(path) && $0.branch == branch })
        #expect(listed.first?.isMain == true)
    }

    @Test func aRemovedWorktreeLeavesTheListing() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let branch = "plume/listed-0002"
        let path = try WorkspaceProvisioner.createWorktree(repository: repository, branch: branch)

        try WorkspaceProvisioner.removeWorktree(
            repository: repository, path: path, branch: branch, deleteBranch: false
        )

        let listed = GitRunner.worktrees(in: repository)
        #expect(!listed.contains { standardized($0.path) == standardized(path) })
        // Only `deleteBranch` removes the branch; removal alone leaves it.
        let remaining = try GitRunner.run(["branch", "--list", branch], in: repository)
        #expect(remaining.contains(branch))
    }

    /// `--force` is what lets removal proceed at all once the tree is dirty.
    @Test func removingADirtyWorktreeDiscardsItsChanges() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let branch = "plume/dirty-0001"
        let path = try WorkspaceProvisioner.createWorktree(repository: repository, branch: branch)
        try "untracked\n".write(toFile: "\(path)/scratch.txt", atomically: true, encoding: .utf8)
        try "modified\n".write(toFile: "\(path)/README.md", atomically: true, encoding: .utf8)

        try WorkspaceProvisioner.removeWorktree(
            repository: repository, path: path, branch: branch, deleteBranch: false
        )

        #expect(!FileManager.default.fileExists(atPath: path))
    }

    /// What a dirty-tree guard reads before offering to remove.
    @Test func aDirtyWorktreeReportsItsChanges() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let path = try WorkspaceProvisioner.createWorktree(repository: repository, branch: "plume/dirty-0002")

        #expect(try GitRunner.run(["status", "--porcelain"], in: path).isEmpty)

        try "untracked\n".write(toFile: "\(path)/scratch.txt", atomically: true, encoding: .utf8)
        let status = try GitRunner.run(["status", "--porcelain"], in: path)
        #expect(status.contains("?? scratch.txt"))
    }

    /// Build output must not trip the dirty-tree confirmation, or every
    /// removal would ask.
    @Test func ignoredFilesDoNotCountAsUncommittedWork() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try "build/\n".write(toFile: "\(repository)/.gitignore", atomically: true, encoding: .utf8)
        try GitRunner.run(["add", "."], in: repository)
        try GitRunner.run(["commit", "-m", "ignore build"], in: repository)
        let path = try WorkspaceProvisioner.createWorktree(repository: repository, branch: "plume/ignored-0001")
        try FileManager.default.createDirectory(atPath: "\(path)/build", withIntermediateDirectories: true)
        try "artifact\n".write(toFile: "\(path)/build/out.o", atomically: true, encoding: .utf8)

        #expect(WorkspaceProvisioner.uncommittedChanges(in: path).isEmpty)
    }

    @Test func uncommittedChangesReportTrackedAndUntrackedWork() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let path = try WorkspaceProvisioner.createWorktree(repository: repository, branch: "plume/dirty-0003")

        #expect(WorkspaceProvisioner.uncommittedChanges(in: path).isEmpty)

        try "changed\n".write(toFile: "\(path)/README.md", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: "\(path)/scratch.txt", atomically: true, encoding: .utf8)

        let changes = WorkspaceProvisioner.uncommittedChanges(in: path)
        #expect(changes.count == 2)
        #expect(changes.contains { $0.hasSuffix("README.md") })
        #expect(changes.contains { $0.hasSuffix("scratch.txt") })
    }

    /// A path git never resolves must not read as dirty, or removing an
    /// already-missing worktree would stop to ask about nothing.
    @Test func uncommittedChangesAreEmptyForAMissingDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "plume-gone-\(UUID().uuidString)").path

        #expect(WorkspaceProvisioner.uncommittedChanges(in: missing).isEmpty)
    }

    private func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    @Test func createWorktreeHonorsABasePathOverride() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let basePath = FileManager.default.temporaryDirectory
            .appending(path: "plume-base-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: basePath) }

        let path = try WorkspaceProvisioner.createWorktree(
            repository: repository, branch: "plume/feature-0004", basePath: basePath
        )

        #expect(path == "\(basePath)/\(URL(fileURLWithPath: repository).lastPathComponent)/plume-feature-0004")
        #expect(FileManager.default.fileExists(atPath: "\(path)/README.md"))
        // An override skips the in-repo `.plume/.gitignore` bootstrap.
        #expect(!FileManager.default.fileExists(atPath: "\(repository)/.plume/.gitignore"))
    }

    @Test func duplicateBranchFailsWithGitsMessage() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try WorkspaceProvisioner.createWorktree(repository: repository, branch: "plume/dupe-0001")

        #expect(throws: GitError.self) {
            _ = try WorkspaceProvisioner.createWorktree(repository: repository, branch: "plume/dupe-0001")
        }
    }

    @Test func repositoryRootResolvesFromASubdirectory() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let nested = "\(repository)/a/b"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)

        let root = GitRunner.repositoryRoot(containing: nested)

        // The temporary directory is a symlink on macOS, so compare resolved paths.
        #expect(root.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            == URL(fileURLWithPath: repository).resolvingSymlinksInPath().path)
    }

    @Test func theConfiguredPrefixComesFromWtBranchprefix() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try GitRunner.run(["config", "wt.branchprefix", "ryanm/"], in: repository)

        #expect(WorkspaceProvisioner.configuredBranchPrefix(in: repository) == "ryanm/")
    }

    /// A prefix is a path segment, so a config that omits the slash still
    /// yields one. Set on `wt.branchprefix` because a developer's own global
    /// config may define it, which would outrank a local `stack.branchprefix`.
    @Test func aPrefixWithoutASlashGainsOne() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try GitRunner.run(["config", "wt.branchprefix", "alice"], in: repository)

        #expect(WorkspaceProvisioner.configuredBranchPrefix(in: repository) == "alice/")
    }

    @Test func createsAWorktreeAtAnExplicitSiblingLocation() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let sibling = repository + "-trees/feature"
        defer { try? FileManager.default.removeItem(atPath: repository + "-trees") }

        let path = try WorkspaceProvisioner.createWorktree(
            repository: repository, branch: "plume/feature-0002", explicitPath: sibling
        )

        #expect(path == sibling)
        #expect(FileManager.default.fileExists(atPath: "\(path)/README.md"))
        // Outside `.plume`, so no ignore file is this call's business.
        #expect(!FileManager.default.fileExists(atPath: "\(repository)/.plume/.gitignore"))
    }

    @Test func createsAWorktreeUnderTheStrippedDirectoryName() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }

        let path = try WorkspaceProvisioner.createWorktree(
            repository: repository, branch: "ryanm/plume-183", strippingPrefix: true
        )

        #expect(path == "\(repository)/.plume/worktrees/plume-183")
        #expect(FileManager.default.fileExists(atPath: "\(path)/README.md"))
    }

    @Test func repositoryRootIsNilOutsideAnyRepository() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "plume-plain-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        #expect(GitRunner.repositoryRoot(containing: directory) == nil)
    }
}
