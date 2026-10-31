#if DEBUG
import SwiftUI

struct HomeComposerDebugSection: View {
    @AppStorage(HomeComposerVariant.userDefaultsKey) private var variant = HomeComposerVariant.chipRow
    @AppStorage(HomeComposerPlacement.userDefaultsKey) private var placement = HomeComposerPlacement.top

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
            Text("Release builds use A and Top.")
        }
    }
}
#endif
