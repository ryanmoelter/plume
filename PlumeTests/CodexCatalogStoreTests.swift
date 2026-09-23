import Foundation
import Testing

@testable import Plume

@MainActor
struct CodexCatalogStoreTests {
    @Test func liveModelsFilterHiddenAndCarryTheirEfforts() {
        let tabID = UUID()
        let store = CodexCatalogStore()
        store.replaceModels(tabID: tabID, values: [
            .object([
                "id": .string("visible"), "displayName": .string("Visible"),
                "hidden": .bool(false), "isDefault": .bool(true),
                "defaultReasoningEffort": .string("deliberate"),
                "supportedReasoningEfforts": .array([
                    .object(["reasoningEffort": .string("low")]),
                    .object(["reasoningEffort": .string("deliberate")])
                ])
            ]),
            .object([
                "id": .string("hidden"), "displayName": .string("Hidden"),
                "hidden": .bool(true), "isDefault": .bool(false)
            ])
        ])

        #expect(store.models(for: tabID).map(\.id) == ["visible"])
        #expect(store.defaultModel(for: tabID)?.id == "visible")
        #expect(store.efforts(for: tabID, modelID: "visible") == [.low, AgentEffort(rawValue: "deliberate")])
        #expect(store.defaultEffort(for: tabID, modelID: "visible")?.rawValue == "deliberate")
        #expect(store.model(for: tabID, id: "visible")?.label == "Visible")
    }

    @Test func liveProfilesDropDisallowedEntries() {
        let tabID = UUID()
        let store = CodexCatalogStore()
        store.replaceProfiles(tabID: tabID, values: [
            .object(["id": .string(":workspace"), "allowed": .bool(true)]),
            .object(["id": .string(":danger-full-access"), "allowed": .bool(false)])
        ])

        #expect(store.profiles(for: tabID) == [
            AgentPermissionPreset(id: ":workspace", label: "Workspace")
        ])
    }

    @Test func staleClaudePermissionFallsBackToCodexDefault() {
        let tabID = UUID()
        let store = CodexCatalogStore()
        store.replaceProfiles(tabID: tabID, values: [
            .object(["id": .string(":read-only"), "allowed": .bool(true)]),
            .object(["id": .string(":workspace"), "allowed": .bool(true)])
        ])

        let profile = store.resolvedProfile(
            for: tabID,
            requestedID: PermissionMode.plan.rawValue,
            fallbackID: AgentPermissionPreset.codexReadOnly.id
        )

        #expect(profile == .some(.codexReadOnly))
    }

    @Test func advertisedCustomPermissionProfileSurvivesResolution() {
        let tabID = UUID()
        let store = CodexCatalogStore()
        store.replaceProfiles(tabID: tabID, values: [
            .object(["id": .string("reviewer"), "allowed": .bool(true)])
        ])

        #expect(store.resolvedProfile(for: tabID, requestedID: "reviewer")?.id == "reviewer")
    }

    @Test func anEmptyAllowedProfileCatalogDoesNotRestoreForbiddenPresets() {
        let tabID = UUID()
        let store = CodexCatalogStore()
        store.replaceProfiles(tabID: tabID, values: [
            .object(["id": .string(":workspace"), "allowed": .bool(false)]),
            .object(["id": .string(":danger-full-access"), "allowed": .bool(false)])
        ])

        #expect(store.profiles(for: tabID).isEmpty)
        #expect(store.resolvedProfile(for: tabID, requestedID: nil) == nil)
    }
}
