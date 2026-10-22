import Testing
import Foundation
import SQLite3
@testable import Plume

struct OrcaParsingTests {
    static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Orca/\(name).json")
        return try Data(contentsOf: url)
    }

    @Test func theBasicDataFileDecodes() throws {
        let file = try JSONDecoder().decode(OrcaDataFile.self, from: try Self.fixture("data-basic"))
        #expect(file.schemaVersion == 1)
        #expect(file.repos.map(\.displayName) == ["Widgets", "Gadgets"])
        #expect(file.worktreeMeta["repo-widgets::/Users/example/Widgets/.worktrees/feature"]?.displayName == "Feature work")
        #expect(file.workspaceSession?.tabGroups["repo-widgets::/Users/example/Widgets"]?.count == 2)
    }

    /// The fixture's root worktree holds a browser tab, a tab of a content
    /// type Plume has never seen, and a bare number among its tabs.
    @Test func unknownKeysAndTabTypesSurviveDecoding() throws {
        let file = try JSONDecoder().decode(OrcaDataFile.self, from: try Self.fixture("data-basic"))
        let tabs = try #require(file.workspaceSession?.unifiedTabs?["repo-widgets::/Users/example/Widgets"])
        #expect(tabs.count == 5)
        #expect(tabs.contains { $0.contentType == "hologram" })
    }

    @Test func aFlatTabGroupArrayIsKeyedByWorktree() throws {
        let json = #"{"tabGroups": [{"id": "g", "worktreeId": "r::/a", "tabOrder": ["x"]}]}"#
        let session = try JSONDecoder().decode(OrcaWorkspaceSession.self, from: Data(json.utf8))
        #expect(session.tabGroups["r::/a"]?.first?.tabOrder == ["x"])
    }

    @Test func anUnknownSchemaVersionYieldsNothing() throws {
        let snapshot = OrcaSnapshot.decoding(data: try Self.fixture("data-future-schema"), claudeSessionIDs: [:])
        #expect(snapshot.worktrees.isEmpty)
        #expect(snapshot.isUnsupportedSchema)
    }

    @Test func malformedDataYieldsNothing() {
        #expect(OrcaSnapshot.decoding(data: Data("not json".utf8), claudeSessionIDs: [:]).worktrees.isEmpty)
    }

    @Test func theProfileIndexPicksTheActiveProfile() throws {
        #expect(OrcaProfileIndex.activeProfileID(from: try Self.fixture("profile-index")) == "work-profile")
        #expect(OrcaLocations.dataFile(profileID: "work-profile").path.hasSuffix("orca/profiles/work-profile/orca-data.json"))
    }

    @Test func aMissingOrUnsafeProfileIndexFallsBackToTheDefaultProfile() {
        #expect(OrcaProfileIndex.activeProfileID(from: nil) == "local-default")
        #expect(OrcaProfileIndex.activeProfileID(from: Data(#"{"activeProfileId": "../x"}"#.utf8)) == "local-default")
    }

    @Test func aWorktreeIDSplitsOnTheFirstSeparatorOnly() {
        let parts = OrcaWorktreeView.split("repo::/Users/example/odd::name")
        #expect(parts.repoID == "repo")
        #expect(parts.path == "/Users/example/odd::name")
        #expect(OrcaWorktreeView.split("ephemeral-setup-terminal:onboarding").path == nil)
    }

    // MARK: - Agent journal

    @Test func theJournalMapsOrcaSessionsToTheirLatestClaudeSession() throws {
        let url = try Self.makeJournal(records: [
            ("claude_aaaa", Self.record(provider: "claude", sessionIDs: ["old-session", "new-session"])),
            ("codex_bbbb", Self.record(provider: "codex", sessionIDs: ["codex-thread"])),
            ("claude_cccc", "{ not json"),
            ("claude_dddd", Self.record(provider: "claude", sessionIDs: [])),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(OrcaAgentJournal.claudeSessionIDs(at: url) == ["claude_aaaa": "new-session"])
    }

    /// With checkpointing off and a connection still open, the record lives
    /// only in the `-wal` file, as it does while Orca runs. `immutable=1`
    /// never reads the log, so it would miss this record.
    @Test func aRecordStillInTheWALIsFound() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Orca WAL \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("agent-session-journal.db")

        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw JournalError.open }
        defer { sqlite3_close(db) }
        let json = Self.record(provider: "claude", sessionIDs: ["wal-session"]).replacingOccurrences(of: "'", with: "''")
        let sql = """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            \(Self.journalSchema)
            INSERT INTO agent_session_records VALUES ('claude_wal', '\(json)');
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw JournalError.exec }
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))

        #expect(OrcaAgentJournal.claudeSessionIDs(at: url) == ["claude_wal": "wal-session"])
    }

    @Test func aMissingJournalReadsAsEmpty() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString).db")
        #expect(OrcaAgentJournal.claudeSessionIDs(at: url).isEmpty)
    }

    @Test func aJournalWithoutTheRecordsTableReadsAsEmpty() throws {
        let url = try Self.makeJournal(records: [], schema: "CREATE TABLE other (x TEXT);")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(OrcaAgentJournal.claudeSessionIDs(at: url).isEmpty)
    }

    private static func record(provider: String, sessionIDs: [String]) -> String {
        let links = sessionIDs.enumerated().map { index, id in
            #"{"linkId": "link-\#(index)", "handle": {"provider": "\#(provider)", "sessionId": "\#(id)", "leafUuid": null}, "origin": "created"}"#
        }
        return #"{"schemaVersion": 1, "provider": "\#(provider)", "providerHandleChain": [\#(links.joined(separator: ","))]}"#
    }

    /// Mirrors the two tables of Orca 1.4's journal that the import touches.
    private static let journalSchema = """
        CREATE TABLE agent_session_records (session_id TEXT PRIMARY KEY, record_json TEXT NOT NULL);
        CREATE TABLE agent_session_tabs (tab_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, position INTEGER NOT NULL);
        """

    // The directory name has a space, as Orca's real one does, to exercise URI escaping.
    private static func makeJournal(records: [(String, String)], schema: String = journalSchema) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Orca Journal \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("agent-session-journal.db")

        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw JournalError.open }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw JournalError.exec }

        for (sessionID, json) in records {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO agent_session_records VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK
            else { throw JournalError.exec }
            sqlite3_bind_text(statement, 1, sessionID, -1, Self.transient)
            sqlite3_bind_text(statement, 2, json, -1, Self.transient)
            let stepped = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard stepped == SQLITE_DONE else { throw JournalError.exec }
        }
        return url
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private enum JournalError: Error { case open, exec }
}
