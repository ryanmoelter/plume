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
                    .foregroundStyle(.tint)
                Text("Grant Full Disk Access?")
            }
            .font(.title2.weight(.semibold))

            Text(
                "Agents running inside of \(AppIdentity.displayName) may ask for permission to read files inside " +
                "protected folders like Desktop, Documents, Downloads, Music, and iCloud Drive."
            )

            Text(LocalizedStringKey(
                "**Giving \(AppIdentity.displayName) Full Disk Access gives your agents full access to all of your " +
                "files**, including sensitive ones, without permission prompts."
            ))

            Text(LocalizedStringKey(
                "**\(AppIdentity.displayName) works with or without this, and you can change it at any time** in " +
                "System Settings › Privacy & Security › Full Disk Access, or via the link in " +
                "\(AppIdentity.displayName)'s settings."
            ))

            Text("You will need to restart \(AppIdentity.displayName) after granting access.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Don't ask again", action: onDismiss)
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
