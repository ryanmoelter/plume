import Testing
import Foundation
@testable import Plume

/// How Orca worktrees become candidates: one per worktree with saved tabs,
/// grouped by repo, in Orca's sidebar and strip order, with an agent tab only
/// where the journal names its Claude session.
struct OrcaCandidateTests {
    private static let rootID = "repo-widgets::/Users/example/Widgets"
    private static let rootAgentSession = "claude_aaaaaaaa_1111_2222_3333_444444444444"

    private func candidates(claudeSessionIDs: [String: String] = [rootAgentSession: "11111111-2222-3333-4444-555555555555"]) throws -> [ImportCandidate] {
        let data = try OrcaParsingTests.fixture("data-basic")
        return OrcaCandidateBuilder.candidates(from: OrcaSnapshot.decoding(data: data, claudeSessionIDs: claudeSessionIDs))
    }

    private func candidate(_ worktreeID: String) throws -> ImportCandidate {
        try #require(try candidates().first { $0.stableID == "orca:\(worktreeID)" })
    }

    /// Repos in file order, then descending `sortOrder`; worktrees whose repo
    /// is unknown come last. The `emptied` worktree has an empty
    /// `unifiedTabs` entry, and the `legacy` worktree has only a legacy terminal,
    /// which is ignored because `unifiedTabs` exists. Gadgets' root holds only
    /// a file tab and the ephemeral id has no path, so all of them drop out.
    @Test func candidatesFollowOrcaSidebarOrder() throws {
        #expect(try candidates().map(\.stableID) == [
            "orca:repo-widgets::/Users/example/Widgets/.worktrees/feature",
            "orca:repo-widgets::/Users/example/Widgets",
            "orca:repo-unknown::/Users/example/Orphan",
        ])
    }

    @Test func theRepoNamesTheGroup() throws {
        #expect(try candidate(Self.rootID).groupName == "Widgets")
        #expect(try candidate("repo-unknown::/Users/example/Orphan").groupName == nil)
    }

    @Test func aDisplayNameTitlesTheCandidateAndAFolderNameStandsIn() throws {
        #expect(try candidate("repo-widgets::/Users/example/Widgets/.worktrees/feature").title == "Feature work")
        let root = try candidate(Self.rootID)
        #expect(root.title == "Widgets")
        #expect(root.workingDirectoryPath == "/Users/example/Widgets")
    }

    /// `tabOrder` lists the agent tab, then Server, then the dropped browser
    /// tab; Terminal 1 is in no group and follows by `sortOrder`.
    @Test func tabsFollowTheGroupsTabOrder() throws {
        let root = try candidate(Self.rootID)
        #expect(root.tabs.map(\.title) == ["Claude Chat", "Server", "Terminal 1"])
        #expect(root.tabs.allSatisfy { $0.workingDirectoryPath == "/Users/example/Widgets" })
    }

    @Test func anAgentTabWithAJournalHitBecomesAClaudeAgent() throws {
        let agent = try #require(try candidate(Self.rootID).tabs.first)
        #expect(agent.kind == .agent)
        #expect(agent.provider == .claudeCode)
        #expect(agent.agentSessionID == "11111111-2222-3333-4444-555555555555")
        #expect(agent.sessionJSONLPath == nil)
    }

    @Test func anAgentTabWithoutAJournalHitBecomesATerminal() throws {
        let feature = try candidate("repo-widgets::/Users/example/Widgets/.worktrees/feature")
        #expect(feature.tabs.map(\.kind) == [.terminal, .terminal])
        #expect(feature.tabs.allSatisfy { $0.agentSessionID == nil })
        #expect(feature.isImportable)
    }

    @Test func withNoJournalEveryTabIsATerminal() throws {
        let root = try #require(try candidates(claudeSessionIDs: [:]).first { $0.stableID == "orca:\(Self.rootID)" })
        #expect(root.agentTabCount == 0)
        #expect(root.terminalTabCount == 3)
    }

    @Test func legacyTerminalsAreReadOnlyWhenUnifiedTabsIsAbsent() throws {
        let legacyTabs = """
        "tabsByWorktree": {"r::/Users/example/Legacy": [
          {"id": "legacy-a", "title": "Terminal 1", "sortOrder": 0},
          {"id": "legacy-b", "title": "Terminal 2", "customTitle": "Logs", "sortOrder": 1},
          {"id": "legacy-c", "title": "Terminal 3", "customTitle": "", "sortOrder": 2}]},
        "tabGroups": {"r::/Users/example/Legacy": [{"id": "g", "tabOrder": ["legacy-b", "legacy-a"]}]}
        """
        let absent = OrcaSnapshot.decoding(
            data: Data(#"{"schemaVersion": 1, "workspaceSession": {\#(legacyTabs)}}"#.utf8),
            claudeSessionIDs: [:]
        )
        let tabs = try #require(OrcaCandidateBuilder.candidates(from: absent).first).tabs
        #expect(tabs.map(\.title) == ["Logs", "Terminal 1", "Terminal 3"])
        #expect(tabs.allSatisfy { $0.kind == .terminal })

        let present = OrcaSnapshot.decoding(
            data: Data(#"{"schemaVersion": 1, "workspaceSession": {"unifiedTabs": {}, \#(legacyTabs)}}"#.utf8),
            claudeSessionIDs: [:]
        )
        #expect(present.worktrees.isEmpty)
    }

    @Test func aRemoteWorktreeIsSkipped() {
        let json = """
        {"schemaVersion": 1,
         "worktreeMeta": {"r::/srv/remote": {"hostId": "ssh-devbox"}, "r::/Users/example/Here": {"hostId": "local"}},
         "workspaceSession": {"unifiedTabs": {
           "r::/srv/remote": [{"id": "a", "entityId": "a", "contentType": "terminal", "label": "Terminal 1"}],
           "r::/Users/example/Here": [{"id": "b", "entityId": "b", "contentType": "terminal", "label": "Terminal 1"}]}}}
        """
        let snapshot = OrcaSnapshot.decoding(data: Data(json.utf8), claudeSessionIDs: [:])
        #expect(snapshot.worktrees.map(\.worktreeID) == ["r::/Users/example/Here"])
    }

    @Test func aWorktreeWithOnlyUnimportableTabsIsSkipped() throws {
        #expect(try candidates().allSatisfy { $0.stableID != "orca:repo-gadgets::/Users/example/Gadgets" })
    }

    @Test func aWorktreeIDWithoutAPathIsSkipped() throws {
        #expect(try candidates().allSatisfy { $0.stableID != "orca:ephemeral-setup-terminal:onboarding" })
    }

    @Test func aBlankRepoNameFallsBackToTheRepoFolder() {
        let json = """
        {"schemaVersion": 1,
         "repos": [{"id": "r", "path": "/Users/example/Folder", "displayName": "  "}],
         "workspaceSession": {"unifiedTabs": {"r::/Users/example/Folder": [
           {"id": "t", "entityId": "t", "contentType": "terminal", "label": "Terminal 1"}]}}}
        """
        let snapshot = OrcaSnapshot.decoding(data: Data(json.utf8), claudeSessionIDs: [:])
        #expect(OrcaCandidateBuilder.candidates(from: snapshot).first?.groupName == "Folder")
    }

    @Test func anAgentTabWithoutASessionLosesItsAgentTitle() throws {
        let feature = try candidate("repo-widgets::/Users/example/Widgets/.worktrees/feature")
        #expect(feature.tabs.map(\.title) == [nil, "Terminal 1"])
    }
}
