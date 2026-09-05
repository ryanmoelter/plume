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

    /// Encoding a directory that Claude Code has actually run in must name the
    /// transcript directory holding its sessions. Catches a change to Claude
    /// Code's encoding scheme, which is otherwise invisible until chat
    /// rendering silently reads nothing.
    ///
    /// Skips where Claude Code has never run in this checkout — a worktree, or
    /// a machine that has only just cloned it — since no transcript directory
    /// exists to match yet.
    @Test func encodingResolvesADirectoryClaudeCodeHasUsed() throws {
        // Derive the repo from this file's own path rather than the cwd,
        // which for a test host is `/`.
        let repositoryPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PlumeTests
            .deletingLastPathComponent()  // repo root
            .path

        // Claude Code stamps each transcript with the cwd it ran in. Finding the
        // repo that way is independent of the encoding under test, so the
        // assertion below still has teeth.
        let owningDirectory = try #require(
            Self.transcriptDirectory(recordingCWD: repositoryPath),
            "Claude Code has not run in \(repositoryPath)"
        )

        let encoded = SessionJSONLReader.encodedProjectDirectory(for: repositoryPath)
        #expect(
            encoded == owningDirectory,
            "encoded \(repositoryPath) as \(encoded), but its transcripts live in \(owningDirectory)"
        )
    }

    /// Name of the transcript directory holding a session whose recorded `cwd`
    /// is `path`, or nil where Claude Code has never run there.
    private static func transcriptDirectory(recordingCWD path: String) -> String? {
        let root = SessionJSONLReader.projectsDirectory
        let directories = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for directory in directories {
            let sessions = (try? FileManager.default.contentsOfDirectory(
                atPath: root.appending(path: directory).path
            )) ?? []
            for session in sessions where session.hasSuffix(".jsonl") {
                // Transcripts reach hundreds of megabytes, and `cwd` rides the
                // opening lines, so read a prefix rather than the whole file.
                guard let handle = try? FileHandle(
                    forReadingFrom: root.appending(path: directory).appending(path: session)
                ) else { continue }
                defer { try? handle.close() }
                // Cutting at a fixed byte count can split a multi-byte
                // character, so decode only up to the last complete line.
                guard var prefix = try? handle.read(upToCount: 64 * 1024),
                      let lastNewline = prefix.lastIndex(of: UInt8(ascii: "\n"))
                else { continue }
                prefix = prefix[..<lastNewline]
                guard let text = String(data: prefix, encoding: .utf8) else { continue }

                for line in text.split(separator: "\n") {
                    guard let object = try? JSONSerialization.jsonObject(
                        with: Data(line.utf8)
                    ) as? [String: Any] else { continue }
                    if let cwd = object["cwd"] as? String {
                        if cwd == path { return directory }
                        break
                    }
                }
            }
        }
        return nil
    }
}

/// `ai-title` lines are the title Claude gives a session. Fixtures mirror
/// real transcripts in `~/.claude/projects`.
struct SessionAITitleTests {
    private func data(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    @Test func theTitleIsRead() {
        let found = SessionJSONLReader.latestAITitle(in: data([
            #"{"type":"user","message":{"role":"user"}}"#,
            #"{"type":"ai-title","aiTitle":"Plume v1 implementation","sessionId":"a"}"#,
        ]))
        #expect(found == "Plume v1 implementation")
    }

    /// Claude retitles a session as it develops, so the last one is current.
    @Test func theLastTitleWins() {
        let found = SessionJSONLReader.latestAITitle(in: data([
            #"{"type":"ai-title","aiTitle":"First guess","sessionId":"a"}"#,
            #"{"type":"assistant","message":{"role":"assistant"}}"#,
            #"{"type":"ai-title","aiTitle":"Sharper title","sessionId":"a"}"#,
        ]))
        #expect(found == "Sharper title")
    }

    /// Short sessions never get titled; that is not an error.
    @Test func aTranscriptWithoutATitleYieldsNil() {
        let found = SessionJSONLReader.latestAITitle(in: data([
            #"{"type":"user","message":{"role":"user"}}"#,
            #"{"type":"system","subtype":"init"}"#,
        ]))
        #expect(found == nil)
    }

    @Test func unknownLineTypesAreSkipped() {
        let found = SessionJSONLReader.latestAITitle(in: data([
            #"{"type":"ai-title","aiTitle":"Real title","sessionId":"a"}"#,
            #"{"type":"file-history-snapshot","snapshot":{"deep":[1,2,3]}}"#,
            #"{"type":"attachment","content":"whatever"}"#,
        ]))
        #expect(found == "Real title")
    }

    /// A half-written last line is normal while the agent is running.
    @Test func aMalformedLineDoesNotHideAnEarlierTitle() {
        let found = SessionJSONLReader.latestAITitle(in: data([
            #"{"type":"ai-title","aiTitle":"Real title","sessionId":"a"}"#,
            #"{"type":"assistant","message":{"role":"#,
        ]))
        #expect(found == "Real title")
    }

    @Test func anEmptyTitleIsIgnored() {
        let found = SessionJSONLReader.latestAITitle(in: data([
            #"{"type":"ai-title","aiTitle":"Real title","sessionId":"a"}"#,
            #"{"type":"ai-title","aiTitle":"","sessionId":"a"}"#,
        ]))
        #expect(found == "Real title")
    }

    @Test func agentNameLinesAreNotMistakenForTitles() {
        let found = SessionJSONLReader.latestAITitle(in: data([
            #"{"type":"agent-name","agentName":"Some agent","sessionId":"a"}"#,
        ]))
        #expect(found == nil)
    }

    @Test func aMissingFileYieldsNil() {
        #expect(SessionJSONLReader.latestAITitle(atPath: "/nonexistent/x.jsonl") == nil)
    }

    @Test func theTitleIsReadFromDisk() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "plume-title-\(UUID().uuidString).jsonl")
        try data([#"{"type":"ai-title","aiTitle":"From disk","sessionId":"a"}"#]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(SessionJSONLReader.latestAITitle(atPath: url.path) == "From disk")
    }
}

/// `bestAvailableTitle` covers a gap real transcripts hit: Claude Code's
/// auto-titling only fires for the interactive TUI, so a headless (`-p`)
/// conversation of any length never gets an `ai-title` line.
struct SessionBestAvailableTitleTests {
    private func write(_ lines: [String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "plume-best-title-\(UUID().uuidString).jsonl")
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        return url
    }

    @Test func anAITitleWinsOverTheFirstMessage() throws {
        let url = try write([
            #"{"type":"user","message":{"role":"user","content":"Fix the login bug"}}"#,
            #"{"type":"ai-title","aiTitle":"Fixing login","sessionId":"a"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(SessionJSONLReader.bestAvailableTitle(atPath: url.path) == "Fixing login")
    }

    @Test func withNoAITitleTheFirstUserMessageStandsIn() throws {
        let url = try write([
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"Fix the login bug"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(SessionJSONLReader.bestAvailableTitle(atPath: url.path) == "Fix the login bug")
    }

    @Test func withNeitherThereIsNoTitle() throws {
        let url = try write([
            #"{"type":"system","subtype":"init"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(SessionJSONLReader.bestAvailableTitle(atPath: url.path) == nil)
    }
}
