#if DEBUG
import SwiftUI

struct HomeDebugSection: View {
    @AppStorage("homeCollapseEmptyStatusSlot") private var collapsesEmptyStatusSlot = false
    @AppStorage("homeAlignColorBarToText") private var alignsColorBarToText = false
    @AppStorage(HomeSectionReveal.scaleKey) private var scalesRevealedRows = true

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
            Toggle("Scale rows in as a section opens", isOn: $scalesRevealedRows)
                .plumeID(
                    AccessibilityID.settingsHomeRevealScaleToggle,
                    value: scalesRevealedRows ? "on" : "off",
                    setValue: { scalesRevealedRows = $0 == "on" }
                )
        } header: {
            Text("Home")
        } footer: {
            Text("Release builds use Off for the two alignment options and On for scaling.")
        }
    }
}
#endif
