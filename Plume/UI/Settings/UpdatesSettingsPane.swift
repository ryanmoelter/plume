import SwiftUI

struct UpdatesSettingsPane: View {
    @State private var settings = AppSettings.shared
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

                if updates.isHomebrewInstall || settings.updateInstallSourceOverride != nil {
                    Picker("Install updates with", selection: installSourceBinding) {
                        ForEach(UpdateInstallSource.allCases) { source in
                            installSourceLabel(for: source).tag(source)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .plumeID(
                        AccessibilityID.updatesInstallSourcePicker,
                        value: updates.installSource.rawValue,
                        setValue: { if let source = UpdateInstallSource(rawValue: $0) { installSourceBinding.wrappedValue = source } }
                    )
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

    @ViewBuilder
    private func installSourceLabel(for source: UpdateInstallSource) -> some View {
        if source == .homebrew, updates.isHomebrewInstall {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.label)
                Text("Detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(source.label)
        }
    }

    /// Explicit rather than following `updates.installSource`: choosing a
    /// value here always sets the override, even when it matches what
    /// detection would already have picked.
    private var installSourceBinding: Binding<UpdateInstallSource> {
        Binding(
            get: { updates.installSource },
            set: { settings.updateInstallSourceOverride = $0 }
        )
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
