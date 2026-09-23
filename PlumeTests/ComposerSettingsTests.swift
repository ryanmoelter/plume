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

    /// The menu's Default item has to undo a pick completely — a leftover
    /// `isModelUserChosen` would keep `--model` on the command line.
    @Test func choosingDefaultUnpinsTheTab() {
        let tab = makeTab()
        let state = makeSettings(session: nil, tab: tab)
        state.setModel(.sonnet)

        state.clearModel()

        #expect(tab.model == nil)
        #expect(tab.modelRaw == nil)
        #expect(!tab.isModelUserChosen)
        #expect(state.model == defaults.model)
        #expect(state.isModelDefaulted)
    }

    /// A running conversation is already on some model, so Default switches it
    /// to the resolved one rather than leaving it wherever the pick left it.
    @Test func choosingDefaultMovesARunningSessionToTheResolvedModel() {
        let session = makeSession()
        session.setModel(.sonnet)
        let state = makeSettings(session: session, tab: makeTab())

        state.clearModel()

        #expect(session.model == defaults.model)
    }

    /// Tabs stored before the model list carried IDs hold a bare alias, which
    /// named the 200K model the CLI resolved it to. It has to keep reading
    /// that way rather than being promoted to a 1M variant the tab never ran.
    @Test func aTabStoringABareAliasKeepsItsPlainModel() throws {
        let tab = makeTab()
        tab.modelRaw = "opus"

        #expect(try #require(tab.model).id == "claude-opus-5")
    }

    /// Round-tripping a pick through the store must not change which model it
    /// names, suffix included.
    @Test func aPickedModelSurvivesTheStore() throws {
        let tab = makeTab()
        tab.model = .opus

        #expect(tab.modelRaw == "claude-opus-5[1m]")
        #expect(tab.model == .opus)
    }

    /// Dimming a pre-launch model reads as a disabled control, and there is
    /// nothing running that could disagree with it yet.
    @Test func theModelAwaitsConfirmationOnlyOnceASessionRuns() {
        #expect(!makeSettings(session: nil, tab: makeTab()).isModelAwaitingConfirmation)

        let session = makeSession()
        let state = makeSettings(session: session, tab: makeTab())
        #expect(state.isModelAwaitingConfirmation)

        session.handle(.initialized(SessionInit(
            sessionID: "session-1",
            cwd: nil,
            model: "claude-opus-5",
            permissionMode: "acceptEdits",
            tools: [],
            slashCommands: []
        )))
        #expect(!state.isModelAwaitingConfirmation)
    }

    /// The Default menu item names the model the launch will resolve to.
    @Test func theDefaultModelIsTheResolvedOne() {
        #expect(makeSettings(session: nil, tab: makeTab()).defaultModel == defaults.model)
        let codexTab = makeTab()
        codexTab.provider = .codex
        #expect(makeSettings(session: nil, tab: codexTab).defaultModel(for: .claudeCode) == defaults.model)
    }

    @Test func providerCanChangeOnlyBeforeConversationStateExists() {
        let tab = makeTab()
        #expect(makeSettings(session: nil, tab: tab).canChangeProvider)

        tab.agentSessionID = "conversation"
        #expect(!makeSettings(session: nil, tab: tab).canChangeProvider)

        tab.agentSessionID = nil
        tab.sessionJSONLPath = "/tmp/conversation.jsonl"
        #expect(!makeSettings(session: nil, tab: tab).canChangeProvider)

        tab.sessionJSONLPath = nil
        #expect(!makeSettings(session: makeSession(), tab: tab).canChangeProvider)
    }

    @Test func providerSwitchClearsProviderSpecificChoices() {
        let tab = makeTab()
        tab.model = .opus
        tab.isModelUserChosen = true
        tab.effort = .max
        tab.isEffortUserChosen = true
        tab.permissionMode = .plan
        tab.codexCollaborationMode = .plan
        let state = makeSettings(session: nil, tab: tab)

        #expect(state.setProvider(.codex))

        #expect(tab.provider == .codex)
        #expect(tab.modelRaw == nil)
        #expect(!tab.isModelUserChosen)
        #expect(tab.effortRaw == nil)
        #expect(!tab.isEffortUserChosen)
        #expect(tab.permissionModeRaw == nil)
        #expect(tab.codexCollaborationMode == .default)
    }

    @Test func crossProviderModelPickChangesProviderAndPinsModel() {
        let tab = makeTab()
        let codexModel = AgentModel.codexSelectable[0]

        #expect(makeSettings(session: nil, tab: tab).setModel(codexModel, provider: .codex))

        #expect(tab.provider == .codex)
        #expect(tab.model == codexModel)
        #expect(tab.isModelUserChosen)
    }

    @Test func persistedConversationRejectsCrossProviderModelPick() {
        let tab = makeTab()
        tab.agentSessionID = "conversation"

        #expect(!makeSettings(session: nil, tab: tab).setModel(.codexSelectable[0], provider: .codex))
        #expect(tab.provider == .claudeCode)
        #expect(tab.modelRaw == nil)
    }

    @Test func providerAwarePickStillChangesALiveModelWithinItsProvider() {
        let tab = makeTab()
        tab.agentSessionID = "conversation"
        let session = makeSession()
        let state = makeSettings(session: session, tab: tab)

        #expect(state.setModel(.sonnet, provider: .claudeCode))

        #expect(session.model == .sonnet)
        #expect(tab.model == .sonnet)
        #expect(tab.provider == .claudeCode)
    }

    /// A model the CLI reports that this build has no preset for still has to
    /// display, or the control would silently name the wrong model.
    @Test func anUnknownReportedModelDisplaysAsItsOwnID() throws {
        let session = makeSession()
        session.handle(.initialized(SessionInit(
            sessionID: "session-1",
            cwd: nil,
            model: "claude-next-7",
            permissionMode: "acceptEdits",
            tools: [],
            slashCommands: []
        )))
        let state = makeSettings(session: session, tab: makeTab())

        #expect(try #require(state.model).id == "claude-next-7")
    }
}
