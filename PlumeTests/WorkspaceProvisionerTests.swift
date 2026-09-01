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

    @Test func randomSuffixIsFourHexCharacters() {
        let suffix = WorkspaceProvisioner.randomSuffix()
        #expect(suffix.count == 4)
        #expect(suffix.allSatisfy { $0.isHexDigit })
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

    @Test func repositoryRootIsNilOutsideAnyRepository() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "plume-plain-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        #expect(GitRunner.repositoryRoot(containing: directory) == nil)
    }
}
