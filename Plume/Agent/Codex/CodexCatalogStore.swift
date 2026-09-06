import Foundation

/// Provider vocabulary advertised by each live Codex app-server.
///
/// Profiles can vary with the working directory and supported effort levels
/// vary by model, so this is keyed by tab rather than treated as app-wide.
@MainActor
@Observable
final class CodexCatalogStore {
    static let shared = CodexCatalogStore()

    private var modelsByTab: [UUID: [AgentModel]] = [:]
    private var effortsByTabAndModel: [UUID: [String: [AgentEffort]]] = [:]
    private var defaultModelByTab: [UUID: AgentModel] = [:]
    private var profilesByTab: [UUID: [AgentPermissionPreset]] = [:]

    func models(for tabID: UUID) -> [AgentModel] {
        modelsByTab[tabID] ?? AgentModel.codexSelectable
    }

    func efforts(for tabID: UUID, modelID: String?) -> [AgentEffort] {
        if let modelID, let efforts = effortsByTabAndModel[tabID]?[modelID], !efforts.isEmpty {
            return efforts
        }
        return AgentProviderKind.codex.efforts
    }

    func defaultModel(for tabID: UUID) -> AgentModel? {
        defaultModelByTab[tabID] ?? models(for: tabID).first
    }

    func profiles(for tabID: UUID) -> [AgentPermissionPreset] {
        profilesByTab[tabID] ?? AgentPermissionPreset.codexPresets
    }

    func replaceModels(tabID: UUID, values: [JSONValue]) {
        var models: [AgentModel] = []
        var efforts: [String: [AgentEffort]] = [:]
        var defaultModel: AgentModel?
        for value in values where value["hidden"]?.boolValue != true {
            guard let id = value["id"]?.stringValue, !id.isEmpty else { continue }
            let model = AgentModel(
                id: id,
                label: value["displayName"]?.stringValue ?? AgentModel(unrecognizedID: id).label
            )
            models.append(model)
            if value["isDefault"]?.boolValue == true { defaultModel = model }
            efforts[id] = value["supportedReasoningEfforts"]?.arrayValue?.compactMap { option in
                option["reasoningEffort"]?.stringValue.flatMap(AgentEffort.init(rawValue:))
            }
        }
        guard !models.isEmpty else { return }
        modelsByTab[tabID] = models
        effortsByTabAndModel[tabID] = efforts
        defaultModelByTab[tabID] = defaultModel ?? models[0]
    }

    func replaceProfiles(tabID: UUID, values: [JSONValue]) {
        let profiles = values.compactMap { value -> AgentPermissionPreset? in
            guard value["allowed"]?.boolValue != false,
                  let id = value["id"]?.stringValue
            else { return nil }
            return AgentPermissionPreset(id: id, label: Self.profileLabel(id))
        }
        if !profiles.isEmpty { profilesByTab[tabID] = profiles }
    }

    func forget(tabID: UUID) {
        modelsByTab[tabID] = nil
        effortsByTabAndModel[tabID] = nil
        defaultModelByTab[tabID] = nil
        profilesByTab[tabID] = nil
    }

    private static func profileLabel(_ id: String) -> String {
        id.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}
