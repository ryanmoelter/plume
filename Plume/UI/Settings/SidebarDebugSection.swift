#if DEBUG
import SwiftUI

/// Tries the alternative hover for a task row's agent groups.
struct SidebarDebugSection: View {
    @AppStorage(AgentGroupBar.debugHoverWashKey) private var hoverShowsWash = false

    var body: some View {
        Section {
            Toggle("Agent group hover shows a wash", isOn: $hoverShowsWash)
                .plumeID(
                    AccessibilityID.debugAgentGroupHoverWashToggle,
                    value: hoverShowsWash ? "on" : "off",
                    invoke: { hoverShowsWash.toggle() }
                )
        } header: {
            Text("Sidebar (Debug)")
        } footer: {
            Text("Off, a hovered agent group widens its bar and brightens its text.")
                .foregroundStyle(.secondary)
        }
    }
}
#endif
