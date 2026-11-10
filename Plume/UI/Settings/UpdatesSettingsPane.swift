import SwiftUI

struct UpdatesSettingsPane: View {
    @State private var updates = UpdateController.shared

    var body: some View {
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: $updates.automaticallyChecksForUpdates)
                    .plumeID(
                        AccessibilityID.updatesAutoCheckToggle,
                        value: String(updates.automaticallyChecksForUpdates),
                        setValue: { updates.automaticallyChecksForUpdates = ($0 == "true" || $0 == "1") }
                    )

                LabeledContent(lastCheckedText) {
                    Button("Check now", action: updates.checkForUpdates)
                        .plumeID(AccessibilityID.updatesCheckNowButton)
                        .disabled(!updates.canCheckForUpdates)
                }
            } header: {
                Text("Updates")
            } footer: {
                if !updates.isRunning {
                    Text(notRunningText)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!updates.isRunning)
        }
        .formStyle(.grouped)
    }

    private var lastCheckedText: String {
        updates.lastUpdateCheckDate.map { "Last checked \($0.formatted(.relative(presentation: .named)))" }
            ?? "Never checked"
    }

    private var notRunningText: String {
        #if DEBUG
        "Updates are off in debug builds until you set a test feed in Settings ▸ Debug."
        #else
        "Updates could not start."
        #endif
    }
}
