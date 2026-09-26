import SwiftUI

/// Planning changes how Codex collaborates; permissions still govern access.
struct CodexCollaborationControl: View, ThemedView {
    @Environment(\.theme) var theme
    let state: ComposerSettings
    let form: ComposerControlsForm

    var body: some View {
        Menu {
            ForEach(CodexCollaborationMode.allCases) { mode in
                Button(mode.label, systemImage: mode.symbol) { state.setCollaborationMode(mode) }
            }
        } label: {
            Label(state.collaborationMode.label, systemImage: state.collaborationMode.symbol)
                .labelStyle(CollaborationLabelStyle(showsTitle: form.showsLabels))
        }
        .menuStyle(.borderlessButton)
        .help("Plan explores and proposes changes. Code implements them. Permissions are controlled separately. Changes apply to the next turn.")
        .accessibilityLabel("Collaboration mode")
        .accessibilityValue(state.collaborationMode.label)
        .accessibilityIdentifier("composerCodexCollaborationMode")
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

private struct CollaborationLabelStyle: LabelStyle {
    let showsTitle: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            if showsTitle { configuration.title }
        }
    }
}
