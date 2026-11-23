import SwiftUI

/// Experimental features, each off until the user opts in.
struct LabsSettingsPane: View {
    @State private var settings = AppSettings.shared

    private static let vmSetupGuide = URL(string: "https://github.com/ryanmoelter/plume/blob/main/docs/vm-testing.md")!

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.labsVMsEnabled) {
                    Text("macOS VMs for testing")
                    Text("Run Plume in a macOS VM from a device tab or `plume devices --kind=vm`. Needs macOS 27 and a base image.")
                }
                .plumeID(
                    AccessibilityID.labsVMsToggle,
                    value: String(settings.labsVMsEnabled),
                    setValue: { settings.labsVMsEnabled = ($0 == "true" || $0 == "1") }
                )
                Link("Setup guide (docs/vm-testing.md)", destination: Self.vmSetupGuide)
            } footer: {
                Text("Turning this off stops new claims. VMs already running keep going until their leases are released or run out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
