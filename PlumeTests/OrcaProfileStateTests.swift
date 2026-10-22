import Testing
import Foundation
import SQLite3
@testable import Plume

/// Where an Orca import reads its state from: `profile-state.db` first,
/// including rows still only in its WAL, and `orca-data.json` only when the
/// database does not exist.
struct OrcaProfileStateTests {
    private static let domains = ["repos", "worktreeMeta", "workspaceSession"]

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orca-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Splits a fixture's top-level sections into domain rows, as Orca stores them.
    private func rows(fromFixture name: String, domainVersion: Int = 1) throws -> [(String, Int, String)] {
        let object = try #require(try JSONSerialization.jsonObject(with: OrcaParsingTests.fixture(name)) as? [String: Any])
        var rows: [(String, Int, String)] = [("schemaVersion", 1, "1")]
        for domain in Self.domains {
            let value = try #require(object[domain])
            let payload = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
            rows.append((domain, domainVersion, payload))
        }
        return rows
    }

    /// With checkpointing off and the connection still open while the reader
    /// runs, every row lives only in the `-wal` file, as it does while Orca runs.
    private func withDatabase<T>(
        at url: URL,
        rows: [(String, Int, String)],
        _ body: () throws -> T
    ) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw DatabaseError.open }
        defer { sqlite3_close(db) }
        let schema = """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE profile_state_documents (
              domain TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL,
              domain_version INTEGER NOT NULL, revision INTEGER NOT NULL,
              updated_at INTEGER NOT NULL, content_hash TEXT NOT NULL);
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw DatabaseError.exec }
        for (domain, version, payload) in rows {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO profile_state_documents VALUES (?, ?, ?, 1, 0, '')", -1, &statement, nil) == SQLITE_OK
            else { throw DatabaseError.exec }
            sqlite3_bind_text(statement, 1, domain, -1, Self.transient)
            sqlite3_bind_text(statement, 2, payload, -1, Self.transient)
            sqlite3_bind_int(statement, 3, Int32(version))
            let stepped = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard stepped == SQLITE_DONE else { throw DatabaseError.exec }
        }
        return try body()
    }

    private func load(database: URL, dataFile: URL) -> OrcaSnapshot {
        OrcaSnapshot.loading(profileStateFile: database, dataFile: dataFile, claudeSessionIDs: [:], paneStatus: [:])
    }

    @Test func theDatabaseIsReadEvenWhenItsRowsAreOnlyInTheWAL() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("profile-state.db")
        let dataFile = directory.appendingPathComponent("orca-data.json")
        // A stale export that disagrees with the database, which must lose.
        try OrcaParsingTests.fixture("data-panes").write(to: dataFile)

        let snapshot = try withDatabase(at: database, rows: try rows(fromFixture: "data-basic")) {
            #expect(FileManager.default.fileExists(atPath: database.path + "-wal"))
            return load(database: database, dataFile: dataFile)
        }
        let fromFile = OrcaSnapshot.decoding(data: try OrcaParsingTests.fixture("data-basic"), claudeSessionIDs: [:])
        #expect(snapshot.worktrees.map(\.worktreeID) == fromFile.worktrees.map(\.worktreeID))
        #expect(snapshot.worktrees.first?.displayName == "Feature work")
    }

    @Test func aDomainOfAnotherVersionIsUnsupported() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("profile-state.db")
        let dataFile = directory.appendingPathComponent("orca-data.json")
        try OrcaParsingTests.fixture("data-basic").write(to: dataFile)

        let snapshot = try withDatabase(at: database, rows: try rows(fromFixture: "data-basic", domainVersion: 2)) {
            load(database: database, dataFile: dataFile)
        }
        #expect(snapshot.isUnsupportedSchema)
        #expect(snapshot.worktrees.isEmpty)
    }

    @Test func withoutADatabaseTheDataFileIsRead() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dataFile = directory.appendingPathComponent("orca-data.json")
        try OrcaParsingTests.fixture("data-panes").write(to: dataFile)

        let snapshot = load(database: directory.appendingPathComponent("profile-state.db"), dataFile: dataFile)
        #expect(snapshot.worktrees.map(\.worktreeID) == ["repo-widgets::/Users/example/Widgets"])
    }

    @Test func aDatabaseWithoutTheDocumentsTableIsUnreadableAndIgnoresTheDataFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("profile-state.db")
        let dataFile = directory.appendingPathComponent("orca-data.json")
        try OrcaParsingTests.fixture("data-panes").write(to: dataFile)
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw DatabaseError.open }
        sqlite3_exec(db, "CREATE TABLE other (x TEXT);", nil, nil, nil)
        sqlite3_close(db)

        let snapshot = load(database: database, dataFile: dataFile)
        #expect(snapshot.worktrees.isEmpty)
        #expect(snapshot.isUnreadable)
    }

    @Test func aDatabaseThatIsNotSQLiteIsUnreadable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("profile-state.db")
        let dataFile = directory.appendingPathComponent("orca-data.json")
        try OrcaParsingTests.fixture("data-panes").write(to: dataFile)
        try Data("not a database, and long enough that sqlite does not mistake it for an empty file".utf8).write(to: database)

        let snapshot = load(database: database, dataFile: dataFile)
        #expect(snapshot.worktrees.isEmpty)
        #expect(snapshot.isUnreadable)
    }

    @Test func neitherFileYieldsNothing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = load(
            database: directory.appendingPathComponent("profile-state.db"),
            dataFile: directory.appendingPathComponent("orca-data.json")
        )
        #expect(snapshot.worktrees.isEmpty)
        #expect(!snapshot.isUnsupportedSchema)
    }

    // MARK: - Codex rollouts

    private func writeRollout(in sessions: URL, sessionID: String, cwd: String) throws -> URL {
        let day = sessions.appendingPathComponent("2026/10/21")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let url = day.appendingPathComponent("rollout-2026-10-21T10-00-00-\(sessionID).jsonl")
        let line = #"{"timestamp":"2026-10-21T10:00:00Z","type":"session_meta","payload":{"id":"\#(sessionID)","cwd":"\#(cwd)"}}"#
        try Data((line + "\n").utf8).write(to: url)
        return url
    }

    private func codexTab(sessionID: String, recorded: String?, directory: String) -> ImportTabPlan {
        ImportTabPlan(
            kind: .agent, title: "Build", workingDirectoryPath: directory,
            agentSessionID: sessionID, sessionJSONLPath: recorded, permissionMode: nil, provider: .codex
        )
    }

    /// Orca recorded the rollout under its own `CODEX_HOME`; the copy in
    /// Plume's sessions directory is the one that counts.
    @Test func aCodexPaneResolvesThroughPlumesSessionsDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = directory.appendingPathComponent("codex/sessions")
        let orcaHome = directory.appendingPathComponent("orca-codex/sessions")
        let orcaRollout = try writeRollout(in: orcaHome, sessionID: "thread-1", cwd: "/Users/example/Widgets")
        _ = try writeRollout(in: sessions, sessionID: "thread-1", cwd: "/Users/example/Widgets")

        let resolved = OrcaImportValidator.resolvingCodexTab(
            codexTab(sessionID: "thread-1", recorded: orcaRollout.path, directory: "/Users/example/Widgets"),
            rollouts: CodexRolloutIndex(sessionsDirectory: sessions)
        )
        #expect(resolved.kind == .agent)
        #expect(resolved.provider == .codex)
        #expect(resolved.agentSessionID == "thread-1")
        #expect(resolved.sessionJSONLPath == nil)
    }

    @Test func aCodexPaneWhoseRolloutPlumeCannotSeeBecomesATerminal() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let orcaRollout = try writeRollout(in: directory.appendingPathComponent("orca-codex/sessions"), sessionID: "thread-2", cwd: "/w")

        let resolved = OrcaImportValidator.resolvingCodexTab(
            codexTab(sessionID: "thread-2", recorded: orcaRollout.path, directory: "/w"),
            rollouts: CodexRolloutIndex(sessionsDirectory: directory.appendingPathComponent("codex/sessions"))
        )
        #expect(resolved.kind == .terminal)
        #expect(resolved.agentSessionID == nil)
        #expect(resolved.title == nil)
    }

    @Test func aRolloutForAnotherDirectoryDoesNotCount() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = directory.appendingPathComponent("codex/sessions")
        _ = try writeRollout(in: sessions, sessionID: "thread-3", cwd: "/elsewhere")

        let path = CodexRollouts.rolloutPath(sessionID: "thread-3", recorded: nil, cwd: "/w", rollouts: CodexRolloutIndex(sessionsDirectory: sessions))
        #expect(path == nil)
    }

    @Test func aRolloutRecordedInsideTheWorktreeCounts() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessions = directory.appendingPathComponent("codex/sessions")
        _ = try writeRollout(in: sessions, sessionID: "thread-4", cwd: "/w/packages/app")
        _ = try writeRollout(in: sessions, sessionID: "thread-5", cwd: "/work")

        let index = CodexRolloutIndex(sessionsDirectory: sessions)
        #expect(CodexRollouts.rolloutPath(sessionID: "thread-4", recorded: nil, cwd: "/w", rollouts: index) != nil)
        #expect(CodexRollouts.rolloutPath(sessionID: "thread-5", recorded: nil, cwd: "/w", rollouts: index) == nil)
    }

    // MARK: - Running Orca

    @Test func daemonPIDsComeFromEveryPIDFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"pid": 456, "startedAtMs": 1792628693681.8}"#.utf8).write(to: directory.appendingPathComponent("daemon-v50.pid"))
        try Data(#"{"pid": 123}"#.utf8).write(to: directory.appendingPathComponent("daemon-v40.pid"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("daemon-v30.pid"))
        try Data(#"{"pid": 789}"#.utf8).write(to: directory.appendingPathComponent("daemon-v50.token"))

        #expect(OrcaRunningState.daemonPIDs(in: directory) == [123, 456])
    }

    @Test func orcaCountsAsRunningWhileTheAppOrADaemonTerminalIs() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"pid": 123}"#.utf8).write(to: directory.appendingPathComponent("daemon-v40.pid"))
        try Data(#"{"pid": 456}"#.utf8).write(to: directory.appendingPathComponent("daemon-v50.pid"))

        #expect(OrcaRunningState.isRunning(appIsRunning: false, daemonDirectory: directory) { $0 == 456 })
        #expect(OrcaRunningState.isRunning(appIsRunning: true, daemonDirectory: directory) { _ in false })
        #expect(!OrcaRunningState.isRunning(appIsRunning: false, daemonDirectory: directory) { _ in false })
        #expect(!OrcaRunningState.isRunning(appIsRunning: false, daemonDirectory: directory.appendingPathComponent("missing")) { _ in true })
    }

    @Test func aProcessWithAChildHasChildProcesses() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }
        #expect(OrcaRunningState.hasChildProcesses(getpid()))
        #expect(!OrcaRunningState.hasChildProcesses(child.processIdentifier))
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private enum DatabaseError: Error { case open, exec }
}
