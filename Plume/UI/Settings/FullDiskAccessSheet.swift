import AppKit
import SwiftUI

/// Explains Full Disk Access before an agent trips the permission on its own.
///
/// Shown once, on the first launch that finds the permission missing. The
/// explanation is the feature: macOS raises this prompt the moment an agent
/// reads somewhere protected, naming Plume and not the agent or the command,
/// so whoever sees it has no way to tell what asked or why. Granting it up
/// front is optional — dismissing is a real choice, and nothing here blocks.
struct FullDiskAccessSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                Text("Grant Full Disk Access?")
                    .font(.title2.weight(.semibold))
            }

            Text(
                "Plume runs coding agents, and an agent reads and writes files wherever you " +
                "point it — your repositories, and folders macOS protects such as Desktop, " +
                "Documents, Downloads, and iCloud Drive."
            )

            Text(
                "Without Full Disk Access, macOS interrupts with a permission prompt the first " +
                "time an agent touches one of those folders. That prompt names Plume rather " +
                "than the agent or the command that caused it, so it tends to arrive with no " +
                "clue what triggered it — often long after you started the work."
            )

            Text(
                "Granting it now avoids those interruptions. You can skip this and grant it " +
                "later in System Settings › Privacy & Security › Full Disk Access; Plume works " +
                "either way, and will not ask again."
            )
            .foregroundStyle(.secondary)

            Text("macOS requires you to quit and reopen Plume after granting access.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Not Now", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .plumeID(AccessibilityID.fullDiskAccessDismissButton)

                Button("Open System Settings") {
                    NSWorkspace.shared.open(FullDiskAccess.settingsURL)
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .plumeID(AccessibilityID.fullDiskAccessOpenButton)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
