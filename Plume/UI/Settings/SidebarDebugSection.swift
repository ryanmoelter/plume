#if DEBUG
import SwiftUI

struct SidebarDebugSection: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Section {
            Toggle("Sidebar agent titles at task-name size", isOn: $settings.sidebarAgentTitlesAtTaskNameSize)
                .plumeID(
                    AccessibilityID.debugSidebarAgentTitleSizeToggle,
                    value: settings.sidebarAgentTitlesAtTaskNameSize ? "on" : "off",
                    invoke: { settings.sidebarAgentTitlesAtTaskNameSize.toggle() }
                )
        } header: {
            Text("Sidebar (Debug)")
        }
    }
}
#endif
