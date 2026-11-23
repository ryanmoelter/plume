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
                    Text("Run a macOS VM from a device tab or `plume devices --kind=vm`. Needs macOS 27 and a base image.")
                }
                .plumeID(
                    AccessibilityID.labsVMsToggle,
                    value: String(settings.labsVMsEnabled),
                    setValue: { settings.labsVMsEnabled = ($0 == "true" || $0 == "1") }
                )
                Link(destination: Self.vmSetupGuide) {
                    HStack(spacing: 4) {
                        Text("Setup guide")
                        Image(systemName: "arrow.up.right.square")
                    }
                }
                .foregroundStyle(.tint)
                .plumeID("labs-vms-setup-guide-link")
            }
        }
        .formStyle(.grouped)
    }
}
