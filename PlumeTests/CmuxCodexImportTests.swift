import Foundation
import Testing
import SwiftData
@testable import Plume

@MainActor
struct CmuxCodexImportTests {
    private func snapshot(records: String) -> CmuxSnapshot {
        CmuxSnapshot.decoding(sessionData: Data(#"{"windows":[{"tabManager":{"workspaces":[{"workspaceId":"work","stableId":"stable","currentDirectory":"/repo","panels":[{"id":"panel","stableSurfaceId":"surface","type":"terminal","directory":"/repo"}]}]}}]}"#.utf8), hookData: nil,
            codexHookData: Data(("{\"sessions\":" + records + "}").utf8))
    }

    @Test func exactCodexSurfaceCarriesProviderAndThreadIdentity() throws {
        let source = snapshot(records: #"{"one":{"sessionId":"thread","workspaceId":"work","surfaceId":"surface","cwd":"/repo","transcriptPath":"/rollout.jsonl"}}"#)
        let tab = try #require(CmuxCandidateBuilder.candidates(from: source).first?.tabs.first)
        #expect(tab.kind == .agent)
        #expect(tab.provider == .codex)
        #expect(tab.agentSessionID == "thread")
        #expect(tab.permissionMode == nil)
    }

    @Test func directoryOnlyAndAmbiguousClaimsRemainTerminal() throws {
        for records in [
            #"{"one":{"sessionId":"thread","workspaceId":"work","surfaceId":"different","cwd":"/repo"}}"#,
            #"{"one":{"sessionId":"first","workspaceId":"work","surfaceId":"surface","updatedAt":1},"two":{"sessionId":"second","workspaceId":"work","surfaceId":"surface","updatedAt":1}}"#
        ] {
            let tab = try #require(CmuxCandidateBuilder.candidates(from: snapshot(records: records)).first?.tabs.first)
            #expect(tab.kind == .terminal)
            #expect(tab.agentSessionID == nil)
        }
    }

    @Test func reusedSurfaceSelectsOnlyItsNewestExactRecord() throws {
        let source = snapshot(records: #"{"one":{"sessionId":"first","workspaceId":"work","surfaceId":"surface","updatedAt":1},"two":{"sessionId":"second","workspaceId":"work","surfaceId":"surface","updatedAt":2}}"#)
        #expect(CmuxCandidateBuilder.candidates(from: source).first?.tabs.first?.agentSessionID == "second")
    }

    @Test func duplicateRecordsCannotHideAnAmbiguousNewestThread() throws {
        let source = snapshot(records: #"{"one":{"sessionId":"first","workspaceId":"work","surfaceId":"surface","updatedAt":2},"duplicate":{"sessionId":"first","workspaceId":"work","surfaceId":"surface","updatedAt":2},"two":{"sessionId":"second","workspaceId":"work","surfaceId":"surface","updatedAt":2}}"#)
        #expect(CmuxCandidateBuilder.candidates(from: source).first?.tabs.first?.kind == .terminal)
    }

    @Test func rolloutMustMatchThreadAndDirectory() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"type":"session_meta","payload":{"id":"thread","cwd":"/repo"}}"#.utf8).write(to: file)
        #expect(CmuxCodexSessions.validRollout(path: file.path, sessionID: "thread", cwd: "/repo"))
        #expect(!CmuxCodexSessions.validRollout(path: file.path, sessionID: "other", cwd: "/repo"))
        #expect(!CmuxCodexSessions.validRollout(path: file.path, sessionID: "thread", cwd: "/different"))
        #expect(!CmuxCodexSessions.validRollout(path: file.path + "missing", sessionID: "thread", cwd: "/repo"))
    }

    @Test func importedCodexIdentityIsNotConvertedToClaude() throws {
        let container = try ModelContainer(for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let candidate = ImportCandidate(stableID: "cmux:codex", title: "Codex", workingDirectoryPath: "/repo",
            groupName: nil, tabs: [ImportTabPlan(kind: .agent, title: nil, workingDirectoryPath: "/repo",
                agentSessionID: "thread", sessionJSONLPath: nil, permissionMode: nil, provider: .codex)],
            workspace: ImportWorkspacePlan(kind: .directory, isValidated: true))
        let task = try #require(Importer.importing([candidate], into: .ungrouped, in: ModelContext(container)).first)
        let tab = try #require(task.tabs.first)
        #expect(tab.provider == .codex)
        #expect(tab.agentSessionID == "thread")
        #expect(tab.sessionJSONLPath == nil)
        #expect(tab.transport == .headless)
    }

}
