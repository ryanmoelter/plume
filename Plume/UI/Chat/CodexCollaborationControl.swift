import SwiftUI

/// Planning changes how Codex collaborates; permissions still govern access.
struct CodexCollaborationControl: View, ThemedView {
    @Environment(\.theme) var theme
    let state: ComposerSettings
    let form: ComposerControlsForm

    var body: some View {
        Menu {
            ForEach(CodexCollaborationMode.allCases) { mode in
                Button(mode.label) { state.setCollaborationMode(mode) }
            }
        } label: {
            Label(state.collaborationMode.label,
                  systemImage: state.collaborationMode == .plan ? "list.bullet.clipboard" : "chevron.left.forwardslash.chevron.right")
                .labelStyle(CollaborationLabelStyle(showsTitle: form.showsLabels))
        }
        .menuStyle(.borderlessButton)
        .help("Plan explores and proposes changes. Code implements them. Permissions are controlled separately. Changes apply to the next turn.")
        .accessibilityLabel("Collaboration mode")
        .accessibilityValue(state.collaborationMode.label)
        .accessibilityIdentifier("composerCodexCollaborationMode")
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
