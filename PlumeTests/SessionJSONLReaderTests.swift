import Testing
import Foundation
@testable import Plume

/// Encoding rules here are checked against real `~/.claude/projects`
/// directory names: the anonymized sample in `Fixtures/Corpus`, and this
/// machine's own where Claude Code has run in this checkout.
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

    /// A working directory Claude Code has run in, and the projects folder
    /// holding the transcripts it wrote there.
    struct RecordedDirectory: Sendable, CustomTestStringConvertible {
        let cwd: String
        let projectsDirectory: URL
        let testDescription: String
    }

    /// The fixture sample's repository and its worktree under a hidden folder,
    /// everywhere; and this checkout, where Claude Code has run in it on this
    /// machine. A worktree, or a machine that has only just cloned the repo, has
    /// no transcript directory to match yet.
    static let recordedDirectories: [RecordedDirectory] = {
        let fixtures = ClaudeCorpus.fixtures.projectsDirectory
        var recorded = [
            RecordedDirectory(
                cwd: "/Users/dev/projects/sample-app",
                projectsDirectory: fixtures,
                testDescription: "fixture repository"
            ),
            RecordedDirectory(
                cwd: "/Users/dev/projects/sample-app/.worktrees/feature-two",
                projectsDirectory: fixtures,
                testDescription: "fixture worktree"
            ),
        ]

        // Derive the repo from this file's own path rather than the cwd,
        // which for a test host is `/`.
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PlumeTests
            .deletingLastPathComponent()  // repo root
            .path
        let live = ClaudeCorpus.thisMac.projectsDirectory
        if !transcriptDirectories(recordingCWD: checkout, in: live).isEmpty {
            recorded.append(RecordedDirectory(
                cwd: checkout, projectsDirectory: live, testDescription: "this checkout"
            ))
        }
        return recorded
    }()

    /// Encoding a directory that Claude Code has actually run in must name the
    /// transcript directory holding its sessions. Catches a change to Claude
    /// Code's encoding scheme, which is otherwise invisible until chat
    /// rendering silently reads nothing.
    @Test(arguments: SessionJSONLReaderTests.recordedDirectories)
    func encodingResolvesADirectoryClaudeCodeHasUsed(_ recorded: RecordedDirectory) throws {
        // Claude Code stamps each transcript with the cwd it ran in. Finding the
        // directory that way is independent of the encoding under test, so the
        // assertion below still has teeth.
        let owningDirectories = Self.transcriptDirectories(
            recordingCWD: recorded.cwd, in: recorded.projectsDirectory
        )
        try #require(
            !owningDirectories.isEmpty,
            "no transcript in \(recorded.projectsDirectory.path) records \(recorded.cwd)"
        )

        let encoded = SessionJSONLReader.encodedProjectDirectory(for: recorded.cwd)
        #expect(
            owningDirectories.contains(encoded),
            "encoded \(recorded.cwd) as \(encoded), but its transcripts live in \(owningDirectories.sorted())"
        )
    }

    /// Names of the transcript directories holding a session whose recorded
    /// `cwd` is `path`. An agent working in a worktree still records the parent
    /// repository's `cwd`, so more than one directory can own the same path.
    private static func transcriptDirectories(recordingCWD path: String, in root: URL) -> Set<String> {
        let directories = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var found: Set<String> = []
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
                        if cwd == path { found.insert(directory) }
                        break
                    }
                }
            }
        }
        return found
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

    @Test func theLastCustomTitleIsRead() {
        let lines = data([
            #"{"type":"custom-title","customTitle":"First name","sessionId":"a"}"#,
            #"{"type":"ai-title","aiTitle":"Generated","sessionId":"a"}"#,
            #"{"type":"custom-title","customTitle":"Second name","sessionId":"a"}"#,
        ])
        #expect(SessionJSONLReader.latestCustomTitle(in: lines) == "Second name")
        #expect(SessionJSONLReader.latestAITitle(in: lines) == "Generated")
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
