import ServiceManagement
import SwiftUI

struct KeepAwakeHelperRow: View {
    @State private var keepAwake = KeepAwakeCoordinator.shared

    var body: some View {
        LabeledContent {
            HStack {
                switch keepAwake.lidOverrideStatus {
                case .notRegistered:
                    Button("Install…") { keepAwake.installLidHelper() }
                        .plumeID(AccessibilityID.keepAwakeLidInstallButton)
                case .needsApproval:
                    Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                        .plumeID(AccessibilityID.keepAwakeLidApprovalButton)
                case .unavailable(let reason):
                    Text(reason).foregroundStyle(.red)
                case .ready, .engaged:
                    Text("Installed").foregroundStyle(.secondary)
                    Button("Uninstall") { keepAwake.uninstallLidHelper() }
                        .plumeID(AccessibilityID.keepAwakeLidUninstallButton)
                }
            }
        } label: {
            Text("Keep awake helper")
            Text("Allows staying awake while your Mac's lid is closed")
                .foregroundStyle(.tertiary)
        }
        .onAppear { keepAwake.refreshLidOverride() }
    }
}
