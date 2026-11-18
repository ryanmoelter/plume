#if DEBUG
import SwiftUI

/// Tries the alternative hover for a task row's agent groups.
struct SidebarDebugSection: View {
    @AppStorage(AgentGroupBar.debugHoverEmphasisKey) private var hoverEmphasizes = false

    var body: some View {
        Section {
            Toggle("Agent group hover darkens text and bar", isOn: $hoverEmphasizes)
                .plumeID(
                    AccessibilityID.debugAgentGroupHoverEmphasisToggle,
                    value: hoverEmphasizes ? "on" : "off",
                    invoke: { hoverEmphasizes.toggle() }
                )
        } header: {
            Text("Sidebar (Debug)")
        } footer: {
            Text("Off, a hovered agent group shows a wash behind it.")
                .foregroundStyle(.secondary)
        }
    }
}
#endif
