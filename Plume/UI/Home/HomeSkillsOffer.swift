import SwiftUI

/// Home's offer to install the bundled skills, shown until Plume owns one or
/// the user says not now.
struct HomeSkillsOffer: View, ThemedView {
    let status: BundledSkillsStatus
    @Environment(\.theme) var theme
    @State private var settings = AppSettings.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Install Plume's agent skills — teaches Claude `plume wt`, `stack`, `devices`…")
                .font(typography.body.font)
                .emphasis(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Not Now", action: dismiss)
                .buttonStyle(.borderless)
                .plumeID(AccessibilityID.homeSkillsNotNowButton, invoke: dismiss)
            Button("Install", action: status.installMissing)
                .buttonStyle(.bordered)
                .plumeID(AccessibilityID.homeSkillsInstallButton, invoke: status.installMissing)
                .disabled(status.isChanging)
        }
        .controlSize(.small)
    }

    private func dismiss() {
        settings.bundledSkillsPromptDismissed = true
    }
}
