import Foundation

/// Shift-Tab is claimed by an open autocomplete, then by a list item's
/// outdent, and only otherwise toggles plan mode.
nonisolated enum ComposerShiftTab {
    enum Action: Equatable {
        case autocomplete
        case outdent(ComposerMarkdownEditing.Result)
        case togglePlanMode
        case ordinary
    }

    static func decide(
        autocompleteShowing: Bool,
        outdent: ComposerMarkdownEditing.Result?,
        canTogglePlanMode: Bool
    ) -> Action {
        if autocompleteShowing { return .autocomplete }
        if let outdent { return .outdent(outdent) }
        return canTogglePlanMode ? .togglePlanMode : .ordinary
    }

    /// Plan mode when `current` is not plan; otherwise the last non-plan mode,
    /// or auto when the conversation has only been in plan. Nil when the
    /// presets offer no plan mode, or no mode to return to.
    static func togglePlan(
        current: AgentPermissionPreset?,
        lastNonPlan: AgentPermissionPreset?,
        in presets: [AgentPermissionPreset]
    ) -> AgentPermissionPreset? {
        let plan = presets.first { $0.id == PermissionMode.plan.rawValue }
        guard let plan else { return nil }
        guard current?.id == plan.id else { return plan }
        if let lastNonPlan, lastNonPlan.id != plan.id, presets.contains(lastNonPlan) { return lastNonPlan }
        return presets.first { $0.id == PermissionMode.auto.rawValue }
    }
}

/// The mode each tab left when it entered plan mode, or last chose.
@MainActor
@Observable
final class LastNonPlanModeStore {
    static let shared = LastNonPlanModeStore()

    private var presets: [UUID: AgentPermissionPreset] = [:]

    func preset(forTab id: UUID) -> AgentPermissionPreset? { presets[id] }

    func remember(_ preset: AgentPermissionPreset, forTab id: UUID) {
        guard preset.id != PermissionMode.plan.rawValue else { return }
        presets[id] = preset
    }
}
