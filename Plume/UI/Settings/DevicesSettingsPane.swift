import SwiftUI

/// Settings for Android device tabs.
struct DevicesSettingsPane: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Keep Plume shortcuts on the Mac", isOn: $settings.keepsPlumeShortcutsOnMac)
                    .plumeID(
                        AccessibilityID.devicesKeepShortcutsToggle,
                        value: String(settings.keepsPlumeShortcutsOnMac),
                        setValue: { settings.keepsPlumeShortcutsOnMac = ($0 == "true" || $0 == "1") }
                    )
            } header: {
                Text("Keyboard")
            } footer: {
                Text("While a physical device tab has focus, ⌘ chords that aren't Plume shortcuts go to the device with Meta held. Turn this off to send every ⌘ chord to the device, Plume's own included; click outside the device to use them again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
