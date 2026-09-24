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
    private var defaultEffortByTabAndModel: [UUID: [String: AgentEffort]] = [:]
    private var defaultModelByTab: [UUID: AgentModel] = [:]
    private var profilesByTab: [UUID: [AgentPermissionPreset]] = [:]
    private var profilesLoaded: Set<UUID> = []

    func models(for tabID: UUID) -> [AgentModel] {
        modelsByTab[tabID] ?? AgentModel.codexSelectable
    }

    func efforts(for tabID: UUID, modelID: String?) -> [AgentEffort] {
        if let modelID, let efforts = effortsByTabAndModel[tabID]?[modelID] {
            return efforts
        }
        return AgentProviderKind.codex.efforts
    }

    /// The server's model-specific default, when a live catalog has supplied
    /// one. Callers may fall back to the app's static default before discovery.
    func defaultEffort(for tabID: UUID, modelID: String?) -> AgentEffort? {
        guard let modelID else { return nil }
        return defaultEffortByTabAndModel[tabID]?[modelID]
    }

    /// Resolves a server-reported model to its catalog display name. The
    /// caller can preserve an unrecognized ID separately when this is nil.
    func model(for tabID: UUID, id: String) -> AgentModel? {
        models(for: tabID).first {
            $0.id.caseInsensitiveCompare(id) == .orderedSame
        }
    }

    func defaultModel(for tabID: UUID) -> AgentModel? {
        defaultModelByTab[tabID] ?? models(for: tabID).first
    }

    func profiles(for tabID: UUID) -> [AgentPermissionPreset] {
        profilesLoaded.contains(tabID)
            ? profilesByTab[tabID] ?? []
            : AgentPermissionPreset.codexPresets
    }

    /// Resolves a persisted profile against what this app-server actually
    /// advertises. A tab can retain a Claude permission value such as `plan`
    /// after changing providers; sending that as a Codex profile makes the
    /// server look for a nonexistent `[permissions.plan]` table and abort the
    /// resume. Real custom profiles survive because they appear in the live
    /// catalog before thread start/resume is sent.
    func resolvedProfile(
        for tabID: UUID,
        requestedID: String?,
        fallbackID: String = AgentPermissionPreset.codexWorkspace.id
    ) -> AgentPermissionPreset? {
        let available = profiles(for: tabID)
        return available.first { $0.id == requestedID }
            ?? available.first { $0.id == fallbackID }
            ?? available.first { $0.id == AgentPermissionPreset.codexWorkspace.id }
            ?? available.first
    }

    func replaceModels(tabID: UUID, values: [JSONValue]) {
        var models: [AgentModel] = []
        var efforts: [String: [AgentEffort]] = [:]
        var defaultEfforts: [String: AgentEffort] = [:]
        var defaultModel: AgentModel?
        for value in values where value["hidden"]?.boolValue != true {
            guard let id = value["id"]?.stringValue, !id.isEmpty else { continue }
            let model = AgentModel(
                id: id,
                label: value["displayName"]?.stringValue ?? AgentModel(unrecognizedID: id).label
            )
            models.append(model)
            if value["isDefault"]?.boolValue == true { defaultModel = model }
            efforts[id] = value["supportedReasoningEfforts"]?.arrayValue?.compactMap {
                AgentEffort.recognizing($0["reasoningEffort"]?.stringValue ?? "")
            } ?? []
            if let rawDefault = value["defaultReasoningEffort"]?.stringValue,
               let defaultEffort = AgentEffort.recognizing(rawDefault) {
                defaultEfforts[id] = defaultEffort
            }
        }
        guard !models.isEmpty else { return }
        modelsByTab[tabID] = models
        effortsByTabAndModel[tabID] = efforts
        defaultEffortByTabAndModel[tabID] = defaultEfforts
        defaultModelByTab[tabID] = defaultModel ?? models[0]
    }

    func replaceProfiles(tabID: UUID, values: [JSONValue]) {
        let profiles = values.compactMap { value -> AgentPermissionPreset? in
            guard value["allowed"]?.boolValue != false,
                  let id = value["id"]?.stringValue
            else { return nil }
            return AgentPermissionPreset(id: id, label: Self.profileLabel(id))
        }
        profilesLoaded.insert(tabID)
        profilesByTab[tabID] = profiles
    }

    func forget(tabID: UUID) {
        modelsByTab[tabID] = nil
        effortsByTabAndModel[tabID] = nil
        defaultEffortByTabAndModel[tabID] = nil
        defaultModelByTab[tabID] = nil
        profilesByTab[tabID] = nil
        profilesLoaded.remove(tabID)
    }

    private static func profileLabel(_ id: String) -> String {
        id.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}
