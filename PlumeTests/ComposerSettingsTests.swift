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

    /// Fixed rather than resolved from the real `~/.claude`, so the tests
    /// assert Plume's fallback order and not this machine's configuration.
    private let defaults = ComposerSettings.Defaults(
        permissionMode: .auto,
        effort: .medium,
        model: .fable
    )

    private func makeSettings(session: HeadlessSession?, tab: TaskTab) -> ComposerSettings {
        ComposerSettings(session: session, tab: tab, defaults: defaults)
    }

    @Test func readsTheTabBeforeASessionExists() {
        let tab = makeTab()
        tab.model = .opus
        tab.effort = .high
        tab.permissionMode = .plan
        let state = makeSettings(session: nil, tab: tab)

        #expect(state.isPreLaunch)
        #expect(state.model == .opus)
        #expect(state.effort == .high)
        #expect(state.permissionMode == .plan)
    }

    /// Pre-launch writes have to land on the tab: they are the only thing the
    /// launch reads, so a write that stayed in the view would be dropped.
    @Test func writesReachTheTabBeforeLaunch() {
        let tab = makeTab()
        let state = makeSettings(session: nil, tab: tab)

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
        let state = makeSettings(session: session, tab: tab)

        #expect(!state.isPreLaunch)
        #expect(state.model == .sonnet)
        #expect(state.permissionMode == .bypassPermissions)
    }

    @Test func modeAndModelReadAsUnconfirmedUntilInitReports() {
        let tab = makeTab()
        let session = makeSession()
        session.setPermissionMode(.plan)
        let state = makeSettings(session: session, tab: tab)

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
        let state = makeSettings(session: nil, tab: makeTab())

        #expect(state.isModeAndModelUnconfirmed)
    }

    /// An untouched tab still launches on something, so every control names
    /// the value the launch will resolve to rather than going blank.
    @Test func unsetControlsShowTheResolvedDefaults() {
        let state = makeSettings(session: nil, tab: makeTab())

        #expect(state.model == .fable)
        #expect(state.effort == .medium)
        #expect(state.permissionMode == .auto)
        #expect(state.isModelDefaulted)
    }

    @Test func theTabBeatsTheDefault() {
        let tab = makeTab()
        tab.model = .sonnet
        tab.effort = .max
        tab.permissionMode = .plan
        let state = makeSettings(session: nil, tab: tab)

        #expect(state.model == .sonnet)
        #expect(state.effort == .max)
        #expect(state.permissionMode == .plan)
        #expect(!state.isModelDefaulted)
    }

    /// Displaying a default must not write one: the tab staying unset is what
    /// keeps `--model` off the command line.
    @Test func showingADefaultModelLeavesTheTabUnset() {
        let tab = makeTab()
        _ = makeSettings(session: nil, tab: tab).model

        #expect(tab.model == nil)
        #expect(!tab.isModelUserChosen)
    }

    /// Only a pick may pass `--model` to a resume.
    @Test func pickingAModelMarksItUserChosen() {
        let tab = makeTab()
        makeSettings(session: nil, tab: tab).setModel(.sonnet)

        #expect(tab.model == .sonnet)
        #expect(tab.isModelUserChosen)
    }
}
