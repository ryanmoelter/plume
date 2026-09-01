import Testing
import Foundation
@testable import Plume

/// Encoding rules here are checked against real `~/.claude/projects`
/// directory names.
struct SessionJSONLReaderTests {
    @Test func slashesBecomeDashes() {
        #expect(SessionJSONLReader.encodedProjectDirectory(for: "/Users/me/dev")
            == "-Users-me-dev")
    }

    /// A worktree under `.plume/` must resolve to its own transcript
    /// directory, not the parent repo's.
    @Test func hiddenDirectoriesProduceADoubleDash() {
        #expect(SessionJSONLReader.encodedProjectDirectory(for: "/Users/me/Repo/.plume/worktrees/x")
            == "-Users-me-Repo--plume-worktrees-x")
    }

    @Test func aWorktreeDiffersFromItsParentRepository() {
        let repo = SessionJSONLReader.encodedProjectDirectory(for: "/Users/me/Repo")
        let worktree = SessionJSONLReader.encodedProjectDirectory(for: "/Users/me/Repo/.plume/worktrees/x")
        #expect(repo != worktree)
    }

    @Test func trailingSlashesAreIgnored() {
        #expect(SessionJSONLReader.encodedProjectDirectory(for: "/Users/me/dev/")
            == SessionJSONLReader.encodedProjectDirectory(for: "/Users/me/dev"))
    }

    @Test func transcriptPathCombinesProjectAndSession() {
        let path = SessionJSONLReader.transcriptPath(
            workingDirectory: "/Users/me/dev", sessionID: "abc-123"
        )
        #expect(path.hasSuffix("/.claude/projects/-Users-me-dev/abc-123.jsonl"))
    }

    /// The hook payload's own path wins over anything derived.
    @Test func hookProvidedPathIsAuthoritative() {
        let resolved = SessionJSONLReader.resolveTranscriptPath(
            hookProvided: "/explicit/path.jsonl",
            workingDirectory: "/Users/me/dev",
            sessionID: "abc"
        )
        #expect(resolved == "/explicit/path.jsonl")
    }

    @Test func fallsBackToDerivingFromTheWorkingDirectory() {
        let resolved = SessionJSONLReader.resolveTranscriptPath(
            hookProvided: nil, workingDirectory: "/Users/me/dev", sessionID: "abc"
        )
        #expect(resolved?.hasSuffix("-Users-me-dev/abc.jsonl") == true)
    }

    @Test func emptyHookPathFallsThrough() {
        let resolved = SessionJSONLReader.resolveTranscriptPath(
            hookProvided: "", workingDirectory: "/Users/me/dev", sessionID: "abc"
        )
        #expect(resolved?.hasSuffix("-Users-me-dev/abc.jsonl") == true)
    }

    @Test func withoutASessionThereIsNoPath() {
        #expect(SessionJSONLReader.resolveTranscriptPath(
            hookProvided: nil, workingDirectory: "/Users/me/dev", sessionID: nil
        ) == nil)
        #expect(SessionJSONLReader.resolveTranscriptPath(
            hookProvided: nil, workingDirectory: nil, sessionID: "abc"
        ) == nil)
    }

    @Test func modificationTimeIsReadableAndAbsentForMissingFiles() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "plume-jsonl-\(UUID().uuidString).jsonl")
        try "{}\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(SessionJSONLReader.exists(atPath: url.path))
        #expect(SessionJSONLReader.lastModified(atPath: url.path) != nil)
        #expect(SessionJSONLReader.lastModified(atPath: "/nope/missing.jsonl") == nil)
    }

    /// Encoding a directory that Claude Code has actually run in must name an
    /// existing transcript directory. Catches a change to Claude Code's
    /// encoding scheme, which is otherwise invisible until chat rendering
    /// silently reads nothing.
    @Test func encodingResolvesADirectoryClaudeCodeHasUsed() throws {
        let existing = Set((try? FileManager.default.contentsOfDirectory(
            atPath: SessionJSONLReader.projectsDirectory.path
        )) ?? [])
        try #require(!existing.isEmpty, "no transcript directories on this machine")

        // Derive the repo from this file's own path rather than the cwd,
        // which for a test host is `/`.
        let repositoryPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PlumeTests
            .deletingLastPathComponent()  // repo root
            .path

        let encoded = SessionJSONLReader.encodedProjectDirectory(for: repositoryPath)
        #expect(
            existing.contains(encoded),
            "encoded \(repositoryPath) as \(encoded), which is not among the real transcript directories"
        )
    }
}
