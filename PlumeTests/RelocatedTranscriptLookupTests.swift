import Testing
import Foundation
@testable import Plume

/// `EnterWorktree` moves a live transcript into a project directory keyed by
/// the worktree's path while keeping the session id, so the path derived from
/// the task's original folder stops being written to. These cover finding the
/// session again by id alone.
struct RelocatedTranscriptLookupTests {
    private func makeProjectsDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, session: String, project: String, in root: URL) throws {
        let directory = root.appending(path: project)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(
            to: directory.appending(path: "\(session).jsonl"), atomically: true, encoding: .utf8
        )
    }

    @Test func findsASessionInADirectoryTheCallerCannotDerive() throws {
        let root = try makeProjectsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID().uuidString
        try write("{}\n", session: session, project: "-Users-me-Repo--worktrees-x", in: root)

        #expect(SessionJSONLReader.locateTranscript(sessionID: session, inProjectsDirectory: root)
            == root.appending(path: "-Users-me-Repo--worktrees-x/\(session).jsonl").path)
    }

    @Test func returnsNilForAnUnknownSession() throws {
        let root = try makeProjectsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("{}\n", session: UUID().uuidString, project: "-Users-me-Repo", in: root)

        #expect(SessionJSONLReader.locateTranscript(
            sessionID: UUID().uuidString, inProjectsDirectory: root
        ) == nil)
    }

    /// `FileWatcher` recreates the file it watches, so a moved-away transcript
    /// leaves a zero-byte stub at the old path.
    @Test func ignoresTheEmptyStubLeftBehindByTheMove() throws {
        let root = try makeProjectsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID().uuidString
        try write("", session: session, project: "-Users-me-Repo", in: root)
        try write("{}\n", session: session, project: "-Users-me-Repo--worktrees-x", in: root)

        #expect(SessionJSONLReader.locateTranscript(sessionID: session, inProjectsDirectory: root)
            == root.appending(path: "-Users-me-Repo--worktrees-x/\(session).jsonl").path)
    }

    @Test func rejectsASessionIDThatWouldEscapeTheProjectsDirectory() throws {
        let root = try makeProjectsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(SessionJSONLReader.locateTranscript(sessionID: "../secret", inProjectsDirectory: root) == nil)
        #expect(SessionJSONLReader.locateTranscript(sessionID: "", inProjectsDirectory: root) == nil)
    }

    @Test func resolutionPrefersTheDerivedPathWhenItHasContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = UUID().uuidString
        let derived = SessionJSONLReader.transcriptPath(
            workingDirectory: directory.path, sessionID: session
        )
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: derived).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}\n".write(toFile: derived, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: derived).deletingLastPathComponent()
            )
        }

        #expect(SessionJSONLReader.resolvedTranscriptPath(
            workingDirectory: directory.path, sessionID: session
        ) == derived)
    }

    /// Nothing is written anywhere yet, so the tab must keep waiting on the
    /// path Claude Code is about to create rather than be sent elsewhere.
    @Test func resolutionFallsBackToTheDerivedPathWhenNothingIsWritten() {
        let session = UUID().uuidString
        let derived = SessionJSONLReader.transcriptPath(
            workingDirectory: "/tmp/plume-nonexistent-\(session)", sessionID: session
        )

        #expect(SessionJSONLReader.resolvedTranscriptPath(
            workingDirectory: "/tmp/plume-nonexistent-\(session)", sessionID: session
        ) == derived)
    }

    @Test func anEmptyFileDoesNotCountAsContent() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(SessionJSONLReader.exists(atPath: url.path))
        #expect(!SessionJSONLReader.hasContent(atPath: url.path))
    }
}
