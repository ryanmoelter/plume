import SwiftUI

/// Home's offer to install the bundled skills, shown until Plume owns one or
/// the user says not now.
struct HomeSkillsOffer: View, ThemedView {
    let status: BundledSkillsStatus
    @Environment(\.theme) var theme
    @State private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: dimensions.panelContentInset) {
            Text("Install Plume's agent skills")
                .font(typography.body.font)
                .fontWeight(.semibold)
            Text("Teach agents how to use Plume, like managing devices, opening tabs, creating worktrees, and stacking PRs")
                .font(typography.body.font)
                .emphasis(.secondary)
            if let error = status.error(for: .home) {
                Text(error)
                    .font(typography.caption.font)
                    .foregroundStyle(colors.danger)
            }
            HStack(spacing: dimensions.panelContentInset) {
                Button(action: install) {
                    Text("Install").font(typography.body.font)
                }
                .buttonStyle(.bordered)
                .tint(colors.selection)
                .plumeID(AccessibilityID.homeSkillsInstallButton, invoke: install)
                .disabled(status.isChanging)
                Button(action: dismiss) {
                    Text("Not Now").font(typography.body.font)
                }
                .buttonStyle(.bordered)
                .tint(colors.foreground)
                .plumeID(AccessibilityID.homeSkillsNotNowButton, invoke: dismiss)
            }
        }
        .padding(dimensions.composerFieldInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: dimensions.panelCornerRadius)
                .strokeBorder(colors.attention, lineWidth: 1)
        }
    }

    private func install() {
        status.installMissing(on: .home)
    }

    private func dismiss() {
        settings.bundledSkillsPromptDismissed = true
        status.clearError(for: .home)
    }
}
