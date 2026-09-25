import SwiftUI

struct KeepAwakeSettingsPane: View {
    @State private var settings = AppSettings.shared
    @State private var keepAwake = KeepAwakeCoordinator.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Keep the Mac awake") {
                    KeepAwakeModeMenu(selection: $settings.keepAwakeMode)
                }
                Toggle("Keep awake for Remote Control", isOn: $settings.keepsAwakeForRemoteControl)
            }

            Section {
                Toggle("Keep awake on battery", isOn: $settings.keepsAwakeOnBattery)
                Stepper(
                    batteryCutoffLabel,
                    value: $settings.keepAwakeBatteryCutoffPercent,
                    in: 0...100,
                    step: 5
                )
                .disabled(!settings.keepsAwakeOnBattery)
                Button("Open battery settings…") {
                    SystemSettingsLink.battery.open()
                }
                .buttonStyle(.link)
            } header: {
                Text("Battery")
            }

            Section {
                Toggle("Keep awake with the lid closed", isOn: $settings.keepsAwakeWithLidClosed)
                    .plumeID(
                        AccessibilityID.keepAwakeLidToggle,
                        value: String(settings.keepsAwakeWithLidClosed),
                        setValue: { settings.keepsAwakeWithLidClosed = ($0 == "true" || $0 == "1") }
                    )
                    .disabled(!keepAwake.lidOverrideStatus.canEngage)
                KeepAwakeHelperRow()
                LabeledContent("Allow sleep when temperature is") {
                    ThermalCutoffMenu(selection: $settings.lidClosedThermalCutoff)
                }
                .disabled(!settings.keepsAwakeWithLidClosed)
            } header: {
                Text("Lid closed")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            keepAwake.refreshLidOverride()
        }
    }

    private var batteryCutoffLabel: String {
        settings.keepAwakeBatteryCutoffPercent == 0
            ? "No battery cutoff"
            : "Allow sleep below \(settings.keepAwakeBatteryCutoffPercent)%"
    }
}
