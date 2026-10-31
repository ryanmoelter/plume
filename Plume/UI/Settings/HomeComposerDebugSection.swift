#if DEBUG
import SwiftUI

struct HomeComposerDebugSection: View {
    @AppStorage(HomeComposerVariant.userDefaultsKey) private var variant = HomeComposerVariant.aboveField
    @AppStorage(HomeComposerPlacement.userDefaultsKey) private var placement = HomeComposerPlacement.top

    @AppStorage("homeCollapseEmptyStatusSlot") private var collapsesEmptyStatusSlot = false
    @AppStorage("homeAlignColorBarToText") private var alignsColorBarToText = false

    var body: some View {
        Section {
            Picker("Destination picker", selection: $variant) {
                ForEach(HomeComposerVariant.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .plumeID(
                AccessibilityID.settingsHomeComposerVariantPicker, value: variant.rawValue,
                setValue: { variant = HomeComposerVariant(rawValue: $0) ?? variant }
            )
            Picker("Placement", selection: $placement) {
                ForEach(HomeComposerPlacement.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .plumeID(
                AccessibilityID.settingsHomeComposerPlacementPicker, value: placement.rawValue,
                setValue: { placement = HomeComposerPlacement(rawValue: $0) ?? placement }
            )
        } header: {
            Text("Home composer")
        } footer: {
            Text("Release builds use D and Top.")
        }
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
