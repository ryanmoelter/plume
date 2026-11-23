import Testing
@testable import Plume

struct ClaudeModelCatalogTests {
    @Test func catalogUsesAdvertisedTokensAndLabels() {
        let models = ClaudeModelCatalog.models(in: [
            "models": .array([
                .object(["value": .string("default"), "resolvedModel": .string("claude-opus-5-5")]),
                .object(["value": .string("sonnet"), "resolvedModel": .string("claude-sonnet-5-5"),
                         "displayName": .string("Sonnet")]),
                .object(["value": .string("claude-fable-5-2[1m]"), "resolvedModel": .string("claude-fable-5-2"),
                         "displayName": .string("Fable")]),
                .object(["value": .string("sonnet"), "displayName": .string("Duplicate")]),
                .object(["value": .string("custom/agent"), "displayName": .string("Custom Agent")]),
                .object(["value": .string("invalid\nmodel")]),
            ])
        ])

        #expect(models == [
            AgentModel(id: "sonnet", label: "Sonnet 5.5"),
            AgentModel(id: "claude-fable-5-2[1m]", label: "Fable 5.2"),
            AgentModel(id: "custom/agent", label: "Custom Agent"),
        ])
    }

    @Test func onlyTheDefaultIsDistinctFromAnUnavailableCatalog() {
        #expect(ClaudeModelCatalog.models(in: [:]) == nil)
        #expect(ClaudeModelCatalog.models(in: ["models": .array([.object(["value": .string("default")])])]) == [])
    }

    @Test @MainActor func pinnedCatalogAliasKeepsItsLaunchToken() {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        tab.model = AgentModel(id: "sonnet", label: "Sonnet 5.5")
        tab.isModelUserChosen = true
        #expect(tab.model?.token == "sonnet")
    }
}
