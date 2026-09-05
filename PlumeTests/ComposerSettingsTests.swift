import Foundation
import Testing
@testable import Plume

/// The composer controls' handoff: the tab's own values before a session
/// exists — which is what `AgentLauncher` launches from — and the session's
/// once one does.
@MainActor
struct ComposerSettingsTests {
    private func makeTab() -> TaskTab {
        TaskTab(kind: .agent, orderIndex: 0)
    }

    private func makeSession() -> HeadlessSession {
        HeadlessSession(tabID: UUID(), taskID: UUID())
    }

    @Test func readsTheTabBeforeASessionExists() {
        let tab = makeTab()
        tab.model = .opus
        tab.effort = .high
        tab.permissionMode = .plan
        let state = ComposerSettings(session: nil, tab: tab)

        #expect(state.isPreLaunch)
        #expect(state.model == .opus)
        #expect(state.effort == .high)
        #expect(state.permissionMode == .plan)
    }

    /// Pre-launch writes have to land on the tab: they are the only thing the
    /// launch reads, so a write that stayed in the view would be dropped.
    @Test func writesReachTheTabBeforeLaunch() {
        let tab = makeTab()
        let state = ComposerSettings(session: nil, tab: tab)

        state.setModel(.sonnet)
        state.setEffort(.max)
        state.setPermissionMode(.acceptEdits)

        #expect(tab.model == .sonnet)
        #expect(tab.effort == .max)
        #expect(tab.permissionMode == .acceptEdits)
    }

    @Test func readsTheSessionOnceOneExists() {
        let tab = makeTab()
        tab.model = .opus
        tab.permissionMode = .plan
        let session = makeSession()
        session.setModel(.sonnet)
        session.setPermissionMode(.bypassPermissions)
        let state = ComposerSettings(session: session, tab: tab)

        #expect(!state.isPreLaunch)
        #expect(state.model == .sonnet)
        #expect(state.permissionMode == .bypassPermissions)
    }

    @Test func modeAndModelReadAsUnconfirmedUntilInitReports() {
        let tab = makeTab()
        let session = makeSession()
        session.setPermissionMode(.plan)
        let state = ComposerSettings(session: session, tab: tab)

        #expect(state.isModeAndModelUnconfirmed)

        session.handle(.initialized(SessionInit(
            sessionID: "session-1",
            cwd: nil,
            model: "claude-opus-5",
            permissionMode: "acceptEdits",
            tools: [],
            slashCommands: []
        )))

        #expect(!state.isModeAndModelUnconfirmed)
    }

    /// A tab that never launched has nothing to confirm, so the pre-launch
    /// values read as the guess they are.
    @Test func preLaunchValuesAreUnconfirmed() {
        let state = ComposerSettings(session: nil, tab: makeTab())

        #expect(state.isModeAndModelUnconfirmed)
    }
}
