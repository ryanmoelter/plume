import SwiftUI

/// Planning changes how Codex collaborates; permissions still govern access.
struct CodexCollaborationControl: View, ThemedView {
    @Environment(\.theme) var theme
    let state: ComposerSettings
    let form: ComposerControlsForm

    var body: some View {
        ComposerSegmentLabel(
            systemImage: state.collaborationMode.symbol,
            text: state.collaborationMode.label,
            showsText: form.showsLabels,
            indicator: .menu,
            foreground: colors.foreground,
            height: dimensions.composerControlHeight
        )
        .overlay {
            SymbolMenuButton(title: "Collaboration mode", value: state.collaborationMode.label, options: CodexCollaborationMode.allCases.map { mode in
                SymbolMenuOption(title: mode.label, systemImage: mode.symbol, isSelected: mode == state.collaborationMode) {
                    state.setCollaborationMode(mode)
                }
            })
        }
        .help("Plan explores and proposes changes. Code implements them. Permissions are controlled separately. Changes apply to the next turn.")
        .accessibilityLabel("Collaboration mode")
        .accessibilityValue(state.collaborationMode.label)
        .plumeID(AccessibilityID.composerCollaborationModeControl)
    }
}

private extension CodexCollaborationMode {
    var symbol: String {
        switch self {
        case .default: "chevron.left.forwardslash.chevron.right"
        case .plan: "list.bullet.clipboard"
        }
    }
}
