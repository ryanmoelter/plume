import Testing
import Foundation
@testable import Plume

/// What each missing-transcript policy does to a Claude agent tab whose
/// session file cannot be found.
struct ImportValidatorTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "import-validator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func candidate(in directory: URL, sessionID: String = UUID().uuidString) -> ImportCandidate {
        let agent = ImportTabPlan(
            kind: .agent,
            title: "Agent",
            workingDirectoryPath: nil,
            agentSessionID: sessionID,
            sessionJSONLPath: nil,
            permissionMode: nil
        )
        return ImportCandidate(
            stableID: "test:1",
            title: "Test",
            workingDirectoryPath: directory.path,
            groupName: nil,
            tabs: [agent],
            workspace: ImportWorkspacePlan()
        )
    }

    @Test func rejectPolicyRefusesTheRow() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID().uuidString
        let validated = await ImportValidator.validating(
            candidate(in: directory, sessionID: sessionID),
            configuration: .init(missingTranscript: .reject, resolveCodexTab: nil)
        )

        #expect(validated.rejection == .unresolvableSession(sessionID))
        #expect(validated.agentTabCount == 1)
    }

    @Test func downgradePolicyTurnsTheTabIntoATerminal() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let validated = await ImportValidator.validating(
            candidate(in: directory),
            configuration: .init(missingTranscript: .downgradeToTerminal, resolveCodexTab: nil)
        )

        #expect(validated.isImportable)
        #expect(validated.agentTabCount == 0)
        #expect(validated.terminalTabCount == 1)
        #expect(validated.tabs.first?.agentSessionID == nil)
        #expect(validated.tabs.first?.title == nil)
    }

    private func makeRepository() throws -> String {
        let path = try makeDirectory().path
        try GitRunner.run(["init", "-b", "main"], in: path)
        try GitRunner.run(["config", "user.email", "test@example.com"], in: path)
        try GitRunner.run(["config", "user.name", "Test"], in: path)
        try GitRunner.run(["config", "commit.gpgsign", "false"], in: path)
        try "hello\n".write(toFile: "\(path)/README.md", atomically: true, encoding: .utf8)
        try GitRunner.run(["add", "."], in: path)
        try GitRunner.run(["commit", "-m", "init"], in: path)
        return path
    }

    private func terminalCandidate(directory: String) -> ImportCandidate {
        ImportCandidate(
            stableID: "test:wt",
            title: "Test",
            workingDirectoryPath: directory,
            groupName: nil,
            tabs: [ImportTabPlan(kind: .terminal, title: nil, workingDirectoryPath: nil, agentSessionID: nil, sessionJSONLPath: nil, permissionMode: nil)],
            workspace: ImportWorkspacePlan()
        )
    }

    private func validatedBranch(
        worktreeArguments: [String],
        readsBranchFromGit: Bool
    ) async throws -> String? {
        let repository = try makeRepository()
        let worktree = repository + "-wt"
        defer {
            try? FileManager.default.removeItem(atPath: repository)
            try? FileManager.default.removeItem(atPath: worktree)
        }
        try GitRunner.run(["worktree", "add"] + worktreeArguments.map { $0 == "PATH" ? worktree : $0 }, in: repository)
        let validated = await ImportValidator.validating(
            terminalCandidate(directory: worktree),
            configuration: .init(missingTranscript: .downgradeToTerminal, resolveCodexTab: nil, readsBranchFromGit: readsBranchFromGit)
        )
        #expect(validated.workspace.kind == .worktree)
        return validated.workspace.branchName
    }

    @Test func aSourceThatReadsGitGetsTheWorktreesBranch() async throws {
        let branch = try await validatedBranch(worktreeArguments: ["-b", "feature", "PATH"], readsBranchFromGit: true)
        #expect(branch == "feature")
    }

    @Test func aDetachedWorktreeHasNoBranch() async throws {
        let branch = try await validatedBranch(worktreeArguments: ["--detach", "PATH"], readsBranchFromGit: true)
        #expect(branch == nil)
    }

    @Test func aSourceThatDoesNotReadGitLeavesTheBranchUnset() async throws {
        let branch = try await validatedBranch(worktreeArguments: ["-b", "feature", "PATH"], readsBranchFromGit: false)
        #expect(branch == nil)
    }
}
