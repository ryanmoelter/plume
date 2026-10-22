import Testing
import Foundation
@testable import Plume

/// The Claude desktop app's session files: which ones count, how they group,
/// and how a lenient decode treats a layout Plume does not recognize. Fixtures
/// have the shape of real files with synthetic values.
struct ClaudeDesktopImportTests {
    private static let worktreeSession = """
    {"sessionId":"local_wt","cliSessionId":"11111111-2222-3333-4444-555555555555",
     "cwd":"/Users/example/Widgets/.claude/worktrees/feature","originCwd":"/Users/example/Widgets",
     "worktreePath":"/Users/example/Widgets/.claude/worktrees/feature","worktreeName":"feature",
     "branch":"claude/feature","sourceBranch":"main","createdAt":1,"lastActivityAt":2000,
     "model":"m","isArchived":false,"title":"Add the feature","titleSource":"auto","permissionMode":"auto",
     "remoteMcpServersConfig":[],"alwaysAllowedReasons":[]}
    """

    private static let plainSession = """
    {"sessionId":"local_plain","cliSessionId":"66666666-7777-8888-9999-000000000000",
     "cwd":"/Users/example/Gadgets","originCwd":"/Users/example/Gadgets","lastActivityAt":3000,
     "isArchived":false,"title":"","permissionMode":"default"}
    """

    private func makeLayout(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-desktop-\(UUID().uuidString)")
        for (relativePath, contents) in files {
            let url = root.appending(path: relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    private func load(_ files: [String: String]) throws -> ClaudeDesktopSnapshot {
        let root = try makeLayout(files)
        defer { try? FileManager.default.removeItem(at: root) }
        return ClaudeDesktopSnapshot.loadingFromDisk(sessionsDirectory: root)
    }

    @Test func everyAccountAndOrganizationIsScannedNewestFirst() throws {
        let snapshot = try load([
            "acct1/org1/local_wt.json": Self.worktreeSession,
            "acct2/org9/local_plain.json": Self.plainSession,
        ])
        #expect(snapshot.sessions.map(\.sessionID) == ["local_plain", "local_wt"])
    }

    @Test func archivedSessionsAreLeftOutByFlagAndByIndex() throws {
        let flagged = Self.plainSession.replacingOccurrences(of: #""isArchived":false"#, with: #""isArchived":true"#)
        let indexed = Self.worktreeSession
        let snapshot = try load([
            "a/o/local_plain.json": flagged,
            "a/o/local_wt.json": indexed,
            "a/o/local_kept.json": Self.plainSession.replacingOccurrences(of: "local_plain", with: "local_kept"),
            "a/o/archived-sessions.idx": #"{"v":1,"archived":["local_wt"]}"#,
        ])
        #expect(snapshot.sessions.map(\.sessionID) == ["local_kept"])
    }

    @Test func aMissingSessionIDFallsBackToTheFileName() throws {
        let snapshot = try load(["a/o/local_abc.json": #"{"cliSessionId":"x","cwd":"/tmp/x"}"#])
        #expect(snapshot.sessions.first?.sessionID == "local_abc")
    }

    @Test func malformedFilesAreCountedAndWrongTypedFieldsReadAsAbsent() throws {
        let snapshot = try load([
            "a/o/local_bad.json": "not json",
            "a/o/local_odd.json": #"{"sessionId":"local_odd","cwd":7,"title":["x"],"isArchived":"yes"}"#,
        ])
        #expect(snapshot.unreadableCount == 1)
        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions[0].cwd == nil)
        #expect(snapshot.sessions[0].isArchived == false)
    }

    @Test func anUnrecognizedLayoutIsFlaggedAndEmpty() throws {
        let missing = ClaudeDesktopSnapshot.loadingFromDisk(
            sessionsDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        )
        #expect(missing.isLayoutUnrecognized)
        #expect(missing.sessions.isEmpty)
        let flat = try load(["local_flat.json": Self.plainSession])
        #expect(flat.isLayoutUnrecognized)
        #expect(flat.sessions.isEmpty)
    }

    @Test func aWorktreeSessionGroupsByItsRepoAndKeepsItsDetails() throws {
        let session = try JSONDecoder().decode(ClaudeDesktopSession.self, from: Data(Self.worktreeSession.utf8))
        let candidate = try #require(ClaudeDesktopCandidateBuilder.candidate(for: session))
        #expect(candidate.stableID == "claude-desktop:local_wt")
        #expect(candidate.title == "Add the feature")
        #expect(candidate.groupName == "Widgets")
        #expect(candidate.workingDirectoryPath == "/Users/example/Widgets/.claude/worktrees/feature")
        #expect(candidate.workspace.branchName == "claude/feature")
        #expect(candidate.rejection == nil)
        let tab = try #require(candidate.tabs.first)
        #expect(tab.kind == .agent)
        #expect(tab.agentSessionID == "11111111-2222-3333-4444-555555555555")
        #expect(tab.permissionMode == .auto)
    }

    @Test func aBlankTitleFallsBackToTheFolderAndDefaultModeIsManual() throws {
        let session = try JSONDecoder().decode(ClaudeDesktopSession.self, from: Data(Self.plainSession.utf8))
        let candidate = try #require(ClaudeDesktopCandidateBuilder.candidate(for: session))
        #expect(candidate.title == "Gadgets")
        #expect(candidate.tabs.first?.permissionMode == .manual)
    }

    @Test func aSessionWithNoFolderOrConversationIsRefused() throws {
        let noFolder = ClaudeDesktopSession(sessionID: "local_a", cliSessionID: "c", cwd: nil)
        #expect(ClaudeDesktopCandidateBuilder.candidate(for: noFolder)?.rejection == .noWorkingDirectory)
        let noConversation = ClaudeDesktopSession(sessionID: "local_b", cliSessionID: nil, cwd: "/tmp/x")
        #expect(ClaudeDesktopCandidateBuilder.candidate(for: noConversation)?.rejection == .nothingToImport)
        #expect(ClaudeDesktopCandidateBuilder.candidate(for: ClaudeDesktopSession(sessionID: nil, cliSessionID: "c", cwd: "/tmp/x")) == nil)
    }

    @Test func aMissingTranscriptDowngradesTheRowToATerminal() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "claude-desktop-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = ClaudeDesktopSession(sessionID: "local_a", cliSessionID: UUID().uuidString, cwd: directory.path)
        let candidate = try #require(ClaudeDesktopCandidateBuilder.candidate(for: session))

        let validated = await ImportSource.claudeDesktop.makeValidator().validating(candidate)

        #expect(validated.rejection == nil)
        #expect(validated.tabs.map(\.kind) == [.terminal])
    }
}
