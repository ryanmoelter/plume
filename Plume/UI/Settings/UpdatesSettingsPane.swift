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

                HStack {
                    Button("Check Now", action: updates.checkForUpdates)
                        .plumeID(AccessibilityID.updatesCheckNowButton)
                        .disabled(!updates.canCheckForUpdates)
                    Spacer()
                }

                if updates.isHomebrewInstall || settings.updateInstallSourceOverride != nil {
                    Picker("Install updates with", selection: installSourceBinding) {
                        ForEach(UpdateInstallSource.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .plumeID(
                        AccessibilityID.updatesInstallSourcePicker,
                        value: updates.installSource.rawValue,
                        setValue: { if let source = UpdateInstallSource(rawValue: $0) { installSourceBinding.wrappedValue = source } }
                    )
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(updatesFooterText)
                    .foregroundStyle(.secondary)
            }
            .disabled(!updates.isRunning)
        }
        .formStyle(.grouped)
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

    private var updatesFooterText: String {
        guard updates.isRunning else {
            return "Updates are off in debug builds."
        }
        let lastChecked = updates.lastUpdateCheckDate.map { "Last checked \($0.formatted(.relative(presentation: .named)))." }
            ?? "Never checked."
        guard updates.isHomebrewInstall || settings.updateInstallSourceOverride != nil else {
            return lastChecked
        }
        return lastChecked + " A Homebrew install updates through brew upgrade."
    }
}
