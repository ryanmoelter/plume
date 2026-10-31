#if DEBUG
import SwiftUI

struct HomeRowAlignmentDebugSection: View {
    @AppStorage("homeCollapseEmptyStatusSlot") private var collapsesEmptyStatusSlot = false
    @AppStorage("homeAlignColorBarToText") private var alignsColorBarToText = false

    var body: some View {
        Section {
            Toggle("Collapse empty status slot", isOn: $collapsesEmptyStatusSlot)
                .plumeID(
                    AccessibilityID.settingsHomeCollapseEmptyStatusSlotToggle,
                    value: collapsesEmptyStatusSlot ? "on" : "off",
                    setValue: { collapsesEmptyStatusSlot = $0 == "on" }
                )
            Toggle("Align color bar to text", isOn: $alignsColorBarToText)
                .plumeID(
                    AccessibilityID.settingsHomeAlignColorBarToggle,
                    value: alignsColorBarToText ? "on" : "off",
                    setValue: { alignsColorBarToText = $0 == "on" }
                )
        } header: {
            Text("Home row alignment")
        } footer: {
            Text("Release builds use Off for both.")
        }
    }
}
#endif
