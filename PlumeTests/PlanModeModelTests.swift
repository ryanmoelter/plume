import Foundation
import Testing
@testable import Plume

/// The model chip names both models while plan mode runs a different one:
/// predicted from the alias until a plan-mode reply reports its own model,
/// and the plain model outside plan mode or once the two match.
@MainActor
struct PlanModeModelTests {
    private let haikuRun = AgentModel(unrecognizedID: "claude-haiku-5-5")
    private let defaults = ComposerSettings.Defaults(permissionMode: .plan, effort: .medium, model: .fable)

    private func makeSession() -> HeadlessSession {
        HeadlessSession(tabID: UUID(), taskID: UUID())
    }

    private func initialized(model: String, permissionMode: String) -> StreamJSONMessage {
        .initialized(SessionInit(
            sessionID: "session-1",
            cwd: nil,
            model: model,
            permissionMode: permissionMode,
            tools: [],
            slashCommands: []
        ))
    }

    private func reply(model: String, parentToolUseID: String? = nil) throws -> StreamJSONMessage {
        let parent = parentToolUseID.map { "\"\($0)\"" } ?? "null"
        let line = #"{"type":"assistant","parent_tool_use_id":\#(parent),"message":{"id":"msg_1","model":"\#(model)","content":[]}}"#
        return try #require(StreamJSONDecoder.decode(line: line))
    }

    // MARK: - Pure rules

    @Test func predictsOnlyTheSwappingAliases() {
        #expect(PlanModeModel.predicted(forRequestedID: "haiku") == .sonnet)
        #expect(PlanModeModel.predicted(forRequestedID: "opusplan") == .opus)
        #expect(PlanModeModel.predicted(forRequestedID: "claude-haiku-5-5") == nil)
        #expect(PlanModeModel.predicted(forRequestedID: "sonnet[1m]") == nil)
        #expect(PlanModeModel.predicted(forRequestedID: nil) == nil)
    }

    @Test func anObservationOverridesThePrediction() throws {
        let observed = try #require(PlanModeModel.observation(replyModel: "claude-haiku-5-5", runs: haikuRun))

        #expect(PlanModeModel.differing(runs: haikuRun, requestedID: "haiku", observed: observed) == nil)
    }

    @Test func anObservationUnderAnotherRunModelIsStale() throws {
        let observed = try #require(PlanModeModel.observation(replyModel: "claude-haiku-5-5", runs: .opus5dot5))

        #expect(PlanModeModel.differing(runs: haikuRun, requestedID: "haiku", observed: observed) == .sonnet)
    }

    @Test func ignoresSyntheticReplies() {
        #expect(PlanModeModel.observation(replyModel: "<synthetic>", runs: haikuRun) == nil)
        #expect(PlanModeModel.observation(replyModel: nil, runs: haikuRun) == nil)
    }

    @Test func aBareFamilyMatchesAnyVersionOfIt() {
        #expect(PlanModeModel.isSameModel(.haiku, haikuRun))
        #expect(PlanModeModel.isSameModel(.sonnet, .sonnet5))
        #expect(!PlanModeModel.isSameModel(.sonnet5, AgentModel(unrecognizedID: "claude-sonnet-5-5")))
        #expect(!PlanModeModel.isSameModel(.sonnet, haikuRun))
    }

    // MARK: - Session

    @Test func recordsTheModelOfAPlanModeReply() throws {
        let session = makeSession()
        session.setModel(.haiku)
        session.handle(initialized(model: "claude-haiku-5-5", permissionMode: "plan"))

        session.handle(try reply(model: "claude-sonnet-5-5"))

        #expect(session.requestedModelID == "haiku")
        #expect(session.observedPlanModel?.planModel.label == "Sonnet 5.5")
        #expect(session.observedPlanModel?.runModelID == "claude-haiku-5-5")
    }

    @Test func ignoresRepliesOutsidePlanModeAndFromSubagents() throws {
        let session = makeSession()
        session.handle(initialized(model: "claude-haiku-5-5", permissionMode: "plan"))
        session.handle(try reply(model: "claude-sonnet-5-5", parentToolUseID: "toolu_1"))
        #expect(session.observedPlanModel == nil)

        session.handle(initialized(model: "claude-haiku-5-5", permissionMode: "auto"))
        session.handle(try reply(model: "claude-sonnet-5-5"))
        #expect(session.observedPlanModel == nil)
    }

    // MARK: - Chip

    @Test func predictsBothModelsBeforeLaunch() {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        tab.model = .haiku
        tab.permissionMode = .plan
        let state = ComposerSettings(session: nil, tab: tab, defaults: defaults)

        #expect(ComposerControlLabels.model(state) == "Sonnet → Haiku")
        #expect(ComposerControlLabels.modelHelp(state) == "Plans with Sonnet, then runs Haiku")
    }

    @Test func showsTheObservedPlanModelAndDropsItOutsidePlanMode() throws {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        let session = makeSession()
        session.setModel(.haiku)
        session.handle(initialized(model: "claude-haiku-5-5", permissionMode: "plan"))
        let state = ComposerSettings(session: session, tab: tab, defaults: defaults)

        #expect(ComposerControlLabels.model(state) == "Sonnet → Haiku 5.5")

        session.handle(try reply(model: "claude-sonnet-5-5"))
        #expect(ComposerControlLabels.model(state) == "Sonnet 5.5 → Haiku 5.5")

        session.setPermissionMode(.auto)
        #expect(ComposerControlLabels.model(state) == "Haiku 5.5")
        #expect(ComposerControlLabels.modelHelp(state) == "Model: Haiku 5.5")

        session.setPermissionMode(.plan)
        #expect(ComposerControlLabels.model(state) == "Sonnet 5.5 → Haiku 5.5")
    }

    @Test func looksUnchangedWhenPlanModeRunsTheSameModel() throws {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        let session = makeSession()
        session.setModel(.sonnet)
        session.handle(initialized(model: "claude-sonnet-5-5", permissionMode: "plan"))
        session.handle(try reply(model: "claude-sonnet-5-5"))
        let state = ComposerSettings(session: session, tab: tab, defaults: defaults)

        #expect(ComposerControlLabels.model(state) == "Sonnet 5.5")
    }

    @Test func marksADefaultedPairAsDefault() {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        tab.permissionMode = .plan
        let state = ComposerSettings(
            session: nil,
            tab: tab,
            defaults: .init(permissionMode: .plan, effort: .medium, model: .haiku)
        )

        #expect(ComposerControlLabels.model(state) == "Default (Sonnet → Haiku)")
    }
}
