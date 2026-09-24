import Foundation
import Testing
@testable import Plume

@MainActor
struct SeededProviderRecoveryTests {
    @Test func restoresOnlyAnIdentifiedClaudeConversation() {
        let tab = mislabeledTab()
        #expect(SeededProviderRecovery.recover(tab, transcriptPrefix: matchingRecord))
        #expect(tab.provider == .claudeCode)
        #expect(tab.agentSessionID == "existing-session")
        #expect(tab.sessionJSONLPath != nil)
        #expect(!SeededProviderRecovery.recover(tab, transcriptPrefix: matchingRecord))
    }

    @Test func preservesCodexWhenTranscriptEvidenceIsMissingOrMismatched() {
        let tab = mislabeledTab()
        #expect(!SeededProviderRecovery.recover(tab, transcriptPrefix: Data()))
        #expect(!SeededProviderRecovery.recover(tab, transcriptPrefix: Data(#"{"type":"user","sessionId":"another-session"}"#.utf8)))
        tab.sessionJSONLPath = "/tmp/existing-session.jsonl"
        #expect(!SeededProviderRecovery.recover(tab, transcriptPrefix: matchingRecord))
        tab.sessionJSONLPath = "/Users/test/.claude/projects/project/another-session.jsonl"
        #expect(!SeededProviderRecovery.recover(tab, transcriptPrefix: matchingRecord))
        tab.sessionJSONLPath = nil
        #expect(!SeededProviderRecovery.recover(tab, transcriptPrefix: matchingRecord))
        #expect(tab.provider == .codex)
    }

    private var matchingRecord: Data {
        Data(#"{"type":"queue-operation","sessionId":"existing-session"}"#.utf8)
    }

    private func mislabeledTab() -> TaskTab {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        tab.provider = .codex
        tab.agentSessionID = "existing-session"
        tab.sessionJSONLPath = "/Users/test/.claude/projects/project/existing-session.jsonl"
        return tab
    }
}
