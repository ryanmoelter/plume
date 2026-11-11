import Foundation

/// What a tab's composer controls set before its first launch, which is what
/// `AgentLauncher` launches from: provider, transport, model, effort,
/// permission mode and Codex collaboration mode.
nonisolated struct TabLaunchChoices: Equatable, Sendable {
    var providerID: String?
    var transportRaw: String?
    var modelRaw: String?
    var isModelUserChosen = false
    var effortRaw: String?
    var isEffortUserChosen = false
    var permissionModeRaw: String?
    var codexCollaborationModeRaw = "default"
}

nonisolated extension TabLaunchChoices {
    @MainActor
    init(_ tab: TaskTab) {
        self.init(
            providerID: tab.providerID,
            transportRaw: tab.transportRaw,
            modelRaw: tab.modelRaw,
            isModelUserChosen: tab.isModelUserChosen,
            effortRaw: tab.effortRaw,
            isEffortUserChosen: tab.isEffortUserChosen,
            permissionModeRaw: tab.permissionModeRaw,
            codexCollaborationModeRaw: tab.codexCollaborationModeRaw
        )
    }

    @MainActor
    func apply(to tab: TaskTab) {
        tab.providerID = providerID
        tab.transportRaw = transportRaw
        tab.modelRaw = modelRaw
        tab.isModelUserChosen = isModelUserChosen
        tab.effortRaw = effortRaw
        tab.isEffortUserChosen = isEffortUserChosen
        tab.permissionModeRaw = permissionModeRaw
        tab.codexCollaborationModeRaw = codexCollaborationModeRaw
    }
}
