import SwiftUI

/// The thermal cutoff picker. A `Menu` of check items rather than a `Picker`
/// so each level can carry its description as a subtitle, which only matters
/// while choosing.
struct ThermalCutoffMenu: View {
    @Binding var selection: ThermalCutoffLevel

    var body: some View {
        Menu {
            ForEach(ThermalCutoffLevel.allCases) { level in
                Toggle(isOn: Binding(
                    get: { selection == level },
                    set: { if $0 { selection = level } }
                )) {
                    Text(level.label)
                    Text(level.detail)
                }
            }
        } label: {
            Text(selection.label)
        }
        .fixedSize()
        .plumeID(
            AccessibilityID.keepAwakeThermalPicker,
            value: selection.rawValue,
            setValue: { if let level = ThermalCutoffLevel(rawValue: $0) { selection = level } }
        )
    }
}
