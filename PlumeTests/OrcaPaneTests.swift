import Testing
import Foundation
@testable import Plume

/// How an Orca terminal tab becomes one Plume tab per pane, in split order,
/// and which saved record decides whether a pane resumes an agent: the pane's
/// hook status when it is fresh and not `done`, even if it cannot be resumed,
/// else its sleeping record.
struct OrcaPaneTests {
    private static let worktreeID = "repo-widgets::/Users/example/Widgets"

    private func tabs(paneStatus: [String: OrcaLastStatus.Status] = [:]) throws -> [ImportTabPlan] {
        let snapshot = OrcaSnapshot.decoding(
            data: try OrcaParsingTests.fixture("data-panes"),
            claudeSessionIDs: [:],
            paneStatus: paneStatus
        )
        let candidate = try #require(OrcaCandidateBuilder.candidates(from: snapshot).first)
        #expect(candidate.stableID == "orca:\(Self.worktreeID)")
        return candidate.tabs
    }

    private func status(_ sessionID: String, agent: String = "claude") -> OrcaLastStatus.Status {
        .resumable(OrcaAgentSession(agent: agent, sessionID: sessionID, transcriptPath: nil, source: .lastStatus))
    }

    /// The split tab's tree is ((a | b) / c), so a, b, c; pane c carries a
    /// title of its own. The unlaid tab has no saved layout at all.
    @Test func eachPaneBecomesATabInSplitOrder() throws {
        #expect(try tabs().map(\.title) == ["Build", "Build (2)", "Logs", "Shell", "Remote", "Bare"])
    }

    @Test func leafIDsWalkFirstChildrenFirst() {
        let tree = OrcaPaneNode.split(
            first: .leaf(id: "1"),
            second: .split(first: .split(first: .leaf(id: "2"), second: .leaf(id: "3")), second: .leaf(id: "4"))
        )
        #expect(tree.leafIDs == ["1", "2", "3", "4"])
    }

    @Test func aSleepingClaudeRecordBecomesAClaudeAgentWithItsTranscript() throws {
        let pane = try tabs()[0]
        #expect(pane.kind == .agent)
        #expect(pane.provider == .claudeCode)
        #expect(pane.agentSessionID == "sleeping-claude")
        #expect(pane.sessionJSONLPath == "/Users/example/.claude/projects/-Users-example-Widgets/sleeping-claude.jsonl")
    }

    @Test func aSleepingCodexRecordBecomesACodexAgent() throws {
        let pane = try tabs()[1]
        #expect(pane.kind == .agent)
        #expect(pane.provider == .codex)
        #expect(pane.agentSessionID == "codex-thread")
    }

    @Test func anAgentPlumeCannotRunStaysATerminal() throws {
        let pane = try tabs()[2]
        #expect(pane.kind == .terminal)
        #expect(pane.agentSessionID == nil)
    }

    @Test func aLiveLastStatusBeatsTheSleepingRecord() throws {
        let pane = try tabs(paneStatus: ["tab-split:leaf-a": status("status-claude")])[0]
        #expect(pane.agentSessionID == "status-claude")
    }

    @Test func theSleepingRecordStandsInForAMissingOrDoneLastStatus() throws {
        #expect(try tabs()[0].agentSessionID == "sleeping-claude")
        let data = lastStatus(entries: ["tab-split:leaf-a": entry(id: "done-claude", state: "done")])
        let paneStatus = OrcaLastStatus.statuses(from: data, now: Self.now)
        #expect(try tabs(paneStatus: paneStatus)[0].agentSessionID == "sleeping-claude")
    }

    /// The sleeping record for leaf d keys its session by `conversation_id`,
    /// which Claude cannot resume by, so the hook status stands in.
    @Test func lastStatusStandsInForAnUnresumableSleepingRecord() throws {
        #expect(try tabs()[3].kind == .terminal)
        let pane = try tabs(paneStatus: ["tab-single:leaf-d": status("status-claude")])[3]
        #expect(pane.kind == .agent)
        #expect(pane.agentSessionID == "status-claude")
    }

    /// Orca resumes nothing from a pane whose live status cannot be resumed,
    /// rather than falling back to the sleeping record.
    @Test func anUnresumableLiveStatusBlocksTheSleepingRecord() throws {
        #expect(try tabs()[0].kind == .agent)
        let data = lastStatus(entries: ["tab-split:leaf-a": entry(id: "remote", connectionID: #""ssh-devbox""#)])
        let paneStatus = OrcaLastStatus.statuses(from: data, now: Self.now)
        let pane = try tabs(paneStatus: paneStatus)[0]
        #expect(pane.kind == .terminal)
        #expect(pane.agentSessionID == nil)
    }

    @Test func aCustomPaneTitleBeatsTheTabTitleOnTheFirstPane() throws {
        let json = """
        {"schemaVersion": 1, "workspaceSession": {
          "unifiedTabs": {"r::/Users/example/W": [{"id": "t", "entityId": "t", "contentType": "terminal", "label": "Build"}]},
          "terminalLayoutsByTabId": {"t": {
            "root": {"type": "split", "first": {"type": "leaf", "leafId": "a"}, "second": {"type": "leaf", "leafId": "b"}},
            "titlesByLeafId": {"a": "Server"}}}}}
        """
        let snapshot = OrcaSnapshot.decoding(data: Data(json.utf8), claudeSessionIDs: [:])
        #expect(OrcaCandidateBuilder.candidates(from: snapshot).first?.tabs.map(\.title) == ["Server", "Build (2)"])
    }

    @Test func aPaneOnAnotherMachineStaysATerminal() throws {
        #expect(try tabs()[4].kind == .terminal)
    }

    @Test func aPaneWithoutASessionIsATerminal() throws {
        let pane = try tabs()[5]
        #expect(pane.kind == .terminal)
        #expect(pane.agentSessionID == nil)
    }

    @Test func theResolverRecordsWhereASessionCameFrom() throws {
        let file = try JSONDecoder().decode(OrcaDataFile.self, from: try OrcaParsingTests.fixture("data-panes"))
        let resolver = OrcaPaneResolver(
            layouts: file.workspaceSession?.terminalLayoutsByTabId ?? [:],
            sleepingAgents: file.workspaceSession?.sleepingAgentSessionsByPaneKey ?? [:],
            paneStatus: ["tab-single:leaf-d": status("status-claude")]
        )
        #expect(resolver.session(forPaneKey: "tab-split:leaf-a")?.source == .sleepingAgent)
        #expect(resolver.session(forPaneKey: "tab-single:leaf-d")?.source == .lastStatus)
        #expect(file.workspaceSession?.terminalLayoutsByTabId["tab-broken"] == nil)
    }

    // MARK: - Last status

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let nowMilliseconds = now.timeIntervalSince1970 * 1000

    private func lastStatus(version: Int = 2, entries: [String: String]) -> Data {
        let body = entries.map { #""\#($0)": \#($1)"# }.joined(separator: ",")
        return Data(#"{"version": \#(version), "entries": {\#(body)}}"#.utf8)
    }

    private func entry(
        id: String,
        agent: String = "claude",
        state: String = "working",
        key: String = "session_id",
        ageDays: Double = 0,
        connectionID: String = "null"
    ) -> String {
        let receivedAt = Self.nowMilliseconds - ageDays * 24 * 60 * 60 * 1000
        return #"{"providerSession": {"key": "\#(key)", "id": "\#(id)"}, "payload": {"agentType": "\#(agent)", "state": "\#(state)"}, "receivedAt": \#(receivedAt), "connectionId": \#(connectionID)}"#
    }

    @Test func lastStatusKeepsAFreshLocalEntry() {
        let sessions = OrcaLastStatus.statuses(
            from: lastStatus(entries: ["t:a": entry(id: "fresh", ageDays: 6.9), "t:b": entry(id: "thread", agent: "codex", state: "waiting")]),
            now: Self.now
        )
        #expect(sessions["t:a"]?.session?.sessionID == "fresh")
        #expect(sessions["t:a"]?.session?.provider == .claudeCode)
        #expect(sessions["t:b"]?.session?.provider == .codex)
    }

    @Test func lastStatusIgnoresDoneAndStaleEntriesButKeepsUnresumableOnes() {
        let statuses = OrcaLastStatus.statuses(
            from: lastStatus(entries: [
                "t:done": entry(id: "done", state: "done"),
                "t:stale": entry(id: "stale", ageDays: 7.1),
                "t:remote": entry(id: "remote", connectionID: #""ssh-devbox""#),
                "t:key": entry(id: "key", key: "conversation_id"),
                "t:junk": "42",
            ]),
            now: Self.now
        )
        #expect(Set(statuses.keys) == ["t:remote", "t:key"])
        #expect(statuses.values.allSatisfy { $0 == .unresumable })
    }

    @Test func lastStatusOfAnotherVersionReadsAsEmpty() {
        let data = lastStatus(version: 1, entries: ["t:a": entry(id: "fresh")])
        #expect(OrcaLastStatus.statuses(from: data, now: Self.now).isEmpty)
        #expect(OrcaLastStatus.statuses(from: nil, now: Self.now).isEmpty)
    }
}
