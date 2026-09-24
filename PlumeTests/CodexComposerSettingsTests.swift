import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexComposerSettingsTests {
    @Test func planningAndPermissionsRemainIndependent() {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        tab.provider = .codex
        let state = ComposerSettings(session: nil, tab: tab,
            defaults: .init(permissionMode: .auto, effort: .medium, model: .fable))
        state.setPermissionPreset(.codexWorkspace)
        state.setCollaborationMode(.plan)
        #expect(tab.codexCollaborationMode == .plan)
        #expect(tab.permissionModeRaw == AgentPermissionPreset.codexWorkspace.id)
        #expect(state.permissionPreset == .codexWorkspace)
        state.setPermissionPreset(.codexReadOnly)
        #expect(state.collaborationMode == .plan)
        state.setCollaborationMode(.default)
        #expect(tab.permissionModeRaw == AgentPermissionPreset.codexReadOnly.id)
        #expect(ComposerControlLabels.all(state: state).contains("Code"))
        #expect(ComposerControlLabels.all(state: state).contains("Read Only"))
    }

    @Test func unknownCodexEffortSurvivesPersistence() {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        tab.provider = .codex
        tab.effortRaw = "future-effort"
        #expect(tab.effort?.rawValue == "future-effort")
    }

    @Test func legacyTabsDefaultToCodeWithoutChangingClaudeMode() {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        tab.permissionMode = .plan
        #expect(tab.provider == .claudeCode)
        #expect(tab.codexCollaborationMode == .default)
        #expect(tab.permissionMode == .plan)
    }
}
