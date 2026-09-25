import ServiceManagement
import SwiftUI

struct KeepAwakeSettingsPane: View {
    @State private var settings = AppSettings.shared
    @State private var keepAwake = KeepAwakeCoordinator.shared

    var body: some View {
        Form {
            Section {
                Picker("Keep the Mac awake", selection: $settings.keepAwakeMode) {
                    ForEach(KeepAwakeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Toggle("Keep awake for Remote Control", isOn: $settings.keepsAwakeForRemoteControl)
            } footer: {
                Text("Auto keeps the Mac awake while an agent works or a session is under remote control.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep awake on battery", isOn: $settings.keepsAwakeOnBattery)
                if settings.keepsAwakeOnBattery {
                    Stepper(
                        batteryCutoffLabel,
                        value: $settings.keepAwakeBatteryCutoffPercent,
                        in: 0...100,
                        step: 5
                    )
                }
            } header: {
                Text("Battery")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The cutoff does not apply while the Mac charges.")
                        .foregroundStyle(.secondary)
                    Button("Open Battery Settings…") {
                        SystemSettingsLink.battery.open()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            Section {
                Toggle("Keep awake with the lid closed", isOn: $settings.keepsAwakeWithLidClosed)
                    .plumeID(
                        AccessibilityID.keepAwakeLidToggle,
                        value: String(settings.keepsAwakeWithLidClosed),
                        setValue: { settings.keepsAwakeWithLidClosed = ($0 == "true" || $0 == "1") }
                    )
                    .disabled(!keepAwake.lidOverrideStatus.canEngage)
                sleepHelperRow
                if settings.keepsAwakeWithLidClosed {
                    LabeledContent("Allow sleep when temperature is") {
                        ThermalCutoffMenu(selection: $settings.lidClosedThermalCutoff)
                    }
                }
            } header: {
                Text("Lid Closed")
            } footer: {
                Text("This needs the sleep helper, approved in Login Items. The Mac sleeps anyway if it gets too hot.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            keepAwake.refreshLidOverride()
        }
    }

    @ViewBuilder
    private var sleepHelperRow: some View {
        switch keepAwake.lidOverrideStatus {
        case .notRegistered:
            LabeledContent("Sleep helper") {
                Button("Install…") { keepAwake.installLidHelper() }
                    .plumeID(AccessibilityID.keepAwakeLidInstallButton)
            }
        case .needsApproval:
            LabeledContent("Sleep helper") {
                Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    .plumeID(AccessibilityID.keepAwakeLidApprovalButton)
            }
        case .unavailable(let reason):
            LabeledContent("Sleep helper") {
                Text(reason).foregroundStyle(.red)
            }
        case .ready, .engaged:
            LabeledContent("Sleep helper") {
                HStack {
                    Text("Installed").foregroundStyle(.secondary)
                    Button("Uninstall") { keepAwake.uninstallLidHelper() }
                        .plumeID(AccessibilityID.keepAwakeLidUninstallButton)
                }
            }
        }
    }

    private var batteryCutoffLabel: String {
        settings.keepAwakeBatteryCutoffPercent == 0
            ? "No battery cutoff"
            : "Allow sleep below \(settings.keepAwakeBatteryCutoffPercent)%"
    }
}
