import SwiftUI

struct ThermalCutoffMenu: View {
    @Binding var selection: ThermalCutoffLevel

    var body: some View {
        Picker(selection: $selection) {
            ForEach(ThermalCutoffLevel.allCases) { level in
                VStack(alignment: .leading) {
                    Text(level.label)
                    Text(level.detail)
                }
                .tag(level)
            }
        } label: {
            Text("Allow sleep when temperature is")
        } currentValueLabel: {
            Text(selection.label)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .plumeID(
            AccessibilityID.keepAwakeThermalPicker,
            value: selection.rawValue,
            setValue: { if let level = ThermalCutoffLevel(rawValue: $0) { selection = level } }
        )
    }
}
